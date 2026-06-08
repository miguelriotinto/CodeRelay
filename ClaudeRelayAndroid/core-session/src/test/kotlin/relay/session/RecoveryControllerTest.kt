package relay.session

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.concurrent.atomic.AtomicInteger

/**
 * Behavioral parity harness for RecoveryController, ported from
 * Sources/ClaudeRelayClient/ViewModels/RecoveryController.swift. Each test maps
 * to one of the nine load-bearing behaviors identified in the verification pass;
 * the Swift line references are noted inline.
 *
 * Uses runTest virtual time + an injected fake clock and sleep, so there are no
 * real sleeps and the 3 s cooldown / 1 s cancel-debounce windows are controlled
 * deterministically.
 */
class RecoveryControllerTest {

    /**
     * Injectable test environment. Lambdas default to success; tests override
     * the ones they exercise. `nowMs` is a mutable fake clock; `sleepMs` records
     * the requested delays and advances virtual time via `delay`.
     */
    private class RecoveryTestEnv(scope: CoroutineScope) {
        var clockMs: Long = 1_000_000L
        var alive: Boolean = false

        val isAliveCalls = AtomicInteger(0)
        val reconnectCalls = AtomicInteger(0)
        val reauthCalls = AtomicInteger(0)
        val resumeCalls = AtomicInteger(0)
        val fetchCalls = AtomicInteger(0)
        val sleeps = mutableListOf<Long>()
        val suppressLog = mutableListOf<Boolean>()

        var reconnectBehavior: suspend (attempt: Int) -> Unit = { /* success */ }
        var reauthBehavior: suspend () -> Unit = { /* success */ }
        var resumeBehavior: suspend () -> Unit = { /* success */ }
        var appLevel: (Throwable) -> Boolean = { false }

        private var reconnectAttempt = 0

        val controller = RecoveryController(
            scope = scope,
            isAlive = { isAliveCalls.incrementAndGet(); alive },
            reconnect = { reconnectCalls.incrementAndGet(); reconnectBehavior(reconnectAttempt++) },
            reauth = { reauthCalls.incrementAndGet(); reauthBehavior() },
            resumeActive = { resumeCalls.incrementAndGet(); resumeBehavior() },
            fetchSessions = { fetchCalls.incrementAndGet() },
            suppressSends = { suppressLog.add(it) },
            isApplicationLevelError = { appLevel(it) },
            sleepMs = { ms -> sleeps.add(ms); delay(ms) },
            nowMs = { clockMs },
        )
    }

    // 1 + 3: isAlive short-circuit — skips backoff, fetches, never flashes recovery UI.
    @Test
    fun `alive short-circuit fetches and skips backoff without flashing recovery`() = runTest {
        val env = RecoveryTestEnv(this).apply { alive = true }
        env.controller.launchRecovery(userInitiated = true)
        advanceUntilIdle()

        assertEquals(1, env.isAliveCalls.get())
        assertEquals(0, env.reconnectCalls.get())
        assertEquals(1, env.fetchCalls.get())
        assertTrue(env.sleeps.isEmpty(), "alive path must not enter the backoff loop")
        // The alive path never sets isRecovering true and never toggles
        // suppressSends — both happen only on the not-alive branch
        // (RecoveryController.swift:164-165). An empty suppress log proves the
        // recovery UI never flashed.
        assertTrue(env.suppressLog.isEmpty(), "alive path must not toggle suppressSends")
        assertEquals(false, env.controller.isRecovering.value)
    }

    // 1: backoff array is exactly [0,1,2,4,8,15] seconds (RecoveryController.swift:176).
    @Test
    fun `backoff uses the exact 0-1-2-4-8-15 second array`() = runTest {
        val env = RecoveryTestEnv(this).apply {
            alive = false
            reconnectBehavior = { throw RuntimeException("down") } // exhaust all attempts
        }
        env.controller.launchRecovery(userInitiated = false)
        advanceUntilIdle()

        assertEquals(6, env.reconnectCalls.get(), "six reconnect attempts")
        // delay==0 is not slept; the controller skips the sleep for the first attempt.
        assertEquals(listOf(1_000L, 2_000L, 4_000L, 8_000L, 15_000L), env.sleeps)
        assertTrue(env.controller.connectionTimedOut.value)
    }

