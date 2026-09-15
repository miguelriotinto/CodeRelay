package relay.session

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.net.OptimizeOutcome
import relay.net.OptimizerStrings
import relay.net.ReplaceOutcome
import relay.net.SessionException
import java.util.UUID

/**
 * The wand state machine (spec §7.1, §9), ported from
 * `SharedSessionCoordinator+Optimizer.swift` with the PR #58 review fix: a
 * failed Undo keeps the original.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class PromptOptimizerControllerTest {

    private val sessionA: UUID = UUID.fromString("00000000-0000-0000-0000-00000000000a")
    private val sessionB: UUID = UUID.fromString("00000000-0000-0000-0000-00000000000b")

    /** Scriptable seams; every default is "authenticated, v2, capable, idle, session A active". */
    private class Harness(scope: TestScope) {
        var authenticated = true
        var serverVersion = 2
        var capabilities: Set<String> = setOf("prompt_optimizer")
        var activeSession: UUID? = UUID.fromString("00000000-0000-0000-0000-00000000000a")
        var recovering = false
        var ensureAuthCalls = 0
        var optimizeCalls = mutableListOf<Pair<UUID, Boolean>>()
        var replaceCalls = mutableListOf<Pair<UUID, String>>()
        var optimizeResult: suspend () -> OptimizeOutcome = { OptimizeOutcome.Ok("original") }
        var replaceResult: suspend () -> ReplaceOutcome = { ReplaceOutcome.Ok }

        val controller = PromptOptimizerController(
            scope = scope,
            ensureAuthenticated = { ensureAuthCalls++ },
            withAuth = { body -> body() },
            isAuthenticated = { authenticated },
            serverProtocolVersion = { serverVersion },
            serverCapabilities = { capabilities },
            activeSessionId = { activeSession },
            isRecovering = { recovering },
            optimize = { id, share -> optimizeCalls += id to share; optimizeResult() },
            replace = { id, text -> replaceCalls += id to text; replaceResult() },
        )
    }

    // MARK: - Availability

    @Test
    fun `availability is unknown until authenticated`() = runTest {
        val h = Harness(this)
        h.authenticated = false
        h.controller.refreshAvailability()
        assertEquals(OptimizerAvailability.UNKNOWN, h.controller.availability.value)
        assertNull(h.controller.wandHint)
    }

    @Test
    fun `server below protocol 2 is too old`() = runTest {
        val h = Harness(this)
        h.serverVersion = 1
        h.capabilities = setOf("prompt_optimizer") // a v1 server cannot send this, but the version check must win
        h.controller.refreshAvailability()
        assertEquals(OptimizerAvailability.SERVER_TOO_OLD, h.controller.availability.value)
        assertEquals(OptimizerStrings.UPDATE_RELAY_HINT, h.controller.wandHint)
    }

    @Test
    fun `protocol 2 without the capability is unconfigured`() = runTest {
        val h = Harness(this)
        h.capabilities = emptySet()
        h.controller.refreshAvailability()
        assertEquals(OptimizerAvailability.UNCONFIGURED, h.controller.availability.value)
        assertEquals(OptimizerStrings.CONFIG_HINT, h.controller.wandHint)
    }

    @Test
    fun `protocol 2 with the capability is available`() = runTest {
        val h = Harness(this)
        h.controller.refreshAvailability()
        assertEquals(OptimizerAvailability.AVAILABLE, h.controller.availability.value)
        assertNull(h.controller.wandHint)
        assertTrue(h.controller.isAvailable)
    }

    // MARK: - isWandEnabled

    @Test
    fun `wand is enabled only when idle, not recovering, with an active session`() = runTest {
        val h = Harness(this)
        assertTrue(h.controller.isWandEnabled)
        h.recovering = true
        assertFalse(h.controller.isWandEnabled)
        h.recovering = false
        h.activeSession = null
        assertFalse(h.controller.isWandEnabled)
    }

    @Test
    fun `wand is enabled while unavailable so a tap can show the hint`() = runTest {
        val h = Harness(this)
        h.capabilities = emptySet()
        h.controller.refreshAvailability()
        assertTrue(h.controller.isWandEnabled)
        assertFalse(h.controller.isAvailable)
    }

    // MARK: - optimizePrompt

    @Test
    fun `successful optimize arms undo for the active session and sends shareScreen`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = false)
        assertEquals(listOf(sessionA to false), h.optimizeCalls)
        assertEquals(1, h.ensureAuthCalls)
        assertEquals(OptimizerUndo(sessionA, "original"), h.controller.undo.value)
        assertNull(h.controller.notice.value)
        assertEquals(OptimizerState.IDLE, h.controller.state.value)
    }

    @Test
    fun `state is optimizing while the RPC is in flight and idle after`() = runTest {
        val h = Harness(this)
        val gate = CompletableDeferred<OptimizeOutcome>()
        h.optimizeResult = { gate.await() }
        val job = launch { h.controller.optimizePrompt(shareScreen = true) }
        runCurrent()
        assertEquals(OptimizerState.OPTIMIZING, h.controller.state.value)
        assertFalse(h.controller.isWandEnabled)
        gate.complete(OptimizeOutcome.Passthrough)
        job.join()
        assertEquals(OptimizerState.IDLE, h.controller.state.value)
    }

    @Test
    fun `a second tap while optimizing is ignored`() = runTest {
        val h = Harness(this)
        val gate = CompletableDeferred<OptimizeOutcome>()
        h.optimizeResult = { gate.await() }
        val job = launch { h.controller.optimizePrompt(shareScreen = true) }
        runCurrent()
        h.controller.optimizePrompt(shareScreen = true)
        assertEquals(1, h.optimizeCalls.size)
        gate.complete(OptimizeOutcome.Passthrough)
        job.join()
    }

    @Test
    fun `undo expires after 10 seconds`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        advanceTimeBy(PromptOptimizerController.UNDO_WINDOW_MS - 1L)
        runCurrent()
        assertEquals(OptimizerUndo(sessionA, "original"), h.controller.undo.value)
        advanceTimeBy(2L)
        runCurrent()
        assertNull(h.controller.undo.value)
    }

    @Test
    fun `ok without an original shows Optimized and arms no undo`() = runTest {
        val h = Harness(this)
        h.optimizeResult = { OptimizeOutcome.Ok(null) }
        h.controller.optimizePrompt(shareScreen = true)
        assertNull(h.controller.undo.value)
        assertEquals(OptimizerStrings.OPTIMIZED, h.controller.notice.value)
    }

    @Test
    fun `switching sessions mid-optimize does not arm undo for the new session`() = runTest {
        val h = Harness(this)
        val gate = CompletableDeferred<OptimizeOutcome>()
        h.optimizeResult = { gate.await() }
        val job = launch { h.controller.optimizePrompt(shareScreen = true) }
        runCurrent()
        h.activeSession = sessionB
        gate.complete(OptimizeOutcome.Ok("original"))
        job.join()
        assertNull(h.controller.undo.value)
    }

    @Test
    fun `no draft, passthrough and failed show their toasts and clear after 4 seconds`() = runTest {
        val cases = listOf(
            OptimizeOutcome.NoDraft to OptimizerStrings.NO_DRAFT,
            OptimizeOutcome.Passthrough to OptimizerStrings.PASSTHROUGH,
            OptimizeOutcome.Failed("Prompt too long to optimize") to "Prompt too long to optimize",
        )
        for ((outcome, expected) in cases) {
            val h = Harness(this)
            h.optimizeResult = { outcome }
            h.controller.optimizePrompt(shareScreen = true)
            assertEquals(expected, h.controller.notice.value, "outcome=$outcome")
            assertNull(h.controller.undo.value)
            advanceTimeBy(PromptOptimizerController.NOTICE_WINDOW_MS + 1L)
            runCurrent()
            assertNull(h.controller.notice.value)
        }
    }

    @Test
    fun `unconfigured reply downgrades availability and shows the config hint`() = runTest {
        val h = Harness(this)
        h.controller.refreshAvailability()
        assertEquals(OptimizerAvailability.AVAILABLE, h.controller.availability.value)
        h.optimizeResult = { OptimizeOutcome.Unconfigured }
        h.controller.optimizePrompt(shareScreen = true)
        assertEquals(OptimizerAvailability.UNCONFIGURED, h.controller.availability.value)
        assertEquals(OptimizerStrings.CONFIG_HINT, h.controller.notice.value)
    }

    @Test
    fun `tapping while unavailable shows the hint without an RPC`() = runTest {
        val h = Harness(this)
        h.serverVersion = 1
        h.controller.refreshAvailability()
        h.controller.optimizePrompt(shareScreen = true)
        assertEquals(OptimizerStrings.UPDATE_RELAY_HINT, h.controller.notice.value)
        assertTrue(h.optimizeCalls.isEmpty())
        assertEquals(0, h.ensureAuthCalls)
    }

    @Test
    fun `availability is re-derived after auth so a fresh server flips the hint`() = runTest {
        val h = Harness(this)
        // Cached UNKNOWN (never refreshed) → the fast path has no hint, so we go through auth …
        h.capabilities = emptySet()
        h.controller.optimizePrompt(shareScreen = true)
        // … and the post-auth refresh sees v2-without-capability.
        assertEquals(OptimizerAvailability.UNCONFIGURED, h.controller.availability.value)
        assertEquals(OptimizerStrings.CONFIG_HINT, h.controller.notice.value)
        assertTrue(h.optimizeCalls.isEmpty())
    }

    @Test
    fun `failed retry keeps the existing undo`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        val armed = h.controller.undo.value
        h.optimizeResult = { OptimizeOutcome.Failed("Optimizer unavailable, try again") }
        h.controller.optimizePrompt(shareScreen = true)
        assertEquals(armed, h.controller.undo.value)
        assertEquals("Optimizer unavailable, try again", h.controller.notice.value)
    }

    @Test
    fun `a new optimize dismisses a stale notice`() = runTest {
        val h = Harness(this)
        h.optimizeResult = { OptimizeOutcome.Failed("Optimizer unavailable, try again") }
        h.controller.optimizePrompt(shareScreen = true)
        assertEquals("Optimizer unavailable, try again", h.controller.notice.value)
        h.optimizeResult = { OptimizeOutcome.Ok("original") }
        h.controller.optimizePrompt(shareScreen = true)
        assertNull(h.controller.notice.value)
        assertEquals(OptimizerUndo(sessionA, "original"), h.controller.undo.value)
    }

    @Test
    fun `transport failure shows the exception message or the fallback`() = runTest {
        val h = Harness(this)
        h.optimizeResult = { throw SessionException("The operation timed out.") }
        h.controller.optimizePrompt(shareScreen = true)
        assertEquals("The operation timed out.", h.controller.notice.value)
        assertEquals(OptimizerState.IDLE, h.controller.state.value)

        val h2 = Harness(this)
        h2.optimizeResult = { throw SessionException("") }
        h2.controller.optimizePrompt(shareScreen = true)
        assertEquals(OptimizerStrings.COULD_NOT_REWRITE, h2.controller.notice.value)
    }

    @Test
    fun `optimize is a no-op while recovering or without a session`() = runTest {
        val h = Harness(this)
        h.recovering = true
        h.controller.optimizePrompt(shareScreen = true)
        h.recovering = false
        h.activeSession = null
        h.controller.optimizePrompt(shareScreen = true)
        assertTrue(h.optimizeCalls.isEmpty())
        assertNull(h.controller.notice.value)
    }

    // MARK: - undoOptimize

    @Test
    fun `undo sends the original once and clears the chip on success`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        h.controller.undoOptimize()
        assertEquals(listOf(sessionA to "original"), h.replaceCalls)
        assertNull(h.controller.undo.value)
        assertNull(h.controller.notice.value)
        h.controller.undoOptimize()
        assertEquals(1, h.replaceCalls.size, "undo is one-shot")
    }

    @Test
    fun `failed undo keeps the chip and shows the server message`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        h.replaceResult = { ReplaceOutcome.Failed("Session not attached") }
        h.controller.undoOptimize()
        assertEquals(OptimizerUndo(sessionA, "original"), h.controller.undo.value)
        assertEquals("Session not attached", h.controller.notice.value)
        // The original 10 s window still expires on schedule — not extended by the failure.
        advanceTimeBy(PromptOptimizerController.UNDO_WINDOW_MS + 1L)
        runCurrent()
        assertNull(h.controller.undo.value)
    }

    @Test
    fun `undo transport failure keeps the chip`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        h.replaceResult = { throw SessionException("The operation timed out.") }
        h.controller.undoOptimize()
        assertEquals(OptimizerUndo(sessionA, "original"), h.controller.undo.value)
        assertEquals("The operation timed out.", h.controller.notice.value)
        assertEquals(OptimizerState.IDLE, h.controller.state.value)
    }

    @Test
    fun `undo refuses when another session is active or while recovering`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        h.activeSession = sessionB
        h.controller.undoOptimize()
        assertTrue(h.replaceCalls.isEmpty())
        h.activeSession = sessionA
        h.recovering = true
        h.controller.undoOptimize()
        assertTrue(h.replaceCalls.isEmpty())
        assertEquals(OptimizerUndo(sessionA, "original"), h.controller.undo.value)
    }

    @Test
    fun `undo with nothing armed is a no-op`() = runTest {
        val h = Harness(this)
        h.controller.undoOptimize()
        assertTrue(h.replaceCalls.isEmpty())
    }

    // MARK: - Notices + cancel

    @Test
    fun `dismissOptimizerNotice clears immediately`() = runTest {
        val h = Harness(this)
        h.optimizeResult = { OptimizeOutcome.NoDraft }
        h.controller.optimizePrompt(shareScreen = true)
        h.controller.dismissNotice()
        assertNull(h.controller.notice.value)
    }

    @Test
    fun `cancel clears undo and notice and stops the timers`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        h.controller.cancel()
        assertNull(h.controller.undo.value)
        assertNull(h.controller.notice.value)
        advanceTimeBy(PromptOptimizerController.UNDO_WINDOW_MS + 1L)
        runCurrent() // must not throw or resurrect anything
        assertNull(h.controller.undo.value)
    }
}
