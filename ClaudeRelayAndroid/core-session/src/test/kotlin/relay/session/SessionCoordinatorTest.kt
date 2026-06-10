package relay.session

import kotlinx.coroutines.ExperimentalCoroutinesApi
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

        override fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID {
            val id = UUID.randomUUID()
            subscribers[id] = handler
            return id
        }

        override fun removeSubscriber(id: UUID) { subscribers.remove(id) }

        override suspend fun send(message: ClientMessage) {
            log.add("rpc:${message.typeString}")
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
        override suspend fun forceReconnect() { log.add("forceReconnect"); forceReconnectGate?.await() }
        override suspend fun disconnect() { log.add("disconnect") }
        override suspend fun isAlive(): Boolean = alive
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
    fun `onSessionStolen of a NON-active session is silent but still unclaims and evicts`() = runTest {
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

        // SILENT: no alert, not added to the stolen set; active is untouched.
        assertNull(coord.stolenAlert.value, "no stolen alert for a non-active session")
        assertFalse(coord.sessionsStolen.value.contains(stolen), "non-active steal does not mark the stolen set")
        assertEquals(active, coord.activeSessionId.value, "active session unchanged")
        // But ownership IS relinquished and the cached terminal evicted.
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