    // 6: 3 consecutive AUTO failures -> autoRecoverySuspended; a 4th does no work.
    @Test
    fun `three auto failures suspend the breaker and a fourth schedule does nothing`() = runTest {
        val env = RecoveryTestEnv(this).apply {
            alive = false
            reconnectBehavior = { throw RuntimeException("down") }
        }
        repeat(3) {
            env.controller.scheduleAutoRecovery()
            advanceUntilIdle()
            // Advance the clock past the 3 s cooldown so the next auto-recovery is allowed.
            env.clockMs += 5_000
        }
        assertTrue(env.controller.autoRecoverySuspended.value)
        assertEquals(3, env.reconnectCalls.get() / 6, "each failed pass made 6 reconnect attempts")

        val reconnectsBefore = env.reconnectCalls.get()
        env.controller.scheduleAutoRecovery() // breaker is open -> no-op
        advanceUntilIdle()
        assertEquals(reconnectsBefore, env.reconnectCalls.get())
    }

    // 6: user recovery resets the breaker (RecoveryController.swift:128-129).
    @Test
    fun `user recovery resets the breaker`() = runTest {
        val env = RecoveryTestEnv(this)
        env.controller.setBreakerForTest(suspended = true, failures = 3)
        assertTrue(env.controller.autoRecoverySuspended.value)

        env.clockMs += 5_000 // clear any cancel debounce window
        env.controller.triggerUserRecovery()
        runCurrent() // let the breaker reset run synchronously before any awaits
        assertFalse(env.controller.autoRecoverySuspended.value)
    }

    // 4: reconnect-success-then-reauth-fail is TERMINAL — counts one failure, no re-loop.
    @Test
    fun `reconnect success then reauth fail is terminal and does not re-loop backoff`() = runTest {
        val env = RecoveryTestEnv(this).apply {
            alive = false
            reconnectBehavior = { /* succeeds immediately */ }
            reauthBehavior = { throw RuntimeException("auth down") }
        }
        env.controller.launchRecovery(userInitiated = false)
        advanceUntilIdle()

        assertEquals(1, env.reconnectCalls.get(), "reconnect attempted ONCE, not 6x")
        assertEquals(1, env.reauthCalls.get())
        assertEquals(0, env.resumeCalls.get())
        assertTrue(env.controller.connectionTimedOut.value, "transport-level error sets connectionTimedOut")
        assertEquals(1, env.controller.consecutiveAutoFailuresForTest, "one breaker failure")
    }

    // 5: app-level restore error -> sessionAttachFailed, NOT connectionTimedOut, still counts.
    @Test
    fun `app level restore error sets attach failed not timed out but still counts`() = runTest {
        val appErr = IllegalStateException("session gone")
        val env = RecoveryTestEnv(this).apply {
            alive = false
            reconnectBehavior = { /* success */ }
            resumeBehavior = { throw appErr }
            appLevel = { it === appErr }
        }
        env.controller.launchRecovery(userInitiated = false)
        advanceUntilIdle()

        assertTrue(env.controller.sessionAttachFailed.value)
        assertFalse(env.controller.connectionTimedOut.value, "app-level error must NOT time out the connection")
        assertEquals(1, env.controller.consecutiveAutoFailuresForTest, "app-level error still counts toward breaker")
    }

    // 7: 3 s auto-recovery cooldown drops a second auto-recovery within the window.
    @Test
    fun `cooldown drops a second auto recovery within three seconds`() = runTest {
        // The cooldown is stamped in the inner finally, which is entered only on
        // the NOT-alive path (RecoveryController.swift:166-170). The alive
        // short-circuit deliberately does NOT participate in the cooldown, so we
        // drive a full not-alive pass that succeeds to stamp lastRecoveryEndedAt.
        val env = RecoveryTestEnv(this).apply {
            alive = false
            reconnectBehavior = { /* success */ }
            reauthBehavior = { /* success */ }
            resumeBehavior = { /* success */ }
        }
        env.controller.scheduleAutoRecovery()
        advanceUntilIdle()
        assertEquals(1, env.reconnectCalls.get())

        // Within 3 s of the last recovery ENDING -> dropped (no new pass).
        env.clockMs += 2_000
        env.controller.scheduleAutoRecovery()
        advanceUntilIdle()
        assertEquals(1, env.reconnectCalls.get(), "second auto-recovery within 3 s must be dropped")

        // Past 3 s -> allowed.
        env.clockMs += 2_000
        env.controller.scheduleAutoRecovery()
        advanceUntilIdle()
        assertEquals(2, env.reconnectCalls.get())
    }

