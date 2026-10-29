package relay.session

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.net.SessionController
import relay.protocol.ClientMessage
import relay.protocol.ConnectionConfig
import relay.protocol.ServerIdentity
import relay.protocol.ServerMessage
import java.util.UUID

/** The additive coordinator hooks the multi-server hub reads (plan 3, Task 2). */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionCoordinatorHubHooksTest {

    private class Harness(scope: TestScope) {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val coord = SessionCoordinator(
            scope = scope,
            connection = conn,
            sessionController = SessionController(surface),
            token = "tok",
            ownershipStore = FakeOwnershipStore(log),
            config = ConnectionConfig(name = "test", host = "127.0.0.1"),
        )
    }

    @Test fun connectedFollowsTheTransport() = runTest {
        val h = Harness(this)
        h.conn.connected = false; advanceUntilIdle()
        assertFalse(h.coord.connected.value)
        h.conn.connected = true; advanceUntilIdle()
        assertTrue(h.coord.connected.value, "the hub republishes on this flow; a plain property fired nothing")
    }

    @Test fun serverIdentityIsPublishedAfterAuth() = runTest {
        val h = Harness(this)
        val id = UUID.randomUUID()
        h.surface.responder = { m ->
            if (m is ClientMessage.AuthRequest) ServerMessage.AuthSuccess(protocolVersion = 3, tokenId = "tok", serverId = id.toString(), serverName = "studio")
            else h.surface.defaultResponseFor(m)
        }
        h.coord.connect(); advanceUntilIdle()
        assertEquals(ServerIdentity(id, "studio"), h.coord.serverIdentity.value)
    }

    @Test fun aRejectedTokenIsFlaggedAndASuccessfulAuthClearsIt() = runTest {
        val h = Harness(this)
        h.surface.responder = { m ->
            if (m is ClientMessage.AuthRequest) ServerMessage.AuthFailure("bad token") else h.surface.defaultResponseFor(m)
        }
        runCatching { h.coord.connect() }; advanceUntilIdle()
        assertTrue(h.coord.isAuthRejected.value, "the hub shows authFailed with Re-pair")
        h.surface.responder = { m -> h.surface.defaultResponseFor(m) }
        h.coord.performHandshake(SessionHandshake.Reason.WAKE); advanceUntilIdle()
        assertFalse(h.coord.isAuthRejected.value)
    }

    @Test fun detachForHubClearsLocallyEvenWhenTheDetachNeverReturns() = runTest {
        val h = Harness(this)
        h.coord.connect(); advanceUntilIdle()
        val id = UUID.randomUUID()
        h.coord.switchToSession(id); advanceUntilIdle()
        assertEquals(id, h.coord.activeSessionId.value)
        val never = CompletableDeferred<Unit>()
        h.surface.sendGate = { m -> if (m is ClientMessage.SessionDetach) never.await() }
        h.coord.detachForHub(budgetMs = 100)
        assertNull(h.coord.activeSessionId.value, "cleared before the RPC, so the hub can attach elsewhere at once")
        never.complete(Unit); advanceUntilIdle()
    }

    @Test fun detachForHubStopsAnAttachInFlightFromPublishing() = runTest {
        // D9: a switch that began before the hub moved to another server must
        // not become the active session when its RPC returns.
        val h = Harness(this)
        h.coord.connect(); advanceUntilIdle()
        val target = UUID.randomUUID()
        val gate = CompletableDeferred<Unit>()
        h.surface.sendGate = { m -> if (m is ClientMessage.SessionResume) gate.await() }
        val switching = launch { h.coord.switchToSession(target) }
        advanceUntilIdle()                       // parked inside resumeSession
        h.surface.sendGate = null
        h.coord.detachForHub(budgetMs = 100)
        gate.complete(Unit)
        switching.join(); advanceUntilIdle()
        assertNull(h.coord.activeSessionId.value)
        assertNull(h.coord.sessionLoadPhase.value)
    }

    @Test fun failedSwitchIsMarkedFailedBeforeItsPhaseClears() = runTest {
        val h = Harness(this)
        h.coord.connect(); advanceUntilIdle()
        h.surface.responder = { m ->
            if (m is ClientMessage.SessionResume) ServerMessage.Error(500, "boom") else h.surface.defaultResponseFor(m)
        }
        // Unconfined: the collector runs inside each write, so it reads the flag
        // at the exact instant the phase clears, as the sheet does.
        var failedWhenCleared: Boolean? = null
        var sawPhase = false
        val watcher = launch(UnconfinedTestDispatcher(testScheduler)) {
            h.coord.sessionLoadPhase.collect { phase ->
                if (phase != null) sawPhase = true
                else if (sawPhase && failedWhenCleared == null) failedWhenCleared = h.coord.lastLoadFailed.value
            }
        }
        h.coord.switchToSession(UUID.randomUUID()); advanceUntilIdle()
        assertTrue(sawPhase)
        assertEquals(true, failedWhenCleared, "the sheet reads the flag the moment the phase clears; it must already say failed")
        assertTrue(h.coord.loadEndedInFailure)
        watcher.cancel()
    }

    @Test fun aSuccessfulLoadResetsTheFailedFlag() = runTest {
        val h = Harness(this)
        h.coord.connect(); advanceUntilIdle()
        h.surface.responder = { m ->
            if (m is ClientMessage.SessionResume) ServerMessage.Error(500, "boom") else h.surface.defaultResponseFor(m)
        }
        h.coord.switchToSession(UUID.randomUUID()); advanceUntilIdle()
        assertTrue(h.coord.lastLoadFailed.value)
        h.surface.responder = { m -> h.surface.defaultResponseFor(m) }
        h.coord.createNewSession(); advanceUntilIdle()
        assertFalse(h.coord.lastLoadFailed.value)
    }

    @Test fun reloadPublishesAttachingAndClearsItOnFailure() = runTest {
        val h = Harness(this)
        h.surface.sessionsOnServer = listOf(
            relay.protocol.SessionInfo(
                id = FakeConnectionSurface.NEW_SESSION_ID, name = "Arya", state = relay.protocol.SessionState.ACTIVE_ATTACHED,
                tokenId = "tok", createdAt = 0.0, cols = 80u, rows = 24u,
                activity = relay.protocol.ActivityState.ACTIVE, agent = null,
            ),
        )
        h.coord.connect(); advanceUntilIdle()
        h.coord.createNewSession(); advanceUntilIdle()
        val id = h.coord.activeSessionId.value!!
        h.surface.responder = { m ->
            if (m is ClientMessage.SessionResume) ServerMessage.Error(500, "boom") else h.surface.defaultResponseFor(m)
        }
        val seen = mutableListOf<SessionLoadPhase?>()
        val watcher = launch(UnconfinedTestDispatcher(testScheduler)) { h.coord.sessionLoadPhase.collect { seen += it } }
        h.coord.reloadTerminalFromServer(id); advanceUntilIdle()
        assertTrue(SessionLoadPhase.Attaching in seen, "the name-label tap raises the sheet at once")
        assertNull(h.coord.sessionLoadPhase.value)
        assertTrue(h.coord.lastLoadFailed.value)
        watcher.cancel()
    }

    @Test fun recoveryFailedIsObservable() = runTest {
        val h = Harness(this)
        assertFalse(h.coord.recoveryFailed.value)
        h.coord.cancelRecovery(); advanceUntilIdle()
        assertTrue(h.coord.recoveryFailed.value, "a cancelled reconnect never closes the sheet with Ready")
    }

    @Test fun expectsSessionToLoadFollowsTheActiveSession() = runTest {
        val h = Harness(this)
        assertFalse(h.coord.expectsSessionToLoad)
        h.coord.connect(); advanceUntilIdle()
        h.coord.createNewSession(); advanceUntilIdle()
        assertTrue(h.coord.expectsSessionToLoad)
    }
}
