package relay.session

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.net.ConnectionSurface
import relay.net.SessionController
import relay.net.SessionException
import relay.protocol.ActivityState
import relay.protocol.ClientMessage
import relay.protocol.ConnectionConfig
import relay.protocol.ServerMessage
import relay.protocol.SessionInfo
import relay.protocol.SessionState
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Op-ordering parity harness for [SessionCoordinator], ported from
 * Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift.
 *
 * The load-bearing assertions are the *orderings* of the four distinct session
 * ops (create / switch / attach / terminate). To assert orderings precisely
 * across the two collaborators the coordinator drives — the real
 * [SessionController] (RPCs) and the connection (terminal-output wiring +
 * control sends) — both fakes append to ONE shared [callLog]. The unified log
 * lets the tests assert, e.g., that SWITCH wires output BEFORE the resume RPC and
 * never claims, or that CREATE wires AFTER the create RPC.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionCoordinatorTest {

    // ---- Shared ordered call-log -------------------------------------------

    private class CallLog {
        val entries = ArrayList<String>()
        fun add(entry: String) = entries.add(entry)
        /** True when [a] occurs before [b] in the log (both must be present). */
        fun precedes(a: String, b: String): Boolean {
            val ia = entries.indexOf(a)
            val ib = entries.indexOf(b)
            return ia >= 0 && ib >= 0 && ia < ib
        }
        operator fun contains(entry: String) = entries.contains(entry)
    }

    // ---- Fake ConnectionSurface backing the REAL SessionController ---------
    //
    // On send it records the RPC and immediately delivers a canned response so
    // the real SessionController.sendAndWaitForResponse resolves without a socket.

    private class FakeConnectionSurface(private val log: CallLog) : ConnectionSurface {
        override var generation: Long = 1L
        private val subscribers = ConcurrentHashMap<UUID, (ServerMessage) -> Unit>()

        /** Override to fail a specific op (e.g. attach) — return the error to throw via response. */
        var responder: (ClientMessage) -> ServerMessage? = { defaultResponse(it) }

        /**
         * Awaited between logging an RPC and delivering its response — lets a
         * test park a session op mid-flight (e.g. between detach and the create
         * response) to probe the coordinator's transient state.
         */
        var sendGate: (suspend (ClientMessage) -> Unit)? = null

        override fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID {
            val id = UUID.randomUUID()
            subscribers[id] = handler
            return id
        }

        override fun removeSubscriber(id: UUID) { subscribers.remove(id) }

        /** Captured cols/rows from the most recent SessionCreate RPC (null if never sent or omitted). */
        var lastCreateCols: UShort? = null
        var lastCreateRows: UShort? = null

        override suspend fun send(message: ClientMessage) {
            log.add("rpc:${message.typeString}")
            if (message is ClientMessage.SessionCreate) {
                lastCreateCols = message.cols
                lastCreateRows = message.rows
            }
            sendGate?.invoke(message)
            responder(message)?.let { response ->
                for (h in subscribers.values) h(response)
            }
        }

        private fun defaultResponse(message: ClientMessage): ServerMessage? = when (message) {
            is ClientMessage.AuthRequest -> ServerMessage.AuthSuccess(protocolVersion = 1)
            is ClientMessage.SessionCreate -> ServerMessage.SessionCreated(NEW_SESSION_ID, 80u, 24u)
            is ClientMessage.SessionAttach -> ServerMessage.SessionAttached(message.sessionId, "running")
            is ClientMessage.SessionResume -> ServerMessage.SessionResumed(message.sessionId)
            is ClientMessage.SessionDetach -> ServerMessage.SessionDetached
            is ClientMessage.SessionList -> ServerMessage.SessionList(sessionsOnServer)
            // SessionListAll defaults to the token-scoped list, but tests can stage a
            // SUPERSET (sessions on OTHER tokens) by setting [allSessionsOnServer] to
            // exercise the prune-against-all-sessions behavior.
            is ClientMessage.SessionListAll ->
                if (failAllSessions) {
                    ServerMessage.Error(code = 500, message = "session_list_all unavailable")
                } else {
                    ServerMessage.SessionListAll(allSessionsOnServer ?: sessionsOnServer)
                }
            else -> null // rename/terminate/ping are fire-and-forget here
        }

        /** Sessions the server reports for SessionList (token-scoped). Mutable so tests can stage prune scenarios. */
        var sessionsOnServer: List<SessionInfo> = emptyList()

        /**
         * Sessions the server reports for SessionListAll (all tokens). `null` ⇒ mirror
         * [sessionsOnServer]; set to a superset to model sessions owned under another
         * token, which must survive the prune.
         */
        var allSessionsOnServer: List<SessionInfo>? = null

        /** When true, SessionListAll responds with an Error so listAllSessions throws. */
        var failAllSessions: Boolean = false

        companion object {
            val NEW_SESSION_ID: UUID = UUID.fromString("00000000-0000-0000-0000-0000000000aa")
        }
    }

    // ---- Fake CoordinatorConnection (wiring + control sends) ---------------

    private class FakeCoordinatorConnection(private val log: CallLog) : CoordinatorConnection {
        var alive: Boolean = true
        var lastWiredHandler: ((ByteArray) -> Unit)? = null
        /** When set, forceReconnect awaits it (lets a test park the recovery pass). */
        var forceReconnectGate: kotlinx.coroutines.CompletableDeferred<Unit>? = null
        /**
         * When set, isAlive awaits it — parks a recovery pass inside the probe,
         * BEFORE it commits (isRecovering is still false there), so a test can
         * race a user op into that window.
         */
        var isAliveGate: kotlinx.coroutines.CompletableDeferred<Unit>? = null
        /**
         * Invoked on forceReconnect — lets a test mirror the real transport, where
         * reconnecting bumps the (shared) connection generation that the
         * SessionController's auth/attachment stamps are compared against.
         */
        var onForceReconnect: (() -> Unit)? = null
        private val subscribers = ConcurrentHashMap<UUID, (ServerMessage) -> Unit>()

        override var onTerminalOutput: ((ByteArray) -> Unit)? = null
            set(value) {
                field = value
                lastWiredHandler = value
                log.add("wire")
            }
        override var onSendFailed: (() -> Unit)? = null
        override var onHealthyPing: (() -> Unit)? = null

        override suspend fun connect(config: ConnectionConfig, token: String) { log.add("connect") }
        override suspend fun forceReconnect() {
            log.add("forceReconnect")
            onForceReconnect?.invoke()
            forceReconnectGate?.await()
        }
        override suspend fun disconnect() { log.add("disconnect") }
        override suspend fun isAlive(): Boolean {
            isAliveGate?.await()
            return alive
        }
        override suspend fun send(message: ClientMessage) { log.add("send:${message.typeString}") }
        override fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID {
            val id = UUID.randomUUID()
            subscribers[id] = handler
            return id
        }
        override fun removeSubscriber(id: UUID) { subscribers.remove(id) }

        /** Push a server message through the coordinator's installed fan-in. */
        fun deliver(message: ServerMessage) { subscribers.values.forEach { it(message) } }
    }

    // ---- In-memory OwnershipStore ------------------------------------------

    private class FakeOwnershipStore(
        private val log: CallLog? = null,
        seedNames: Map<UUID, String> = emptyMap(),
        seedOwned: Set<UUID> = emptySet(),
        seedAgents: Map<UUID, String> = emptyMap(),
    ) : OwnershipStore {
        private val namesMap = seedNames.toMutableMap()
        private val ownedSet = seedOwned.toMutableSet()
        private val agentsMap = seedAgents.toMutableMap()

        override val names: Map<UUID, String> get() = namesMap.toMap()
        override val owned: Set<UUID> get() = ownedSet.toSet()
        override val agents: Map<UUID, String> get() = agentsMap.toMap()

        override fun setName(id: UUID, name: String?) {
            if (name == null) namesMap.remove(id) else namesMap[id] = name
        }
        override fun claim(id: UUID) { ownedSet.add(id); log?.add("claim") }
        override fun unclaim(id: UUID) { ownedSet.remove(id); log?.add("unclaim") }
        override fun setAgent(id: UUID, agentId: String?) {
            if (agentId == null) agentsMap.remove(id) else agentsMap[id] = agentId
        }
    }

    // ---- Harness -----------------------------------------------------------

    private val config = ConnectionConfig(name = "test", host = "127.0.0.1")

    private fun session(id: UUID, name: String? = null): SessionInfo =
        SessionInfo(
            id = id,
            name = name,
            state = SessionState.ACTIVE_ATTACHED,
            tokenId = "tok",
            createdAt = 0.0,
            cols = 80u,
            rows = 24u,
            activity = ActivityState.ACTIVE,
            agent = null,
        )

    private fun newClock() = object {
        var ms = 1_000_000L
    }

    // -------------------------------------------------------------------------
    // CREATE: withAuth → createSession, THEN claim, THEN wire (AFTER the RPC),
    // set active, touch, enforceLimit, fetch.
    // -------------------------------------------------------------------------

    @Test
    fun `createNewSession wires after the create RPC and claims`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val store = FakeOwnershipStore(log)
        // The post-create fetchSessions prunes anything the server doesn't list,
        // so the server must report the freshly-created session back.
        surface.sessionsOnServer = listOf(session(FakeConnectionSurface.NEW_SESSION_ID, "Arya"))
        val controller = SessionController(surface)
        val coord = SessionCoordinator(
            scope = this,
            connection = conn,
            sessionController = controller,
            token = "tok",
            ownershipStore = store,
            config = config,
        )

        coord.createNewSession()
        advanceUntilIdle()

        // RPC ordering: create happens, then claim, then wire (wire AFTER RPC).
        assertTrue(log.precedes("rpc:session_create", "claim"), "create RPC precedes claim")
        assertTrue(log.precedes("claim", "wire"), "claim precedes wire")
        assertTrue(log.precedes("rpc:session_create", "wire"), "wire is AFTER the create RPC")
        assertEquals(FakeConnectionSurface.NEW_SESSION_ID, coord.activeSessionId.value)
        assertTrue(store.owned.contains(FakeConnectionSurface.NEW_SESSION_ID), "session is claimed")
    }

    // -------------------------------------------------------------------------
    // CREATE seeds the session_create RPC with the last-known terminal size.
    // -------------------------------------------------------------------------

    @Test
    fun `createNewSession sends the last-known terminal size`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val store = FakeOwnershipStore(log)
        surface.sessionsOnServer = listOf(session(FakeConnectionSurface.NEW_SESSION_ID, "Arya"))
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        coord.recordTerminalSize(110, 35)
        coord.createNewSession()
        advanceUntilIdle()

        assertEquals(110.toUShort(), surface.lastCreateCols, "create carried the cached cols")
        assertEquals(35.toUShort(), surface.lastCreateRows, "create carried the cached rows")
    }

    // -------------------------------------------------------------------------
    // SWITCH: wire BEFORE resume, and NO claim.
    // -------------------------------------------------------------------------

    @Test
    fun `switchToSession wires before resume and never claims`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val target = UUID.randomUUID()
        val store = FakeOwnershipStore(log, seedOwned = setOf(target))
        surface.sessionsOnServer = listOf(session(target, "Arya"))
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        coord.switchToSession(target)
        advanceUntilIdle()

        assertTrue(log.precedes("wire", "rpc:session_resume"), "wire precedes resume RPC")
        assertFalse("claim" in log, "switch must NOT claim")
        assertEquals(target, coord.activeSessionId.value)
    }

    // -------------------------------------------------------------------------
    // SWITCH then replay_complete → active VM endReplay() flushes.
    // We assert via a wired output handler: beginReplay buffers, endReplay flushes.
    // -------------------------------------------------------------------------

    @Test
    fun `onReplayComplete ends replay on the active terminal`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val target = UUID.randomUUID()
        val store = FakeOwnershipStore(log, seedOwned = setOf(target))
        surface.sessionsOnServer = listOf(session(target, "Arya"))
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        coord.switchToSession(target)
        advanceUntilIdle()

        // The active VM is in replay mode (beginReplay was called during switch).
        // Install an output sink + mark the terminal sized, push output, then end replay.
        val vm = coord.terminalCache.view(target)!!
        val flushed = ArrayList<ByteArray>()
        vm.onTerminalOutput = { flushed.add(it) }
        vm.terminalReady() // sized; still replaying so nothing flushes yet (emits RIS only)
        flushed.clear()
        vm.receiveOutput(byteArrayOf(1, 2, 3)) // buffered while replaying

        // Deliver replay_complete via the server-message fan-in.
        conn.deliver(ServerMessage.ReplayComplete(target))
        advanceUntilIdle()

        assertEquals(1, flushed.size, "endReplay flushed the buffered output as one frame")
        assertEquals(listOf<Byte>(1, 2, 3), flushed[0].toList())
    }

    // -------------------------------------------------------------------------
    // ATTACH failure → rollback: resume(previousId) + re-wire(previousId).
    // -------------------------------------------------------------------------

    @Test
    fun `attachRemoteSession failure rolls back to the previous session`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val previous = UUID.randomUUID()
        val attachTarget = UUID.randomUUID()
        val store = FakeOwnershipStore(log, seedOwned = setOf(previous))
        surface.sessionsOnServer = listOf(session(previous, "Arya"))
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        // Establish an active "previous" session via switch.
        coord.switchToSession(previous)
        advanceUntilIdle()

        // Now fail the attach: the SessionAttach RPC returns an error.
        surface.responder = { msg ->
            when (msg) {
                is ClientMessage.SessionAttach -> ServerMessage.Error(404, "session not found")
                is ClientMessage.AuthRequest -> ServerMessage.AuthSuccess(1)
                is ClientMessage.SessionDetach -> ServerMessage.SessionDetached
                is ClientMessage.SessionResume -> ServerMessage.SessionResumed((msg).sessionId)
                is ClientMessage.SessionList -> ServerMessage.SessionList(surface.sessionsOnServer)
                else -> null
            }
        }
        log.entries.clear()

        coord.attachRemoteSession(attachTarget)
        advanceUntilIdle()

        // Rollback: a resume of the PREVIOUS id happened, followed by a re-wire.
        assertTrue("rpc:session_attach" in log, "attach was attempted")
        assertTrue("rpc:session_resume" in log, "previous session was resumed on rollback")
        // The last wire after rollback re-targets the previous VM; assert resume precedes that wire.
        assertTrue(log.precedes("rpc:session_resume", "wire"), "re-wire follows the rollback resume")
        // Active session stays the previous one (attach never committed).
        assertEquals(previous, coord.activeSessionId.value)
    }

    // -------------------------------------------------------------------------
    // TERMINATE: send terminate, clear active, evict, forget BEFORE unclaim, fetch.
    // -------------------------------------------------------------------------

    @Test
    fun `terminateSession clears active, evicts, forgets and unclaims`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val target = UUID.randomUUID()
        val store = FakeOwnershipStore(log, seedOwned = setOf(target), seedAgents = mapOf(target to "claude"))
        // Report the target with a running agent so the switch's fetchSessions
        // keeps the agent mapped (an agent==null SessionInfo would clear it).
        surface.sessionsOnServer = listOf(
            session(target, "Arya").copy(activity = ActivityState.AGENT_ACTIVE, agent = "claude"),
        )
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)
        coord.switchToSession(target)
        advanceUntilIdle()
        assertEquals(target, coord.activeSessionId.value)
        assertTrue(store.agents.containsKey(target), "agent mapped before terminate")
        // After terminate the server no longer lists the session.
        surface.sessionsOnServer = emptyList()
        log.entries.clear()

        coord.terminateSession(target)
        advanceUntilIdle()

        assertTrue("send:session_terminate" in log, "terminate control message sent")
        assertNull(coord.activeSessionId.value, "active cleared")
        assertNull(coord.terminalCache.view(target), "terminal evicted")
        assertFalse(store.agents.containsKey(target), "agent forgotten")
        assertFalse(store.owned.contains(target), "session unclaimed")
    }

    // forget-before-unclaim ordering, asserted directly via a logging store that
    // records both forget (setAgent null) and unclaim.
    @Test
    fun `terminateSession ordering forget precedes unclaim`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val target = UUID.randomUUID()
        // A store that logs BOTH setAgent(null) ("forget") and unclaim.
        val store = object : OwnershipStore {
            private val n = mutableMapOf<UUID, String>()
            private val o = mutableSetOf(target)
            private val a = mutableMapOf(target to "claude")
            override val names get() = n.toMap()
            override val owned get() = o.toSet()
            override val agents get() = a.toMap()
            override fun setName(id: UUID, name: String?) { if (name == null) n.remove(id) else n[id] = name }
            override fun claim(id: UUID) { o.add(id) }
            override fun unclaim(id: UUID) { o.remove(id); log.add("unclaim") }
            override fun setAgent(id: UUID, agentId: String?) {
                if (agentId == null) { if (a.remove(id) != null) log.add("forget") } else a[id] = agentId
            }
        }
        surface.sessionsOnServer = emptyList()
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        coord.terminateSession(target)
        advanceUntilIdle()

        assertTrue(log.precedes("forget", "unclaim"), "forgetSession (setAgent null) precedes unclaim")
    }

    // -------------------------------------------------------------------------
    // Ops are no-ops while recovering.
    // -------------------------------------------------------------------------

    @Test
    fun `createNewSession is a no-op while recovering`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val conn = FakeCoordinatorConnection(log).apply {
            alive = false
            forceReconnectGate = gate // park the recovery pass inside forceReconnect
        }
        val store = FakeOwnershipStore(log)
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        // Trigger auto-recovery: isAlive=false commits to a recovery pass, which
        // parks inside forceReconnect (gate is never completed), so isRecovering
        // stays true for the duration of the assertion.
        conn.onSendFailed?.invoke()
        testScheduler.runCurrent()

        assertTrue(coord.isRecovering.value, "coordinator is recovering")
        log.entries.clear()

        coord.createNewSession()
        testScheduler.runCurrent()

        assertFalse("rpc:session_create" in log, "createNewSession made no RPC while recovering")

        gate.complete(Unit) // let the parked recovery pass unwind so runTest finishes
        advanceUntilIdle()
    }

    // -------------------------------------------------------------------------
    // fetchSessions stale-prune: seed A,B,C; server returns only A; B,C are
    // unclaimed/un-named/un-agented and their cached terminals pruned.
    // -------------------------------------------------------------------------

    @Test
    fun `fetchSessions prunes ownership and cache for sessions gone from the server`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val a = UUID.fromString("00000000-0000-0000-0000-00000000000a")
        val b = UUID.fromString("00000000-0000-0000-0000-00000000000b")
        val c = UUID.fromString("00000000-0000-0000-0000-00000000000c")
        val store = FakeOwnershipStore(
            log,
            seedNames = mapOf(a to "Arya", b to "Bran", c to "Cersei"),
            seedOwned = setOf(a, b, c),
            seedAgents = mapOf(b to "claude", c to "codex"),
        )
        surface.sessionsOnServer = listOf(session(a, "Arya")) // only A survives
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        // Seed cached terminals for B and C.
        coord.terminalCache.put(b, relay.terminal.TerminalSessionVm())
        coord.terminalCache.put(c, relay.terminal.TerminalSessionVm())

        coord.fetchSessions()
        advanceUntilIdle()

        // A survives; B and C are pruned everywhere.
        assertTrue(store.owned.contains(a))
        assertFalse(store.owned.contains(b), "B unclaimed")
        assertFalse(store.owned.contains(c), "C unclaimed")
        assertFalse(store.names.containsKey(b), "B un-named")
        assertFalse(store.names.containsKey(c), "C un-named")
        assertFalse(store.agents.containsKey(b), "B un-agented")
        assertFalse(store.agents.containsKey(c), "C un-agented")
        assertNull(coord.terminalCache.view(b), "B terminal evicted")
        assertNull(coord.terminalCache.view(c), "C terminal evicted")
        assertFalse(coord.terminalCache.cachedIds.contains(b), "B not cached")
        assertFalse(coord.terminalCache.cachedIds.contains(c), "C not cached")
    }

    // -------------------------------------------------------------------------
    // REGRESSION (device-pin bug): a session this device owns but that lives under
    // a DIFFERENT token (absent from the token-scoped session_list, present in
    // session_list_all) must SURVIVE the prune. Previously the prune ran against the
    // token-scoped list and permanently unclaimed it → the session vanished from the
    // pane with no recovery.
    // -------------------------------------------------------------------------

    @Test
    fun `fetchSessions keeps owned sessions that exist under another token`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val a = UUID.fromString("00000000-0000-0000-0000-00000000000a") // this token
        val b = UUID.fromString("00000000-0000-0000-0000-00000000000b") // another token (alive)
        val gone = UUID.fromString("00000000-0000-0000-0000-00000000000d") // truly gone
        val store = FakeOwnershipStore(
            log,
            seedNames = mapOf(a to "Arya", b to "Bran", gone to "Ghost"),
            seedOwned = setOf(a, b, gone),
            seedAgents = mapOf(b to "claude"),
        )
        // Token-scoped list: only A (B is attached under another device's token now).
        surface.sessionsOnServer = listOf(session(a, "Arya"))
        // All-tokens list: A and B exist on the server; `gone` does not.
        surface.allSessionsOnServer = listOf(session(a, "Arya"), session(b, "Bran"))
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        coord.fetchSessions()
        advanceUntilIdle()

        // A and B survive (both exist server-side, on some token); `gone` is pruned.
        assertTrue(store.owned.contains(a), "A kept")
        assertTrue(store.owned.contains(b), "B kept (exists under another token)")
        assertFalse(store.owned.contains(gone), "truly-gone session pruned")
        assertTrue(store.names.containsKey(b), "B name kept")
        assertFalse(store.names.containsKey(gone), "gone un-named")
        assertTrue(store.agents.containsKey(b), "B agent kept")
    }

    // -------------------------------------------------------------------------
    // A failed session_list_all must NOT trigger any unclaim (avoid over-pruning
    // when the all-sessions RPC is unavailable).
    // -------------------------------------------------------------------------

    @Test
    fun `fetchSessions does not prune when listAllSessions is unavailable`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val a = UUID.fromString("00000000-0000-0000-0000-00000000000a")
        val b = UUID.fromString("00000000-0000-0000-0000-00000000000b")
        val store = FakeOwnershipStore(log, seedOwned = setOf(a, b))
        surface.sessionsOnServer = listOf(session(a, "Arya"))
        // Make SessionListAll return no usable response → listAllSessions throws →
        // existsIds is null → prune is skipped entirely.
        surface.failAllSessions = true
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        coord.fetchSessions()
        advanceUntilIdle()

        assertTrue(store.owned.contains(a), "A kept (no prune on all-sessions failure)")
        assertTrue(store.owned.contains(b), "B kept (no prune on all-sessions failure)")
    }

    // -------------------------------------------------------------------------
    // isApplicationLevelError classification parity.
    // -------------------------------------------------------------------------

    @Test
    fun `isApplicationLevelError treats unexpected-response as app-level and timeout as transport`() = runTest {
        val log = CallLog()
        val coord = SessionCoordinator(
            this,
            FakeCoordinatorConnection(log),
            SessionController(FakeConnectionSurface(log)),
            "tok",
            FakeOwnershipStore(log),
            config,
        )
        assertTrue(coord.isApplicationLevelError(SessionException("Unexpected server response: session not found")))
        assertFalse(coord.isApplicationLevelError(SessionException("The operation timed out.")))
    }

    // -------------------------------------------------------------------------
    // FIX 1 — onSessionStolen branches on wasActive (SharedSessionCoordinator.swift:601-625).
    //   Active steal   → raise the alert + clear active + unclaim + evict + fetch.
    //   Inactive steal → SILENT (no alert) + unclaim + evict + fetch.
    // -------------------------------------------------------------------------

    @Test
    fun `onSessionStolen of the ACTIVE session raises the alert and clears active`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val target = UUID.randomUUID()
        val store = FakeOwnershipStore(log, seedNames = mapOf(target to "Arya"), seedOwned = setOf(target))
        surface.sessionsOnServer = listOf(session(target, "Arya"))
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        // Make `target` the active session.
        coord.switchToSession(target)
        advanceUntilIdle()
        assertEquals(target, coord.activeSessionId.value)

        conn.deliver(ServerMessage.SessionStolen(target))
        advanceUntilIdle()

        // The displaced focused terminal → alert raised, active cleared.
        assertNull(coord.activeSessionId.value, "active cleared on steal of active session")
        assertEquals(target, coord.stolenAlert.value?.sessionId, "stolen alert raised for the active session")
        assertTrue(coord.sessionsStolen.value.contains(target), "session marked stolen")
        // Both branches: unclaim (sessionStolen unclaims internally here) + evict.
        assertFalse(store.owned.contains(target), "session unclaimed")
        assertNull(coord.terminalCache.view(target), "terminal evicted")
    }

    @Test
    fun `onSessionStolen of a NON-active session removes it AND raises the alert`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val active = UUID.randomUUID()
        val stolen = UUID.randomUUID()
        val store = FakeOwnershipStore(
            log,
            seedNames = mapOf(active to "Arya", stolen to "Bran"),
            seedOwned = setOf(active, stolen),
        )
        surface.sessionsOnServer = listOf(session(active, "Arya"), session(stolen, "Bran"))
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        // Make `active` the focused session; `stolen` is owned but only in the sidebar.
        coord.switchToSession(active)
        advanceUntilIdle()
        // Seed a cached terminal for the non-active stolen session.
        coord.terminalCache.put(stolen, relay.terminal.TerminalSessionVm())
        assertEquals(active, coord.activeSessionId.value)

        conn.deliver(ServerMessage.SessionStolen(stolen))
        advanceUntilIdle()

        // The reported bug fix: a stolen sidebar session must ALSO alert, not
        // just clean up silently.
        assertEquals(stolen, coord.stolenAlert.value?.sessionId, "stolen alert raised for the sidebar session")
        assertTrue(coord.sessionsStolen.value.contains(stolen), "non-active steal marks the stolen set")
        // The active session the user is looking at is untouched.
        assertEquals(active, coord.activeSessionId.value, "active session unchanged")
        // Ownership relinquished and the cached terminal evicted.
        assertFalse(store.owned.contains(stolen), "non-active stolen session unclaimed")
        assertNull(coord.terminalCache.view(stolen), "non-active stolen terminal evicted")
    }

    // -------------------------------------------------------------------------
    // FIX 2 — onReplayComplete keys on the message's sessionId, NOT the active VM
    //   (SharedSessionCoordinator.swift:211-214). A late replay_complete for idA
    //   while idB is active must end replay on idA, not idB.
    // -------------------------------------------------------------------------

    @Test
    fun `onReplayComplete keys on the message session id not the active vm`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val idA = UUID.randomUUID()
        val idB = UUID.randomUUID()
        val store = FakeOwnershipStore(log, seedOwned = setOf(idA, idB))
        surface.sessionsOnServer = listOf(session(idA, "Arya"), session(idB, "Bran"))
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        // idB becomes active (and is put into replay mode by switch).
        coord.switchToSession(idB)
        advanceUntilIdle()
        assertEquals(idB, coord.activeSessionId.value)

        // idA: a separate cached VM left mid-replay (e.g. a fast switch away).
        // Build it on the test scope so its input-prompt debounce launches on
        // the test scheduler, not the absent JVM `Dispatchers.Main`.
        val vmA = relay.terminal.TerminalSessionVm(scope = this)
        coord.terminalCache.put(idA, vmA)
        vmA.beginReplay()

        // Install sinks + size both VMs, then buffer distinct output in each.
        val flushedA = ArrayList<ByteArray>()
        val flushedB = ArrayList<ByteArray>()
        vmA.onTerminalOutput = { flushedA.add(it) }
        vmA.terminalReady()
        val vmB = coord.terminalCache.view(idB)!!
        vmB.onTerminalOutput = { flushedB.add(it) }
        vmB.terminalReady()
        flushedA.clear()
        flushedB.clear()
        vmA.receiveOutput(byteArrayOf(10, 11)) // buffered while replaying
        vmB.receiveOutput(byteArrayOf(20, 21)) // buffered while replaying

        // Deliver replay_complete for the NON-active idA.
        conn.deliver(ServerMessage.ReplayComplete(idA))
        advanceUntilIdle()

        assertEquals(1, flushedA.size, "idA endReplay flushed (it is the message's session)")
        assertEquals(listOf<Byte>(10, 11), flushedA[0].toList())
        assertTrue(flushedB.isEmpty(), "active idB did NOT flush on a replay_complete for idA")
    }

    // -------------------------------------------------------------------------
    // FIX 4 — app-level recovery (restore) failure evicts the active terminal +
    //   clears active (RecoveryController.swift:263-266). Drive a full recovery
    //   pass where reconnect+reauth succeed but the resume RPC returns an Error
    //   (→ app-level SessionException).
    // -------------------------------------------------------------------------

    @Test
    fun `app-level restore failure evicts and clears the active session`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val target = UUID.randomUUID()
        val store = FakeOwnershipStore(log, seedOwned = setOf(target))
        surface.sessionsOnServer = listOf(session(target, "Arya"))
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        // Establish `target` as the active session.
        coord.switchToSession(target)
        advanceUntilIdle()
        assertEquals(target, coord.activeSessionId.value)
        assertNotNull(coord.terminalCache.view(target))

        // Now stage recovery: the socket is dead, reconnect+reauth succeed, but the
        // resume RPC during restoreSession returns an Error → app-level failure.
        conn.alive = false
        surface.responder = { msg ->
            when (msg) {
                is ClientMessage.AuthRequest -> ServerMessage.AuthSuccess(1)
                is ClientMessage.SessionResume -> ServerMessage.Error(404, "session not found")
                is ClientMessage.SessionDetach -> ServerMessage.SessionDetached
                is ClientMessage.SessionList -> ServerMessage.SessionList(surface.sessionsOnServer)
                else -> null
            }
        }

        // Trigger an auto-recovery pass (reconnect at backoff[0]=0s succeeds).
        conn.onSendFailed?.invoke()
        advanceUntilIdle()

        // App-level branch fired: active cleared, stale terminal evicted, flag set.
        assertNull(coord.activeSessionId.value, "app-level restore failure cleared active")
        assertNull(coord.terminalCache.view(target), "stale active terminal evicted")
        assertTrue(coord.sessionAttachFailed.value, "sessionAttachFailed surfaced")
        assertFalse(coord.connectionTimedOut.value, "transport stayed up — not a connection timeout")
    }

    // -------------------------------------------------------------------------
    // SLEEP/WAKE TRAP (end-to-end) — a recovery pass whose reconnect succeeds
    // but whose resume FAILS leaves the transport healthy (pongs flow) while the
    // server handler has no attached PTY: it silently drops every typed byte.
    // The old bare isAlive() short-circuit locked that state in forever — every
    // later trigger just fetched. The fix: needsSessionRestore() detects the
    // stale attachment (generation mismatch) and the next trigger runs a
    // restore-only pass on the live socket: resume WITHOUT reconnect, and
    // WITHOUT a blind reauth (the handler is still authenticated; a second
    // auth_request would draw the server's 400 "Already authenticated").
    // -------------------------------------------------------------------------

    @Test
    fun `wake after a failed restore resumes on the live socket without reconnect or reauth`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val target = UUID.randomUUID()
        val store = FakeOwnershipStore(log, seedOwned = setOf(target))
        surface.sessionsOnServer = listOf(session(target, "Arya"))
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        // Mirror the real transport: reconnecting replaces the socket and bumps
        // the shared generation, invalidating the controller's auth/attachment
        // stamps (the server's new handler knows nothing about either).
        conn.onForceReconnect = { surface.generation += 1 }

        // 1) Healthy: the session is active with a current attachment.
        coord.switchToSession(target)
        advanceUntilIdle()
        assertEquals(target, coord.activeSessionId.value)
        assertFalse(coord.needsSessionRestore(), "fresh attachment needs no restore")

        // 2) Phone sleeps; the socket dies. Auto-recovery reconnects (generation
        // bump) and reauths fine, but the resume RPC gets no response — the 10 s
        // timeout makes it a TRANSPORT-shaped failure, so the active id survives
        // (only app-level failures clear it).
        conn.alive = false
        surface.responder = { msg ->
            when (msg) {
                is ClientMessage.AuthRequest -> ServerMessage.AuthSuccess(1)
                is ClientMessage.SessionDetach -> ServerMessage.SessionDetached
                is ClientMessage.SessionList -> ServerMessage.SessionList(surface.sessionsOnServer)
                else -> null // SessionResume never answered → timeout
            }
        }
        conn.onSendFailed?.invoke()
        advanceUntilIdle() // virtual time runs through the 10 s resume timeout

        // The trap state: transport healthy again, attachment orphaned.
        conn.alive = true
        assertEquals(target, coord.activeSessionId.value, "transport-shaped failure keeps the active id")
        assertTrue(coord.connectionTimedOut.value, "first pass surfaced the transport failure")
        assertFalse(coord.sessionAttachFailed.value)
        assertTrue(coord.needsSessionRestore(), "stale attachment detected on the live socket")

        // 3) Wake: the server answers again. The next foreground trigger must
        // RESTORE — not reconnect, not blind-reauth, not bare-fetch.
        surface.responder = { msg ->
            when (msg) {
                is ClientMessage.AuthRequest -> ServerMessage.AuthSuccess(1)
                is ClientMessage.SessionResume -> ServerMessage.SessionResumed(msg.sessionId)
                is ClientMessage.SessionDetach -> ServerMessage.SessionDetached
                is ClientMessage.SessionList -> ServerMessage.SessionList(surface.sessionsOnServer)
                is ClientMessage.SessionListAll -> ServerMessage.SessionListAll(surface.sessionsOnServer)
                else -> null
            }
        }
        log.entries.clear()
        coord.handleForegroundTransition()
        advanceUntilIdle()

        assertFalse("forceReconnect" in log, "alive-restore path never touches the transport")
        assertFalse(
            "rpc:auth_request" in log,
            "handler is still authenticated — a blind reauth would draw the server's 400",
        )
        assertTrue("rpc:session_resume" in log, "the orphaned session was resumed on the live socket")
        assertFalse(coord.needsSessionRestore(), "attachment is current again after the restore")
        assertEquals(target, coord.activeSessionId.value)
        assertFalse(coord.isRecovering.value)
    }

    // -------------------------------------------------------------------------
    // FOREGROUND REPAINT — returning to the app must always repaint the active
    // terminal, even when the transport still looks alive and the attachment
    // generation never changed (a plain background→foreground where the socket
    // quietly stalled but was never replaced). The bare handleForegroundTransition
    // short-circuits on isAlive()==true && !needsSessionRestore() → fetch only,
    // so the cached emulator is never re-fed and the grid stays blank (the
    // "reopen lands on a dead terminal" bug). restoreActiveOnForeground() forces
    // a resume so the server replays scrollback into the live emulator.
    // -------------------------------------------------------------------------

    @Test
    fun `restoreActiveOnForeground resumes and repaints the active session even when alive`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log).apply { alive = true } // transport looks fine
        val target = UUID.randomUUID()
        val store = FakeOwnershipStore(log, seedOwned = setOf(target))
        surface.sessionsOnServer = listOf(session(target, "Arya"))
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        coord.switchToSession(target)
        advanceUntilIdle()
        assertEquals(target, coord.activeSessionId.value)
        // Fresh attachment + alive socket: the existing foreground path would NOT
        // restore (it short-circuits to fetch). This is exactly the dead-terminal case.
        assertFalse(coord.needsSessionRestore(), "attachment is current — bare foreground would only fetch")
        log.entries.clear()

        coord.restoreActiveOnForeground()
        advanceUntilIdle()

        // The active session is resumed so the server replays scrollback into the
        // live emulator (the repaint), and output is re-wired to the same VM.
        assertTrue("rpc:session_resume" in log, "foreground forces a resume to repaint the live terminal")
        assertTrue(log.precedes("rpc:session_resume", "wire"), "output re-wired after the resume")
        assertEquals(target, coord.activeSessionId.value, "active session unchanged")
        assertFalse(coord.isRecovering.value, "a healthy-socket repaint never flashes recovery UI")
    }

    @Test
    fun `restoreActiveOnForeground with no active session never resumes (defers to recovery fetch)`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        // Alive socket → the recovery path short-circuits to a fetch; no resume.
        val conn = FakeCoordinatorConnection(log).apply { alive = true }
        val store = FakeOwnershipStore(log)
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        coord.restoreActiveOnForeground()
        advanceUntilIdle()

        assertFalse("rpc:session_resume" in log, "nothing to resume with no active session")
        assertFalse("forceReconnect" in log, "alive socket: recovery short-circuits to fetch, no reconnect")
        assertNull(coord.activeSessionId.value)
        assertFalse(coord.isRecovering.value)
    }

    @Test
    fun `restoreActiveOnForeground defers to recovery when the socket is dead`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val conn = FakeCoordinatorConnection(log).apply {
            alive = false
            forceReconnectGate = gate // park the recovery pass so isRecovering stays true
        }
        val target = UUID.randomUUID()
        val store = FakeOwnershipStore(log, seedOwned = setOf(target))
        surface.sessionsOnServer = listOf(session(target, "Arya"))
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)
        coord.switchToSession(target)
        advanceUntilIdle()

        // Socket is dead now. A foreground signal must route through full recovery
        // (reconnect→reauth→resume), NOT a bare resume on a dead socket.
        conn.alive = false
        log.entries.clear()
        coord.restoreActiveOnForeground()
        testScheduler.runCurrent()

        assertTrue(coord.isRecovering.value, "dead socket drives full recovery, not a bare resume")
        assertTrue("forceReconnect" in log, "recovery reconnects the dead transport")

        gate.complete(Unit) // unwind the parked pass so runTest finishes
        advanceUntilIdle()
    }

    // -------------------------------------------------------------------------
    // RE-SELECT ACTIVE = RESTORE — tapping the already-active session in the
    // sidebar must force a resume (escape hatch for a stale terminal), instead of
    // the old early-return no-op that left the user stuck with a blank grid.
    // -------------------------------------------------------------------------

    @Test
    fun `switchToSession on the active id forces a restoring resume`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log).apply { alive = true }
        val target = UUID.randomUUID()
        val store = FakeOwnershipStore(log, seedOwned = setOf(target))
        surface.sessionsOnServer = listOf(session(target, "Arya"))
        val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

        coord.switchToSession(target)
        advanceUntilIdle()
        assertEquals(target, coord.activeSessionId.value)
        log.entries.clear()

        // Re-tap the SAME session: must resume (repaint), not no-op.
        coord.switchToSession(target)
        advanceUntilIdle()

        assertTrue("rpc:session_resume" in log, "re-selecting the active session resumes it (repaint escape hatch)")
        assertEquals(target, coord.activeSessionId.value)
    }

    // -------------------------------------------------------------------------
    // OP-IN-FLIGHT RACES — session ops (create / switch / attach) put the
    // controller and _activeSessionId in transiently mismatched states at their
    // suspension points. needsSessionRestore() must defer to the in-flight op
    // instead of misreading the gap as a stale attachment; otherwise a recovery
    // pass racing the op resumes the OLD active id concurrently with the op's
    // own resume — two resumes on one connection (the server holds ONE attached
    // PTY per handler) → black terminal / output routed to the wrong VM.
    // -------------------------------------------------------------------------

    // Both race tests freeze the injected clock: every non-force fetchSessions
    // after the first is then debounced (500 ms window never elapses), so the
    // recovery short-circuit's fetch issues no RPC while an op's RPC is parked.
    // That isolation matters — sendAndWaitForResponse matches ANY response type
    // (single-request-in-flight design, Swift parity), so a list result arriving
    // while a resume/create awaits would cross-deliver into the parked guard.

    @Test
    fun `needsSessionRestore defers to a create parked mid-flight`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val a = UUID.randomUUID()
        val store = FakeOwnershipStore(log, seedOwned = setOf(a))
        surface.sessionsOnServer = listOf(
            session(a, "Arya"),
            session(FakeConnectionSurface.NEW_SESSION_ID, "Bran"),
        )
        val clock = newClock() // frozen — see comment above
        val coord = SessionCoordinator(
            this, conn, SessionController(surface), "tok", store, config,
            nowMs = { clock.ms },
        )

        coord.switchToSession(a)
        advanceUntilIdle()
        assertEquals(a, coord.activeSessionId.value)
        assertFalse(coord.needsSessionRestore())
        log.entries.clear()

        // Park the create between its detach (controller.sessionId is now null)
        // and the create response (_activeSessionId still holds `a`) — the
        // mismatched window a concurrent trigger used to misread as stale.
        val createGate = kotlinx.coroutines.CompletableDeferred<Unit>()
        surface.sendGate = { msg ->
            if (msg is ClientMessage.SessionCreate) createGate.await()
        }
        val create = launch { coord.createNewSession() }
        testScheduler.runCurrent()

        assertEquals(a, coord.activeSessionId.value, "create has not committed yet")
        assertFalse(
            coord.needsSessionRestore(),
            "an in-flight op is not a stale attachment — it is establishing a fresh one",
        )

        // A recovery trigger inside the window must short-circuit to a fetch,
        // never resume the old active id under the op's feet.
        coord.handleForegroundTransition()
        advanceUntilIdle()
        assertFalse("rpc:session_resume" in log, "no spurious restore raced the create")

        createGate.complete(Unit)
        advanceUntilIdle()
        create.join()

        assertEquals(FakeConnectionSurface.NEW_SESSION_ID, coord.activeSessionId.value)
        assertFalse(coord.needsSessionRestore(), "committed create is a current attachment")
        assertFalse("rpc:session_resume" in log, "nothing ever resumed")
        assertFalse(coord.isRecovering.value)
    }

    @Test
    fun `switch racing a parked alive probe wins - recovery defers to the op`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log).apply { alive = true }
        val a = UUID.randomUUID()
        val b = UUID.randomUUID()
        val store = FakeOwnershipStore(log, seedOwned = setOf(a, b))
        surface.sessionsOnServer = listOf(session(a, "Arya"), session(b, "Bran"))
        val clock = newClock() // frozen — see comment above
        val coord = SessionCoordinator(
            this, conn, SessionController(surface), "tok", store, config,
            nowMs = { clock.ms },
        )

        coord.switchToSession(a)
        advanceUntilIdle()
        assertEquals(a, coord.activeSessionId.value)

        // Sleep/wake trap: the socket was replaced — auth + attachment stamps stale.
        surface.generation += 1
        assertTrue(coord.needsSessionRestore(), "stale attachment detected")

        // Recovery parks inside the isAlive probe — PRE-commit, so isRecovering
        // is still false and the switch below is not gated at entry. This is the
        // exact window the race lives in.
        val aliveGate = kotlinx.coroutines.CompletableDeferred<Unit>()
        conn.isAliveGate = aliveGate
        coord.handleForegroundTransition()
        testScheduler.runCurrent()
        assertFalse(coord.isRecovering.value, "probe is pre-commit")

        // The user switches to B; park its resume so the op is still mid-flight
        // when the probe resumes. Record every resume's target id.
        val resumeTargets = mutableListOf<UUID>()
        val resumeGate = kotlinx.coroutines.CompletableDeferred<Unit>()
        surface.sendGate = { msg ->
            if (msg is ClientMessage.SessionResume) {
                resumeTargets.add(msg.sessionId)
                if (msg.sessionId == b) resumeGate.await()
            }
        }
        val switch = launch { coord.switchToSession(b) }
        testScheduler.runCurrent()
        assertEquals(listOf(b), resumeTargets, "the switch's resume is in flight")

        // Probe resumes mid-op: recovery must defer (fetch only), NOT resume A
        // on the same connection the switch is resuming B on.
        aliveGate.complete(Unit)
        testScheduler.runCurrent()
        assertEquals(listOf(b), resumeTargets, "recovery deferred — no second resume of A")

        resumeGate.complete(Unit)
        advanceUntilIdle()
        switch.join()

        assertEquals(listOf(b), resumeTargets, "exactly one resume — the switch's")
        assertEquals(b, coord.activeSessionId.value)
        assertFalse(coord.needsSessionRestore(), "switch re-established a current attachment")
        assertFalse(coord.isRecovering.value)
    }

    // -------------------------------------------------------------------------
    // notifyUserActivity — input over a possibly-dead socket drives a fast
    // liveness probe + user recovery, because OkHttp send() returning true does
    // not prove delivery. A keystroke after health has gone stale probes; one on
    // a recently-healthy connection does not; bursts are throttled.
    // -------------------------------------------------------------------------

    @Test
    fun `notifyUserActivity probes when health is stale and is a no-op while fresh`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        // Socket reports alive so triggerUserRecovery's isAlive short-circuit just
        // fetches (no reconnect) — we only need to observe that a pass was driven.
        val conn = FakeCoordinatorConnection(log).apply { alive = true }
        val clock = newClock()
        val store = FakeOwnershipStore(log)
        val coord = SessionCoordinator(
            this, conn, SessionController(surface), "tok", store, config,
            nowMs = { clock.ms },
        )

        // connect() stamps lastHealthyAtMs = now, so an immediate keystroke is fresh.
        coord.connect()
        advanceUntilIdle()
        val listsAfterConnect = log.entries.count { it == "rpc:session_list" }

        // Fresh health → no probe (no extra isAlive-driven fetch).
        coord.notifyUserActivity()
        advanceUntilIdle()
        assertEquals(
            listsAfterConnect,
            log.entries.count { it == "rpc:session_list" },
            "no probe while health is fresh",
        )

        // Let health go stale (past ACTIVITY_HEALTH_STALE_MS = 12 s).
        clock.ms += 13_000
        coord.notifyUserActivity()
        advanceUntilIdle()
        assertTrue(
            log.entries.count { it == "rpc:session_list" } > listsAfterConnect,
            "stale health drove a recovery pass (alive short-circuit → fetch)",
        )
    }

    @Test
    fun `notifyUserActivity throttles a burst of keystrokes to one probe`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log).apply { alive = true }
        val clock = newClock()
        val store = FakeOwnershipStore(log)
        val coord = SessionCoordinator(
            this, conn, SessionController(surface), "tok", store, config,
            nowMs = { clock.ms },
        )
        coord.connect()
        advanceUntilIdle()
        // Make health stale so probes are eligible.
        clock.ms += 13_000
        val baseline = log.entries.count { it == "rpc:session_list" }

        // A burst of keystrokes within the throttle window → exactly one probe.
        repeat(5) { coord.notifyUserActivity() }
        advanceUntilIdle()
        assertEquals(
            baseline + 1,
            log.entries.count { it == "rpc:session_list" },
            "burst within the throttle window probes once",
        )
    }

    @Test
    fun `notifyUserActivity is a no-op while a recovery pass is in flight`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val conn = FakeCoordinatorConnection(log).apply {
            alive = false
            forceReconnectGate = gate // park the recovery pass inside forceReconnect
        }
        val clock = newClock()
        val store = FakeOwnershipStore(log)
        val coord = SessionCoordinator(
            this, conn, SessionController(surface), "tok", store, config,
            nowMs = { clock.ms },
        )

        // Health is stale (never connected), so the keystroke is probe-eligible.
        // The first notifyUserActivity dispatches a recovery that parks in
        // forceReconnect with the dispatch lock held.
        coord.notifyUserActivity()
        testScheduler.runCurrent()
        assertTrue(coord.isRecovering.value, "first keystroke drove a recovery pass")
        val reconnects = log.entries.count { it == "forceReconnect" }

        // Keystrokes during the in-flight pass (past the 5 s throttle so only the
        // dispatch lock can stop them) must not dispatch a second pass.
        clock.ms += 6_000
        coord.notifyUserActivity()
        testScheduler.runCurrent()
        assertEquals(
            reconnects,
            log.entries.count { it == "forceReconnect" },
            "keystroke during in-flight recovery did not dispatch a second pass",
        )

        gate.complete(Unit) // unwind the parked pass so runTest finishes
        advanceUntilIdle()
    }

    // -------------------------------------------------------------------------
    // FIX 5 — fetchSessions 0.5 s debounce keyed on the injected clock + isLoading.
    //   First fetch passes; a second within 500 ms is skipped; advancing the clock
    //   past 500 ms lets it through again.
    // -------------------------------------------------------------------------

    @Test
    fun `fetchSessions debounces within 500ms and toggles isLoading`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val clock = newClock()
        val a = UUID.fromString("00000000-0000-0000-0000-00000000000a")
        val store = FakeOwnershipStore(log, seedOwned = setOf(a))
        surface.sessionsOnServer = listOf(session(a, "Arya"))
        val coord = SessionCoordinator(
            this, conn, SessionController(surface), "tok", store, config,
            nowMs = { clock.ms },
        )

        // First fetch always passes the gate (lastFetchMs == null).
        coord.fetchSessions()
        advanceUntilIdle()
        assertFalse(coord.isLoading.value, "isLoading is false after the fetch returns")
        val firstCount = log.entries.count { it == "rpc:session_list" }
        assertEquals(1, firstCount, "first fetch issued one list RPC")

        // Second fetch only 200 ms later → debounced (no new RPC).
        clock.ms += 200
        coord.fetchSessions()
        advanceUntilIdle()
        assertEquals(firstCount, log.entries.count { it == "rpc:session_list" }, "debounced fetch issued no RPC")

        // Advance past the 500 ms window → the next fetch goes through.
        clock.ms += 400 // total 600 ms since the first fetch
        coord.fetchSessions()
        advanceUntilIdle()
        assertEquals(firstCount + 1, log.entries.count { it == "rpc:session_list" }, "fetch past the window issued an RPC")
    }

    // -------------------------------------------------------------------------
    // computeActiveSessions — pure filter+sort parity with the Swift
    // `activeSessions` computed property (SharedSessionCoordinator.swift:92-96):
    //   sessions.filter { !$0.state.isTerminal && ownedSessionIds.contains($0.id) }
    //           .sorted { $0.createdAt < $1.createdAt }
    // i.e. keep non-terminal sessions this device owns, sorted by createdAt ASC.
    // -------------------------------------------------------------------------

    private fun sessionWith(id: UUID, state: SessionState, createdAt: Double): SessionInfo =
        SessionInfo(
            id = id,
            name = null,
            state = state,
            tokenId = "tok",
            createdAt = createdAt,
            cols = 80u,
            rows = 24u,
            activity = null,
            agent = null,
        )

    @Test
    fun `computeActiveSessions keeps only owned non-terminal sessions sorted by createdAt ascending`() {
        val ownedActiveLate = UUID.fromString("00000000-0000-0000-0000-000000000001")
        val ownedActiveEarly = UUID.fromString("00000000-0000-0000-0000-000000000002")
        val ownedActiveMid = UUID.fromString("00000000-0000-0000-0000-000000000003")
        val ownedTerminal = UUID.fromString("00000000-0000-0000-0000-000000000004")
        val unownedActive = UUID.fromString("00000000-0000-0000-0000-000000000005")

        val all = listOf(
            sessionWith(ownedActiveLate, SessionState.ACTIVE_ATTACHED, createdAt = 300.0),
            sessionWith(ownedActiveEarly, SessionState.ACTIVE_DETACHED, createdAt = 100.0),
            sessionWith(ownedActiveMid, SessionState.RESUMING, createdAt = 200.0),
            // Owned but TERMINAL — must be filtered out.
            sessionWith(ownedTerminal, SessionState.EXITED, createdAt = 50.0),
            // Non-terminal but NOT owned — must be filtered out.
            sessionWith(unownedActive, SessionState.ACTIVE_ATTACHED, createdAt = 10.0),
        )
        val owned = setOf(ownedActiveLate, ownedActiveEarly, ownedActiveMid, ownedTerminal)

        val result = SessionCoordinator.computeActiveSessions(all, owned)

        // Only the three owned non-terminal sessions survive, ascending by createdAt
        // (early=100 → mid=200 → late=300). Swift sorts `$0.createdAt < $1.createdAt`.
        assertEquals(
            listOf(ownedActiveEarly, ownedActiveMid, ownedActiveLate),
            result.map { it.id },
        )
    }

    @Test
    fun `computeActiveSessions filters every terminal state even when owned`() {
        val survivor = UUID.fromString("00000000-0000-0000-0000-0000000000a0")
        val unowned = UUID.fromString("00000000-0000-0000-0000-0000000000b0")
        val terminalStates = listOf(
            SessionState.EXITED, SessionState.FAILED, SessionState.TERMINATED, SessionState.EXPIRED,
        )
        // One OWNED session in each terminal state (all must drop despite being owned),
        // one OWNED non-terminal survivor, plus an unowned non-terminal (must drop).
        val terminals = terminalStates.mapIndexed { i, st ->
            sessionWith(UUID.randomUUID(), st, createdAt = i.toDouble())
        }
        val all = terminals +
            sessionWith(unowned, SessionState.ACTIVE_ATTACHED, createdAt = 99.0) +
            sessionWith(survivor, SessionState.ACTIVE_ATTACHED, createdAt = 5.0)
        // Own every terminal session and the survivor — but NOT `unowned` — so the
        // terminal-state filter is the only thing dropping the terminals.
        val ownedSet = (terminals.map { it.id } + survivor).toSet()

        val result = SessionCoordinator.computeActiveSessions(all, ownedSet)

        assertEquals(listOf(survivor), result.map { it.id })
    }
}
