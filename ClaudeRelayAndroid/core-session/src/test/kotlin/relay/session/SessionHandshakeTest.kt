package relay.session

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.net.SessionController
import relay.protocol.ActivityState
import relay.protocol.ConnectionConfig
import relay.protocol.SessionInfo
import relay.protocol.SessionState
import java.util.UUID

/**
 * Regression suite for [SessionHandshake] — the single sequence that populates
 * the session pane (connect → authenticate → ask for the sessions this client
 * owns → render).
 *
 * Kotlin mirror of Tests/ClaudeRelayClientTests/SessionHandshakeTests.swift. The
 * properties pinned here are the ones that let the "empty pane on relaunch" bug
 * survive five shipped fixes, and none of them are about the happy path: does
 * recovery stay out of the way, does the gate always clear, does a total failure
 * stay visible, is LAUNCH silent about sessions lost while the app was closed.
 *
 * Uses the shared doubles in CoordinatorTestDoubles.kt, so the handshake is
 * exercised over the SAME fake transport + REAL [SessionController] the
 * coordinator's own op-ordering suite uses.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionHandshakeTest {

    private val config = ConnectionConfig(name = "test", host = "127.0.0.1")

    private val ARYA: UUID = UUID.fromString("00000000-0000-0000-0000-0000000000a1")
    private val BRAN: UUID = UUID.fromString("00000000-0000-0000-0000-0000000000b2")

    private fun session(id: UUID, name: String? = null, token: String = "tok"): SessionInfo =
        SessionInfo(
            id = id,
            name = name,
            state = SessionState.ACTIVE_ATTACHED,
            tokenId = token,
            createdAt = 0.0,
            cols = 80u,
            rows = 24u,
            activity = ActivityState.ACTIVE,
            agent = null,
        )

    /** The coordinator + its collaborators, so each test can reach the fakes. */
    private class Harness(
        val log: CallLog,
        val surface: FakeConnectionSurface,
        val conn: FakeCoordinatorConnection,
        val coord: SessionCoordinator,
    )

    private fun harness(scope: kotlinx.coroutines.CoroutineScope): Harness {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val coord = SessionCoordinator(
            scope = scope,
            connection = conn,
            sessionController = SessionController(surface),
            token = "tok",
            ownershipStore = FakeOwnershipStore(log),
            config = config,
        )
        return Harness(log, surface, conn, coord)
    }

    // MARK: - The flow itself

    /**
     * The whole point, end to end: one call authenticates and then lists, in that
     * order, and the pane ends up holding exactly what the server says this token
     * owns. Ordering is asserted, not assumed — a `session_list` that overtakes
     * `auth_request` draws the server's "not authenticated" reject, which is one
     * of the ways the pane came up empty.
     */
    @Test
    fun `launch handshake authenticates then lists and renders the pane`() = runTest {
        val h = harness(this)
        h.surface.sessionsOnServer = listOf(session(ARYA, "Arya"), session(BRAN, "Bran"))

        val ok = h.coord.performHandshake(SessionHandshake.Reason.LAUNCH)
        advanceUntilIdle()

        assertTrue(ok, "the handshake must report success")
        assertTrue(h.log.precedes("rpc:auth_request", "rpc:session_list"), "auth completes BEFORE the list")
        assertEquals(setOf(ARYA, BRAN), h.coord.activeSessions.value.map { it.id }.toSet())
        assertFalse(h.coord.isPerformingHandshake.value, "the gate must clear on success")
    }

    /**
     * Owning zero sessions is a legitimate ANSWER, not a failure: it must not
     * retry (which would delay the empty pane behind ~3.75 s of backoff) and must
     * not surface an error.
     */
    @Test
    fun `an empty owned list is a success not a retry`() = runTest {
        val h = harness(this)
        h.surface.sessionsOnServer = emptyList()

        val ok = h.coord.performHandshake(SessionHandshake.Reason.LAUNCH)
        advanceUntilIdle()

        assertTrue(ok)
        assertTrue(h.coord.activeSessions.value.isEmpty())
        assertNull(h.coord.errorMessage.value, "zero sessions is an answer, not an error")
        assertEquals(1, h.log.entries.count { it == "rpc:session_list" }, "must not retry a successful list")
    }

    /**
     * A receive-loop failure drops the socket WITHOUT bumping the connection
     * generation, so "authenticated" can be reported over a socket that is gone.
     * The handshake must notice via the cheap `isConnected` read and reconnect
     * FIRST — reconnect → auth → list, in that order.
     */
    @Test
    fun `a dead socket costs a reconnect not the contents of the pane`() = runTest {
        val h = harness(this)
        h.surface.sessionsOnServer = listOf(session(ARYA, "Arya"))
        h.conn.connected = false
        h.conn.onForceReconnect = { h.conn.connected = true }

        val ok = h.coord.performHandshake(SessionHandshake.Reason.WAKE)
        advanceUntilIdle()

        assertTrue(ok)
        assertTrue(h.log.precedes("forceReconnect", "rpc:auth_request"), "reconnect BEFORE authenticating")
        assertTrue(h.log.precedes("rpc:auth_request", "rpc:session_list"))
        assertEquals(listOf(ARYA), h.coord.activeSessions.value.map { it.id })
    }

    // MARK: - The recovery gate (the #43 root cause, generalised)

    /**
     * The cold-launch bug: a foreground/network trigger fires while the launch
     * handshake is mid-flight, recovery calls `forceReconnect()`, and the in-flight
     * `session_list` dies with the socket. Recovery must refuse to run while a
     * handshake owns the connection.
     *
     * The socket is staged as NOT alive, so a recovery pass that did run would log
     * `forceReconnect` — its absence is the proof.
     */
    @Test
    fun `user recovery is blocked while the handshake is in flight`() = runTest {
        val h = harness(this)
        h.conn.alive = false // a recovery pass that runs WILL reconnect
        val listGate = CompletableDeferred<Unit>()
        h.surface.sendGate = { message ->
            if (message is relay.protocol.ClientMessage.SessionList) listGate.await()
        }

        val pass = async { h.coord.performHandshake(SessionHandshake.Reason.LAUNCH) }
        advanceUntilIdle()
        assertTrue(h.coord.isPerformingHandshake.value, "handshake should be parked in session_list")

        h.coord.triggerUserRecovery()
        advanceUntilIdle()

        assertFalse("forceReconnect" in h.log, "recovery must not reconnect under a live handshake")
        assertTrue(h.coord.isPerformingHandshake.value, "the handshake must not have been pre-empted")

        listGate.complete(Unit)
        assertTrue(pass.await())
    }

    @Test
    fun `auto recovery is blocked while the handshake is in flight`() = runTest {
        val h = harness(this)
        h.conn.alive = false
        val listGate = CompletableDeferred<Unit>()
        h.surface.sendGate = { message ->
            if (message is relay.protocol.ClientMessage.SessionList) listGate.await()
        }

        val pass = async { h.coord.performHandshake(SessionHandshake.Reason.LAUNCH) }
        advanceUntilIdle()

        h.coord.recoveryController.scheduleAutoRecovery()
        advanceUntilIdle()

        assertFalse("forceReconnect" in h.log, "auto-recovery must not pre-empt a handshake")

        listGate.complete(Unit)
        assertTrue(pass.await())
    }

    /**
     * Once the handshake finishes — success OR total failure — the gate must
     * clear, or recovery is dead for the rest of the session.
     */
    @Test
    fun `the gate clears after a total failure`() = runTest {
        val h = harness(this)
        h.surface.failSessionList = true

        val ok = h.coord.performHandshake(SessionHandshake.Reason.LAUNCH)
        advanceUntilIdle()

        assertFalse(ok, "every attempt failed: the handshake cannot succeed")
        assertFalse(
            h.coord.isPerformingHandshake.value,
            "the gate must clear on failure — a stuck gate permanently blocks recovery",
        )
    }

    @Test
    fun `tearDown clears the gate and releases joiners`() = runTest {
        val h = harness(this)
        val listGate = CompletableDeferred<Unit>()
        h.surface.sendGate = { message ->
            if (message is relay.protocol.ClientMessage.SessionList) listGate.await()
        }

        val pass = async { h.coord.performHandshake(SessionHandshake.Reason.LAUNCH) }
        advanceUntilIdle()
        assertTrue(h.coord.isPerformingHandshake.value)

        h.coord.tearDown()
        advanceUntilIdle()

        assertFalse(h.coord.isPerformingHandshake.value, "teardown must not leave the recovery gate armed")
        assertFalse(pass.await(), "a caller waiting on the abandoned pass must be released, not hang")
    }

    /**
     * The Kotlin-only hazard in the single-flight slot: `launch` on an
     * already-cancelled scope never runs the body, so a `finally` placed *inside*
     * the body never fires. That left the deferred incomplete — `perform()` and
     * every joiner hung forever — and the recovery gate armed, permanently
     * blocking recovery on a coordinator that was only trying to shut down. The
     * release therefore hangs off the job's completion, which fires even for a job
     * that is born cancelled.
     */
    @Test
    fun `a pass on a cancelled scope fails fast instead of hanging with the gate armed`() = runTest {
        val dead = CoroutineScope(coroutineContext + Job())
        val h = harness(dead)
        dead.cancel()

        val ok = withTimeoutOrNull(5_000) { h.coord.performHandshake(SessionHandshake.Reason.LAUNCH) }

        assertEquals(false, ok, "a pass that can never run must report failure, not hang")
        assertFalse(h.coord.isPerformingHandshake.value, "the gate must not stay armed")
        // And a later caller must not be stuck behind the abandoned slot either.
        assertEquals(
            false,
            withTimeoutOrNull(5_000) { h.coord.performHandshake(SessionHandshake.Reason.WAKE) },
            "the slot must have been released, so a new caller starts its own pass",
        )
    }

    // MARK: - No silent failure

    /**
     * The old launch path caught every list error and dropped it, so one transient
     * RPC failure meant a permanently blank pane with no message and no retry. A
     * handshake that exhausts its retries must say so — but must NOT set the
     * terminal `connectionTimedOut` flag, which tears the workspace down and takes
     * the user's ability to retry with it.
     */
    @Test
    fun `total failure surfaces an error without tearing the workspace down`() = runTest {
        val h = harness(this)
        h.surface.failSessionList = true

        h.coord.performHandshake(SessionHandshake.Reason.LAUNCH)
        advanceUntilIdle()

        assertNotNull(h.coord.errorMessage.value, "an exhausted handshake must surface an error")
        assertTrue(
            h.coord.errorMessage.value!!.contains("Couldn't load your sessions"),
            "the message must name what failed, got: ${h.coord.errorMessage.value}",
        )
        assertFalse(h.coord.connectionTimedOut.value, "a failed list fetch must not dismiss the workspace")
    }

    /**
     * Every attempt retries — the common failure is a socket replaced milliseconds
     * ago, which succeeds on the next try. A single-shot handshake would blank the
     * pane on exactly the race this whole type exists to survive.
     */
    @Test
    fun `a transient failure is retried`() = runTest {
        val h = harness(this)
        // The first `session_list` fails; the second (the retry) succeeds. The
        // responder — not `failSessionList` — drives this, because the flag is read
        // when the reply is built and the test needs the change to apply per call.
        var lists = 0
        h.surface.responder = { message ->
            when (message) {
                is relay.protocol.ClientMessage.AuthRequest ->
                    relay.protocol.ServerMessage.AuthSuccess(protocolVersion = 1, tokenId = "tok")
                is relay.protocol.ClientMessage.SessionList -> {
                    lists += 1
                    if (lists == 1) relay.protocol.ServerMessage.Error(code = 500, message = "transient")
                    else relay.protocol.ServerMessage.SessionList(listOf(session(ARYA, "Arya")))
                }
                else -> null
            }
        }

        val ok = h.coord.performHandshake(SessionHandshake.Reason.LAUNCH)
        advanceUntilIdle()

        assertTrue(ok, "the second attempt must succeed")
        assertEquals(2, lists, "the failed list must be retried exactly once here")
        assertEquals(listOf(ARYA), h.coord.activeSessions.value.map { it.id })
        assertTrue(
            "disconnect" in h.log,
            "a failed attempt drops the socket so the retry starts from a fresh, re-authenticated one",
        )
        assertEquals(
            2, h.log.entries.count { it == "rpc:auth_request" },
            "the retry re-authenticates rather than reusing auth bound to the dropped socket",
        )
    }

    @Test
    fun `the retry schedule is front-loaded`() {
        // Five attempts over ~3.75 s: the first must not be delayed (launch
        // latency is user-visible), the tail accommodates a server still coming up.
        assertEquals(5, SessionHandshake.RETRY_DELAYS_MS.size)
        assertEquals(0L, SessionHandshake.RETRY_DELAYS_MS.first())
    }

    /**
     * A rejected token can never be accepted by retrying, and hammering the server
     * trips its rate limiter. Stop after one attempt and tell the user.
     */
    @Test
    fun `a rejected token stops immediately instead of retrying`() = runTest {
        val h = harness(this)
        h.surface.responder = { message ->
            if (message is relay.protocol.ClientMessage.AuthRequest) {
                relay.protocol.ServerMessage.AuthFailure("invalid token")
            } else {
                null
            }
        }

        val ok = h.coord.performHandshake(SessionHandshake.Reason.LAUNCH)
        advanceUntilIdle()

        assertFalse(ok)
        assertEquals(
            1, h.log.entries.count { it == "rpc:auth_request" },
            "a rejected token must not be retried",
        )
        assertNotNull(h.coord.errorMessage.value)
    }

    // MARK: - Launch is silent, wake announces

    /**
     * The product requirement, directly: a cold launch must NOT report sessions
     * another client took while this app was closed. There is no "before" worth
     * diffing on launch, and reporting it every time is noise.
     */
    @Test
    fun `launch never announces a session taken while the app was closed`() = runTest {
        val h = harness(this)
        // Seed the pane, then have the server report the session as no longer ours.
        h.surface.sessionsOnServer = listOf(session(ARYA, "Arya"))
        h.coord.performHandshake(SessionHandshake.Reason.LAUNCH)
        advanceUntilIdle()
        h.surface.sessionsOnServer = emptyList()

        h.coord.performHandshake(SessionHandshake.Reason.LAUNCH)
        advanceUntilIdle()

        assertTrue(h.coord.activeSessions.value.isEmpty(), "the pane follows the server")
        assertNull(h.coord.stolenAlert.value, "launch must stay silent about what was lost while closed")
    }

    /**
     * The other half of the same requirement: when the app was ALREADY open and
     * comes back, a session that dropped out of our list WAS taken by another
     * device — and we missed the live `session_stolen` push because our socket was
     * down, so this is the only place the user learns about it.
     */
    @Test
    fun `wake announces a session that is no longer ours`() = runTest {
        val h = harness(this)
        h.surface.sessionsOnServer = listOf(session(ARYA, "Arya"), session(BRAN, "Bran"))
        h.coord.performHandshake(SessionHandshake.Reason.LAUNCH)
        advanceUntilIdle()
        h.surface.sessionsOnServer = listOf(session(BRAN, "Bran"))

        h.coord.performHandshake(SessionHandshake.Reason.WAKE)
        advanceUntilIdle()

        val alert = h.coord.stolenAlert.value
        assertNotNull(alert, "wake must report the session another device attached")
        assertEquals(ARYA, alert!!.sessionId)
        assertEquals("Arya", alert.sessionName, "the name must come from the pre-fetch snapshot")
    }

    @Test
    fun `firstLostSession is the one missing from the server list`() {
        val before = listOf(
            SessionHandshake.LostSession(ARYA, "Arya"),
            SessionHandshake.LostSession(BRAN, "Bran"),
        )

        val lost = SessionHandshake.firstLostSession(before, stillOwned = setOf(ARYA))

        assertEquals(BRAN, lost?.id)
        assertEquals("Bran", lost?.name)
    }

    @Test
    fun `no lost session when the server list still matches`() {
        val before = listOf(
            SessionHandshake.LostSession(ARYA, "Arya"),
            SessionHandshake.LostSession(BRAN, "Bran"),
        )

        assertNull(SessionHandshake.firstLostSession(before, stillOwned = setOf(ARYA, BRAN)))
    }

    /**
     * The launch case by construction: an empty pane before the fetch means there
     * is no "before" to diff, so nothing is ever announced.
     */
    @Test
    fun `nothing is announced when there was no prior pane`() {
        assertNull(SessionHandshake.firstLostSession(emptyList(), stillOwned = emptySet()))
        assertNull(SessionHandshake.firstLostSession(emptyList(), stillOwned = setOf(ARYA)))
    }

    // MARK: - Single-flight

    /**
     * On a cold launch the launch fetch, the `ON_RESUME` trigger and the
     * network-restored collector all fire within milliseconds. They must share ONE
     * pass: overlapping `session_list` RPCs can cross-deliver, because replies are
     * matched by response TYPE — the protocol has no request ids.
     */
    @Test
    fun `concurrent callers share one pass`() = runTest {
        val h = harness(this)
        h.surface.sessionsOnServer = listOf(session(ARYA, "Arya"))
        val listGate = CompletableDeferred<Unit>()
        h.surface.sendGate = { message ->
            if (message is relay.protocol.ClientMessage.SessionList) listGate.await()
        }

        val a = async { h.coord.performHandshake(SessionHandshake.Reason.LAUNCH) }
        advanceUntilIdle()
        val b = async { h.coord.performHandshake(SessionHandshake.Reason.WAKE) }
        val c = async { h.coord.performHandshake(SessionHandshake.Reason.WAKE) }
        advanceUntilIdle()
        listGate.complete(Unit)

        assertEquals(listOf(true, true, true), listOf(a.await(), b.await(), c.await()))
        assertEquals(1, h.log.entries.count { it == "rpc:auth_request" }, "one auth for all three callers")
        assertEquals(1, h.log.entries.count { it == "rpc:session_list" }, "one list for all three callers")
        assertFalse(h.coord.isPerformingHandshake.value, "the gate must clear exactly once")
    }

    // MARK: - Foreground refresh (Android-specific gap)

    /**
     * `restoreActiveOnForeground` used to repaint the terminal and stop there, so
     * coming back from sleep never refreshed the sidebar — violating "ask for the
     * sessions you own and refresh your list" on the very path that needs it most.
     * A live-socket resume must be followed by the full handshake.
     */
    @Test
    fun `foreground restore refreshes the pane after resuming`() = runTest {
        val h = harness(this)
        h.surface.sessionsOnServer = listOf(session(ARYA, "Arya"))
        h.coord.performHandshake(SessionHandshake.Reason.LAUNCH)
        advanceUntilIdle()
        h.coord.switchToSession(ARYA)
        advanceUntilIdle()

        // Another device created a session under this token while we were away.
        h.surface.sessionsOnServer = listOf(session(ARYA, "Arya"), session(BRAN, "Bran"))
        h.coord.restoreActiveOnForeground()
        advanceUntilIdle()

        assertEquals(
            setOf(ARYA, BRAN), h.coord.activeSessions.value.map { it.id }.toSet(),
            "coming back must re-ask the server what we own, not just repaint the terminal",
        )
    }

    /**
     * The foreground repaint checks the handshake/recovery gates and then suspends
     * on a liveness PING ROUND-TRIP — so by the time it wakes, the checks are as
     * stale as the network was slow, and the rest of the ON_RESUME burst has had
     * ample time to start a handshake. Re-reading the gates after the probe is what
     * keeps the repaint from issuing a resume against a socket the handshake owns
     * (and may be about to replace on a retry).
     */
    @Test
    fun `a foreground repaint stands down when a handshake starts during its probe`() = runTest {
        val h = harness(this)
        h.surface.sessionsOnServer = listOf(session(ARYA, "Arya"))
        h.coord.performHandshake(SessionHandshake.Reason.LAUNCH)
        advanceUntilIdle()
        h.coord.switchToSession(ARYA)
        advanceUntilIdle()

        // Park the repaint inside its liveness probe.
        val probeGate = CompletableDeferred<Unit>()
        h.conn.isAliveGate = probeGate
        h.log.entries.clear()
        h.coord.restoreActiveOnForeground()
        advanceUntilIdle()

        // The rest of the burst lands: a handshake takes the connection and parks in
        // session_list, so it is demonstrably still in flight when the probe returns.
        val listGate = CompletableDeferred<Unit>()
        h.surface.sendGate = { message ->
            if (message is relay.protocol.ClientMessage.SessionList) listGate.await()
        }
        val pass = async { h.coord.performHandshake(SessionHandshake.Reason.WAKE) }
        advanceUntilIdle()
        assertTrue(h.coord.isPerformingHandshake.value, "the handshake should own the connection now")

        probeGate.complete(Unit)
        advanceUntilIdle()
        listGate.complete(Unit)
        assertTrue(pass.await(), "the handshake itself must still succeed")
        advanceUntilIdle()

        // Asserted after everything unwinds: a repaint that merely QUEUED behind the
        // handshake's RPC would still show up here, which is the point — standing
        // down means never sending it, not sending it late.
        assertFalse(
            "rpc:session_resume" in h.log,
            "the repaint must abandon its resume, not run it once the handshake releases the wire",
        )
    }
}
