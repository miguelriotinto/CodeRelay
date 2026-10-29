package relay.session

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** Port of Swift `SessionLoadingPresentationTests`. */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionLoadingPresentationTest {

    private fun make(
        phase: SessionLoadPhase?,
        recovering: Boolean = false,
        recovery: RecoveryPhase = RecoveryPhase.RECONNECTING,
        expectsSession: Boolean = true,
        sessionAttached: Boolean = true,
        failed: Boolean = false,
        recoveryFailed: Boolean = false,
    ) = SessionLoadingPresentation(
        loadPhase = phase, isRecovering = recovering, recoveryPhase = recovery,
        expectsSession = expectsSession, sessionAttached = sessionAttached,
        loadFailed = failed, recoveryFailed = recoveryFailed,
        sessionName = "Arya", serverName = "studio",
    )

    /** Scripted sleeps: each call parks until the test releases that duration. */
    private class Sleeper {
        val parked = mutableListOf<Pair<Long, CompletableDeferred<Unit>>>()
        val durations get() = parked.map { it.first }
        suspend fun sleep(ms: Long) {
            val d = CompletableDeferred<Unit>()
            parked += ms to d
            d.await()
        }
        fun release(ms: Long) {
            val i = parked.indexOfFirst { it.first == ms }
            if (i >= 0) parked.removeAt(i).second.complete(Unit)
        }
    }

    /** A scope on the test scheduler the test does not wait for (parked sleeps never finish). */
    private fun TestScope.modelScope(): CoroutineScope = CoroutineScope(coroutineContext + Job())

    private fun TestScope.model(sleeper: Sleeper) = SessionLoadingSheetModel(modelScope()) { sleeper.sleep(it) }

    @Test fun inactiveWhenNothingLoads() = assertFalse(make(null).isActive)

    @Test fun handshakePhasesDoNotRaiseTheSheetWithoutASessionToShow() {
        for (phase in listOf(SessionLoadPhase.Connecting, SessionLoadPhase.Authenticating, SessionLoadPhase.LoadingSessions)) {
            assertFalse(make(phase, expectsSession = false).isActive, "$phase with no session expected")
            assertTrue(make(phase, expectsSession = true).isActive, "$phase while a restore is pending")
        }
        assertTrue(make(SessionLoadPhase.Attaching, expectsSession = false).isActive, "a switch always shows")
        assertTrue(make(null, recovering = true, expectsSession = false).isActive, "recovery always shows (it has Cancel)")
    }

    @Test fun detailReadsZeroKbBeforeHistoryStreams() {
        assertEquals("0 KB", make(SessionLoadPhase.Attaching).detail)
        assertEquals("0 KB", make(null, recovering = true).detail)
        assertEquals("2 KB", make(SessionLoadPhase.LoadingHistory(2048)).detail)
    }

    @Test fun loadPhasesDriveTitleStatusAndBytes() {
        val p = make(SessionLoadPhase.LoadingHistory(212_000))
        assertTrue(p.isActive)
        assertEquals("Loading session", p.title)
        assertEquals("Loading session history…", p.status)
        assertEquals(SessionLoadPhase.formatBytes(212_000), p.detail)
        assertEquals("Arya · studio", p.subtitle)
        assertFalse(p.allowsCancel)
        assertEquals("Authenticating…", make(SessionLoadPhase.Authenticating).status)
        assertNull(make(null).detail)
    }

    @Test fun recoveryWinsTheTitleAndOffersCancel() {
        val p = make(null, recovering = true, recovery = RecoveryPhase.AUTHENTICATING)
        assertTrue(p.isActive)
        assertEquals("Reconnecting", p.title)
        assertEquals("Authenticating…", p.status)
        assertTrue(p.allowsCancel)
        assertEquals("Reconnecting to server…", make(null, recovering = true).status)
        assertEquals(
            "Loading session history…",
            make(SessionLoadPhase.LoadingHistory(10), recovering = true, recovery = RecoveryPhase.RESUMING).status,
        )
    }

    @Test fun sheetHoldsAMinimumEvenWhenLoadingIsInstant() = runTest {
        val sleeper = Sleeper(); val model = model(sleeper)
        model.update(make(SessionLoadPhase.Attaching))
        assertTrue(model.isPresented.value, "up immediately on the first active presentation")
        model.update(make(null, failed = true))
        assertTrue(model.isPresented.value, "held: a 5 ms sheet reads as a flicker")
        runCurrent()
        assertTrue(SessionLoadingSheetModel.MINIMUM_VISIBLE_MS in sleeper.durations)
        sleeper.release(SessionLoadingSheetModel.MINIMUM_VISIBLE_MS); runCurrent()
        assertFalse(model.isPresented.value, "dismissed once the hold elapsed and nothing is loading")
        assertEquals("Attaching to session…", model.shown.value?.status, "the text stays while the sheet animates down")
    }

    @Test fun sheetStaysWhileLoadingOutlivesTheHold() = runTest {
        val sleeper = Sleeper(); val model = model(sleeper)
        model.update(make(SessionLoadPhase.Attaching)); runCurrent()
        sleeper.release(SessionLoadingSheetModel.MINIMUM_VISIBLE_MS); runCurrent()
        assertTrue(model.isPresented.value, "the hold elapsed but the load is still running")
        model.update(make(SessionLoadPhase.LoadingHistory(4096)))
        assertEquals(SessionLoadPhase.formatBytes(4096), model.shown.value?.detail)
        model.update(make(null, failed = true))
        assertFalse(model.isPresented.value, "past the hold, a failed load dismisses immediately")
    }

    @Test fun sheetDismissesAfterAStallAndReturnsOnProgress() = runTest { // Review Focus 6
        val sleeper = Sleeper(); val model = model(sleeper)
        model.update(make(SessionLoadPhase.LoadingHistory(1024)))
        assertTrue(model.isPresented.value)
        runCurrent()
        sleeper.release(SessionLoadingSheetModel.MINIMUM_VISIBLE_MS)
        sleeper.release(SessionLoadingSheetModel.STALL_TIMEOUT_MS); runCurrent()
        assertFalse(model.isPresented.value, "stalled: the sheet lowers so the pane is usable")
        model.update(make(SessionLoadPhase.LoadingHistory(4096)))
        assertTrue(model.isPresented.value, "progress resumed: the sheet comes back")
    }

    @Test fun aFullySyncedSessionShowsZeroThenReadyThenDismisses() = runTest {
        val sleeper = Sleeper(); val model = model(sleeper)
        model.update(make(SessionLoadPhase.Attaching))
        assertEquals("0 KB", model.shown.value?.detail)
        assertFalse(model.shown.value?.isReady ?: true)
        model.update(make(null))
        assertTrue(model.isPresented.value, "still up: Ready is shown before the sheet goes")
        assertEquals(true, model.shown.value?.isReady)
        assertEquals("Ready", model.shown.value?.status)
        assertEquals("0 KB", model.shown.value?.detail, "nothing streamed: 0 KB, then Ready")
        runCurrent()
        assertTrue(SessionLoadingSheetModel.READY_DWELL_MS in sleeper.durations)
        sleeper.release(SessionLoadingSheetModel.MINIMUM_VISIBLE_MS); runCurrent()
        assertTrue(model.isPresented.value, "Ready holds for its own dwell, not the minimum hold")
        sleeper.release(SessionLoadingSheetModel.READY_DWELL_MS); runCurrent()
        assertFalse(model.isPresented.value, "dismissed after Ready")
    }

    @Test fun readyKeepsTheFinalByteCount() = runTest {
        val model = model(Sleeper())
        model.update(make(SessionLoadPhase.Attaching))
        model.update(make(SessionLoadPhase.LoadingHistory(212_000)))
        model.update(make(null))
        assertEquals(true, model.shown.value?.isReady)
        assertEquals(SessionLoadPhase.formatBytes(212_000), model.shown.value?.detail)
        assertFalse(model.shown.value?.allowsCancel ?: true)
    }

    @Test fun aFailedLoadNeverSaysReady() = runTest {
        val model = model(Sleeper())
        model.update(make(SessionLoadPhase.Attaching))
        model.update(make(null, failed = true))
        assertNotEquals(true, model.shown.value?.isReady, "an error alert follows; Ready would be a lie")
        model.update(make(SessionLoadPhase.Attaching))
        model.update(make(null, sessionAttached = false))
        assertNotEquals(true, model.shown.value?.isReady, "nothing attached")
    }

    @Test fun aCancelledReconnectNeverSaysReady() = runTest {
        val model = model(Sleeper())
        model.update(make(null, recovering = true))
        model.update(make(null, recovering = false, recoveryFailed = true))
        assertNotEquals(true, model.shown.value?.isReady)
        val ok = model(Sleeper())
        ok.update(make(null, recovering = true))
        ok.update(make(null))
        assertEquals(true, ok.shown.value?.isReady)
    }

    @Test fun aNewLoadDuringReadyTakesOver() = runTest {
        val sleeper = Sleeper(); val model = model(sleeper)
        model.update(make(SessionLoadPhase.Attaching))
        model.update(make(null))
        assertEquals(true, model.shown.value?.isReady)
        model.update(make(SessionLoadPhase.Attaching))
        assertEquals(false, model.shown.value?.isReady)
        runCurrent()
        sleeper.release(SessionLoadingSheetModel.READY_DWELL_MS); runCurrent()
        assertTrue(model.isPresented.value, "the earlier Ready's dwell must not dismiss the new load")
    }
}