    // 8: resetAutoRecoveryBreaker clears suspension + failures.
    @Test
    fun `resetAutoRecoveryBreaker clears suspension`() = runTest {
        val env = RecoveryTestEnv(this)
        env.controller.setBreakerForTest(suspended = true, failures = 3)
        env.controller.resetAutoRecoveryBreaker()
        assertFalse(env.controller.autoRecoverySuspended.value)
        assertEquals(0, env.controller.consecutiveAutoFailuresForTest)
    }

    // 9: cancel() suspends the breaker and bumps generation so in-flight recovery bails.
    @Test
    fun `cancel suspends breaker and bumps generation so in-flight recovery bails`() = runTest {
        val reconnectGate = CompletableDeferred<Unit>()
        val env = RecoveryTestEnv(this).apply {
            alive = false
            // First reconnect blocks until cancel bumps the generation; the
            // recovery must bail at the post-reconnect generation check.
            reconnectBehavior = { reconnectGate.await() }
        }
        env.controller.launchRecovery(userInitiated = false)
        advanceUntilIdle() // parks inside reconnect()

        env.controller.cancel()
        reconnectGate.complete(Unit)
        advanceUntilIdle()

        assertTrue(env.controller.autoRecoverySuspended.value, "cancel suspends the breaker")
        // Generation bumped -> the in-flight pass must NOT proceed to reauth/resume/fetch.
        assertEquals(0, env.reauthCalls.get())
        assertEquals(0, env.resumeCalls.get())
        assertFalse(env.controller.isRecovering.value, "cancel clears the recovery UI flag")
    }

    // 9: 1 s cancel-debounce — triggerUserRecovery within 1 s of cancel is ignored.
    @Test
    fun `user recovery within one second of cancel is ignored`() = runTest {
        val env = RecoveryTestEnv(this).apply { alive = true }
        env.controller.cancel() // stamps lastCancelledAt = clockMs

        env.clockMs += 500 // within the 1 s debounce
        env.controller.triggerUserRecovery()
        advanceUntilIdle()
        assertEquals(0, env.isAliveCalls.get(), "user recovery within 1 s of cancel must be ignored")

        env.clockMs += 1_000 // now past the debounce
        env.controller.triggerUserRecovery()
        advanceUntilIdle()
        assertEquals(1, env.isAliveCalls.get())
    }

    // generation: a newer generation makes an older in-flight recovery bail.
    @Test
    fun `newer generation makes the older recovery bail`() = runTest {
        val firstReconnect = CompletableDeferred<Unit>()
        val env = RecoveryTestEnv(this)
        env.alive = false
        var call = 0
        env.reconnectBehavior = {
            if (call++ == 0) firstReconnect.await() // first pass parks here
            // second pass succeeds immediately
        }
        env.controller.launchRecovery(userInitiated = true)
        advanceUntilIdle() // first pass parked in reconnect

        // Start a second pass (new generation) by cancelling + re-triggering.
        env.controller.cancel()
        env.clockMs += 2_000 // past the 1 s cancel debounce
        env.controller.triggerUserRecovery()
        advanceUntilIdle() // second pass runs to completion

        // Release the first (now-stale) reconnect; it must bail at the gen check.
        firstReconnect.complete(Unit)
        advanceUntilIdle()

        // Only the newest pass restored: reauth/resume/fetch ran exactly once.
        assertEquals(1, env.reauthCalls.get())
        assertEquals(1, env.fetchCalls.get())
    }

    // defer-idempotency: cancel mid-backoff still clears isRecovering + suppressSends(false).
    @Test
    fun `cancel mid backoff still clears recovery flags`() = runTest {
        val env = RecoveryTestEnv(this).apply {
            alive = false
            reconnectBehavior = { throw RuntimeException("down") } // forces backoff sleeps
        }
        env.controller.launchRecovery(userInitiated = false)
        runCurrent()
        // First attempt (delay 0) fails immediately, then the controller sleeps 1 s.
        advanceTimeBy(500) // mid-backoff sleep
        runCurrent()
        assertTrue(env.controller.isRecovering.value, "recovery is in progress mid-backoff")

        env.controller.cancel()
        advanceUntilIdle()

        assertFalse(env.controller.isRecovering.value, "isRecovering cleared after cancel mid-backoff")
        // suppressSends must have been toggled back to false (cancel() does this
        // directly now that the inner finally is generation-guarded).
        assertEquals(false, env.suppressLog.last())
    }

    // I2: the generation-guarded inner finally must NOT let a stale gen-1 pass
    // clobber a genuinely mid-flight gen-2 pass's recovery state. We park gen-1
    // inside reconnect, cancel + re-trigger to start gen-2, park gen-2 inside ITS
    // reconnect, then release gen-1 so its finally runs while gen-2 is still
    // parked. The guarded finally skips its StateFlow writes because gen-1's
    // captured generation no longer matches, leaving gen-2's state intact.
    //
    // CAVEAT (documented per the I2 brief): under the serial test dispatcher this
    // assertion passes WITH OR WITHOUT the guard. `cancel()` eagerly resumes the
    // cancelled gen-1 coroutine, so gen-1's inner finally fully unwinds BEFORE
    // gen-2 commits `isRecovering=true` — the `isRecoveryDispatched` entry-lock
    // structurally prevents gen-1's finally from interleaving AFTER gen-2's
    // commit. The clobber is therefore not exercisable under faithful serial /
    // @MainActor ordering; the guard is cheap insurance against a future
    // re-entrant ordering change. This test still pins the intended invariant
    // (gen-2's mid-flight state survives a stale finally) as a regression guard.
    @Test
    fun `gen-guarded finally does not clobber a mid-flight newer generation`() = runTest {
        val gen1Reconnect = CompletableDeferred<Unit>()
        val gen2Reconnect = CompletableDeferred<Unit>()
        val env = RecoveryTestEnv(this)
        env.alive = false
        var call = 0
        env.reconnectBehavior = {
            when (call++) {
                0 -> gen1Reconnect.await() // gen-1 parks here
                else -> gen2Reconnect.await() // gen-2 parks here, stays mid-flight
            }
        }

        // gen-1 starts and parks inside reconnect with isRecovering=true.
        env.controller.launchRecovery(userInitiated = true)
        advanceUntilIdle()
        assertTrue(env.controller.isRecovering.value, "gen-1 committed to recovery")

        // Cancel gen-1 (bumps generation to 2) and start gen-2.
        env.controller.cancel()
        env.clockMs += 2_000 // clear the 1 s cancel debounce
        env.controller.triggerUserRecovery()
        advanceUntilIdle() // gen-2 now parked inside its own reconnect

        assertTrue(env.controller.isRecovering.value, "gen-2 is mid-flight and recovering")
        // suppressSends was driven true again by gen-2 entering recovery.
        assertEquals(true, env.suppressLog.last(), "gen-2 re-suppressed sends")

        // Release gen-1: its (cancelled) coroutine runs its generation-guarded
        // finally. Because gen-1's captured generation (1) != current (2), the
        // guarded writes are skipped — gen-2's state is left intact.
        gen1Reconnect.complete(Unit)
        advanceUntilIdle()

        assertTrue(
            env.controller.isRecovering.value,
            "gen-1's stale finally must NOT clear gen-2's isRecovering",
        )
        assertEquals(
            true,
            env.suppressLog.last(),
            "gen-1's stale finally must NOT toggle suppressSends(false) under gen-2",
        )

        // Sanity: let gen-2 finish cleanly so its OWN (matching-generation) finally
        // performs the real cleanup.
        gen2Reconnect.complete(Unit)
        advanceUntilIdle()
        assertFalse(env.controller.isRecovering.value, "gen-2's own finally clears recovery")
        assertEquals(false, env.suppressLog.last(), "gen-2's own finally restores sends")
    }
}
