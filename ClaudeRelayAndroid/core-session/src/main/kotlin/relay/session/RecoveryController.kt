package relay.session

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

/**
 * Owns the recovery state machine ported from
 * Sources/ClaudeRelayClient/ViewModels/RecoveryController.swift: the
 * auto-suspend circuit breaker, generation tokens, cooldown tracking, and the
 * `handleForegroundTransition` / `restoreSession` flow.
 *
 * This is a faithful behavioral rewrite of the Swift source, not the plan
 * skeleton. Everything the Swift original reaches through its coordinator /
 * connection is injected as a lambda so the controller is testable without any
 * Android dependency. The nine load-bearing behaviors verified against the
 * source:
 *
 *  1. Backoff `[0,1,2,4,8,15]` seconds (RecoveryController.swift:176).
 *  2. The [isAlive] probe wraps a 5 s pong wait (RelayConnection.swift:313);
 *     this controller just calls [isAlive] and trusts that timeout.
 *  3. isAlive short-circuit: alive -> fetch + return WITHOUT entering the
 *     backoff loop; `isRecovering` is set true only AFTER the alive==false
 *     branch (RecoveryController.swift:151-164), so the alive path never
 *     flashes recovery UI.
 *  4. Auth/resume failure is TERMINAL: only RECONNECT failures retry the
 *     backoff array. A successful reconnect whose reauth/resume fails accounts
 *     the failure ONCE and returns — it does NOT re-run the loop
 *     (RecoveryController.swift:202-206, 272).
 *  5. App-level vs transport-level split: an app-level restore error sets
 *     [sessionAttachFailed], does NOT set [connectionTimedOut], but still
 *     counts toward the breaker (RecoveryController.swift:258-272).
 *  6. Circuit breaker: 3 consecutive AUTO failures -> [autoRecoverySuspended];
 *     only AUTO (not user) failures count; reset by user signals and by
 *     [resetAutoRecoveryBreaker] (RecoveryController.swift:47, 69-74,
 *     128-129, 224-233).
 *  7. 3 s auto-recovery cooldown: [scheduleAutoRecovery] drops auto-recoveries
 *     within 3 s of the last one ENDING (RecoveryController.swift:43, 94-98),
 *     stamping `lastRecoveryEndedAt` from the injected [nowMs] clock in the
 *     `finally` (RecoveryController.swift:169).
 *  8. [resetAutoRecoveryBreaker] clears suspension + failures
 *     (RecoveryController.swift:69-74); wired to a healthy-ping signal.
 *  9. [cancel] suspends the breaker, sets a recovery-failed flag, stamps
 *     `lastCancelledAt`, and bumps the generation so in-flight recovery bails
 *     (RecoveryController.swift:286-299); [triggerUserRecovery] ignores calls
 *     within 1 s of a cancel (RecoveryController.swift:56-58, 124-127).
 *
 * Plus: `recoveryGeneration` captured at entry and rechecked at every await
 * checkpoint (bail if newer); the two distinct guards `isRecoveryDispatched`
 * (sync entry-lock) vs [isRecovering] (UI StateFlow); [suppressSends] toggled
 * around the recovery body; and defer-idempotency — a single try/finally clears
 * `isRecovering` + `suppressSends(false)` + `isRecoveryDispatched` + stamps
 * `lastRecoveryEndedAt` even on a mid-await cancel.
 *
 * Not thread-safe across dispatchers — the Swift original is `@MainActor`
 * isolated. Callers must confine entry points to a single (main) dispatcher;
 * the [isRecoveryDispatched] sync entry-lock relies on that confinement.
 *
 * @param scope The coroutine scope recovery passes launch on. It MUST use a
 *   serial / confined dispatcher (e.g. `Dispatchers.Main.immediate`) — the
 *   [isRecoveryDispatched] sync entry-lock and the single-flight generation
 *   guards assume entry points and the recovery body never run concurrently,
 *   faithful to the Swift `@MainActor` model. The Task-6 coordinator wiring is
 *   responsible for providing such a scope.
 * @param isAlive Probes the socket; wraps a 5 s pong wait at the call site.
 * @param reconnect Forces a transport reconnect; throws on failure (only this
 *   failure retries the backoff array).
 * @param reauth Resets + re-establishes auth on the current connection.
 * @param resumeActive Resumes the active session (no-op if there is none).
 * @param fetchSessions Refreshes the server session list.
 * @param suppressSends Toggled true around the recovery body, false on exit.
 * @param isApplicationLevelError Classifies a restore error: app-level (session
 *   gone) vs transport-level. App-level errors set [sessionAttachFailed]
 *   instead of [connectionTimedOut].
 * @param sleepMs Backoff sleep; injectable for virtual-time tests.
 * @param nowMs Clock for cooldown/debounce stamps; injectable so tests control
 *   time. The default `System.currentTimeMillis()` is WALL-CLOCK and
 *   non-monotonic — an NTP correction or manual clock change can move it
 *   backwards and corrupt the 3 s cooldown / 1 s cancel-debounce windows. The
 *   Task-6 coordinator wiring MUST inject the Android-correct monotonic source
 *   `android.os.SystemClock.elapsedRealtime()` instead. This module stays
 *   pure-JVM (no Android dependency), so the monotonic clock is injected from
 *   the Android layer rather than referenced here. Never stamped as 0L.
 */
class RecoveryController(
    private val scope: CoroutineScope,
    private val isAlive: suspend () -> Boolean,
    private val reconnect: suspend () -> Unit,
    private val reauth: suspend () -> Unit,
    private val resumeActive: suspend () -> Unit,
    private val fetchSessions: suspend () -> Unit,
    private val suppressSends: (Boolean) -> Unit = {},
    private val isApplicationLevelError: (Throwable) -> Boolean = { false },
    private val sleepMs: suspend (Long) -> Unit = { delay(it) },
    private val nowMs: () -> Long = { System.currentTimeMillis() },
) {
    private companion object {
        /** Backoff delays in seconds (RecoveryController.swift:176). */
        val BACKOFF_SECONDS = longArrayOf(0, 1, 2, 4, 8, 15)

        /** Auto-recovery cooldown, ms (RecoveryController.swift:43 — 3 s). */
        const val AUTO_RECOVERY_COOLDOWN_MS = 3_000L

        /** Max consecutive auto failures before suspend (RecoveryController.swift:47). */
        const val MAX_AUTO_RECOVERY_FAILURES = 3

        /** Cancel debounce for user recovery, ms (RecoveryController.swift:124 — 1 s). */
        const val CANCEL_DEBOUNCE_MS = 1_000L
    }

    // MARK: - UI state (StateFlows)

    private val _isRecovering = MutableStateFlow(false)
    /** True while the backoff/restore body is running (drives recovery UI). */
    val isRecovering: StateFlow<Boolean> = _isRecovering.asStateFlow()

    private val _phase = MutableStateFlow(RecoveryPhase.RECONNECTING)
    val phase: StateFlow<RecoveryPhase> = _phase.asStateFlow()

    private val _connectionTimedOut = MutableStateFlow(false)
    /** Set on a terminal transport-level failure; tears the workspace down. */
    val connectionTimedOut: StateFlow<Boolean> = _connectionTimedOut.asStateFlow()

    private val _sessionAttachFailed = MutableStateFlow(false)
    /** Set on an app-level restore failure (session gone); connection stays up. */
    val sessionAttachFailed: StateFlow<Boolean> = _sessionAttachFailed.asStateFlow()

    private val _autoRecoverySuspended = MutableStateFlow(false)
    /** True when auto-retry is circuit-broken; awaits a user/healthy-ping signal. */
    val autoRecoverySuspended: StateFlow<Boolean> = _autoRecoverySuspended.asStateFlow()

    // MARK: - Breaker + generation state

    /**
     * Monotonic token bumped at the start of every recovery pass and on
     * [cancel]. A pass only proceeds while the token it captured still matches —
     * prevents a stale pass from restoring after a newer one or a cancel
     * (RecoveryController.swift:35, 158-159).
     */
    private var recoveryGeneration: ULong = 0u

    /**
     * Last recovery completion stamp (success or failure); cooldown anchor.
     * Null means "no recovery has ended yet" (Swift `Date.distantPast`), so the
     * first auto-recovery is always allowed — avoids the `now - MIN_VALUE`
     * overflow a sentinel Long would cause.
     */
    private var lastRecoveryEndedAt: Long? = null

    /** Consecutive auto-triggered recovery failures (RecoveryController.swift:41). */
    private var consecutiveAutoRecoveryFailures = 0

    /** Recovery-failed flag (Swift `coordinator.recoveryFailed`). Internal — the
     * UI binds to the more specific [connectionTimedOut] / [sessionAttachFailed]. */
    private var recoveryFailed = false

    /**
     * Synchronous entry lock, distinct from [isRecovering] (which is set after
     * `await isAlive()`). Prevents concurrent dispatches from racing across the
     * suspension at the top of the flow (RecoveryController.swift:55, 144).
     */
    private var isRecoveryDispatched = false

    /**
     * Stamp set by [cancel]; gates [triggerUserRecovery]
     * (RecoveryController.swift:58). Null means "never cancelled" so user
     * recovery is not debounced until a cancel actually happens.
     */
    private var lastCancelledAt: Long? = null

    /** The in-flight recovery job, so [cancel] can cancel it. */
    private var recoveryJob: Job? = null

    // MARK: - Breaker

    /**
     * Clears the auto-recovery circuit breaker. No-op when already idle so
     * healthy steady-state traffic doesn't thrash (RecoveryController.swift:69-74).
     * Wired to a healthy-ping signal by the coordinator.
     */
    fun resetAutoRecoveryBreaker() {
        if (!_autoRecoverySuspended.value && consecutiveAutoRecoveryFailures == 0) return
        consecutiveAutoRecoveryFailures = 0
        _autoRecoverySuspended.value = false
    }

    /**
     * Clears the terminal recovery flags ([connectionTimedOut] /
     * [sessionAttachFailed]). These are set-only by the recovery flow; the
     * coordinator/UI resets them on a fresh foreground transition or when the
     * user dismisses the recovery error. Mirrors the Swift reset on WorkspaceView
     * / SharedSessionCoordinator.
     */
    fun clearTerminalFlags() {
        _connectionTimedOut.value = false
        _sessionAttachFailed.value = false
    }

    // MARK: - Entry points

    /**
     * Auto-triggered recovery (from a send/ping failure). Gated by:
     * already-dispatched, auto-suspend (breaker open), and a 3 s cooldown since
     * the last recovery ended (RecoveryController.swift:84-104).
     */
    fun scheduleAutoRecovery() {
        if (isRecoveryDispatched) return
        if (_autoRecoverySuspended.value) return
        val endedAt = lastRecoveryEndedAt
        if (endedAt != null && nowMs() - endedAt < AUTO_RECOVERY_COOLDOWN_MS) return
        isRecoveryDispatched = true
        recoveryJob = scope.launch { handleForegroundTransition(userInitiated = false) }
    }

    /**
     * Explicit user-initiated recovery (foreground, network restored, rescan).
     * Clears the breaker so auto-retry resumes after this attempt. Ignores calls
     * within 1 s of a [cancel] to avoid sheet-dismiss -> foreground -> re-trigger
     * (RecoveryController.swift:118-134).
     */
    fun triggerUserRecovery() {
        if (isRecoveryDispatched) return
        val cancelledAt = lastCancelledAt
        if (cancelledAt != null && nowMs() - cancelledAt < CANCEL_DEBOUNCE_MS) return
        _autoRecoverySuspended.value = false
        consecutiveAutoRecoveryFailures = 0
        isRecoveryDispatched = true
        recoveryJob = scope.launch { handleForegroundTransition(userInitiated = true) }
    }

    /**
     * Test seam / direct entry: launches a recovery pass on [scope] bypassing the
     * scheduling gates, matching the Swift `coordinator.recoveryTask = Task { ... }`
     * dispatch. Sets the dispatch lock so re-entry is blocked, just like the real
     * entry points.
     */
    internal fun launchRecovery(userInitiated: Boolean) {
        if (isRecoveryDispatched) return
        isRecoveryDispatched = true
        recoveryJob = scope.launch { handleForegroundTransition(userInitiated) }
    }

    // MARK: - Recovery flow

    /**
     * The recovery pass (Swift `handleForegroundTransition`). Outer `finally`
     * clears the sync dispatch lock for ALL paths (including the alive
     * short-circuit), mirroring the outermost Swift `defer` at :144. The inner
     * `finally` — entered only on the not-alive path — clears the recovery UI
     * state and stamps the cooldown, mirroring the inner Swift `defer` at :166.
     */
    private suspend fun handleForegroundTransition(userInitiated: Boolean) {
        try {
            if (_isRecovering.value) return // already recovering (RecoveryController.swift:146)

            // isAlive short-circuit (RecoveryController.swift:151-156). isRecovering
            // is NOT set yet, so this path never flashes recovery UI.
            if (isAlive()) {
                fetchSessions()
                return
            }

            // Not alive: now we commit to a recovery pass.
            recoveryGeneration += 1u
            val myGeneration = recoveryGeneration

            _phase.value = RecoveryPhase.RECONNECTING
            recoveryFailed = false
            _isRecovering.value = true
            suppressSends(true)
            try {
                runReconnectThenRestore(myGeneration, userInitiated)
            } finally {
                // Inner defer (RecoveryController.swift:166-170): idempotent even
                // on a mid-await cancel. Generation-guarded so a stale gen-N
                // coroutine's finally can never clobber a mid-flight gen-(N+1)'s
                // freshly-set state. Under the current serial/confined dispatcher
                // (faithful to Swift's @MainActor) this guard is a no-op — gen-N's
                // body fully unwinds before gen-(N+1) is dispatched — but it is
                // cheap insurance against a future re-entrant ordering change.
                // The OUTER `isRecoveryDispatched` clear stays ungated (matches
                // Swift, and gating it would risk stranding the dispatch lock).
                if (myGeneration == recoveryGeneration) {
                    _isRecovering.value = false
                    suppressSends(false)
                    lastRecoveryEndedAt = nowMs()
                }
            }
        } finally {
            // Outer defer (RecoveryController.swift:144).
            isRecoveryDispatched = false
        }
    }

    /**
     * The backoff reconnect loop + terminal restore. Only [reconnect] failures
     * retry the backoff array (RecoveryController.swift:178-210); once
     * reconnected we hand off to [restoreSession], whose failure is TERMINAL.
     */
    private suspend fun runReconnectThenRestore(myGeneration: ULong, userInitiated: Boolean) {
        var reconnected = false
        for (attempt in BACKOFF_SECONDS.indices) {
            val delaySeconds = BACKOFF_SECONDS[attempt]
            // Generation/cancellation checkpoint (RecoveryController.swift:179).
            if (myGeneration != recoveryGeneration || !currentlyActive()) return

            if (delaySeconds > 0) {
                try {
                    sleepMs(delaySeconds * 1_000L)
                } catch (_: CancellationException) {
                    return // cancelled during backoff (RecoveryController.swift:186-189)
                }
                if (myGeneration != recoveryGeneration) return
            }

            try {
                reconnect()
                reconnected = true
                break
            } catch (_: CancellationException) {
                return // cancelled during reconnect (RecoveryController.swift:197-199)
            } catch (_: Throwable) {
                if (attempt == BACKOFF_SECONDS.size - 1) {
                    // Last attempt failed -> terminal transport failure
                    // (RecoveryController.swift:202-207).
                    if (myGeneration != recoveryGeneration) return
                    recoveryFailed = true
                    _connectionTimedOut.value = true
                    recordAutoRecoveryOutcome(success = false, userInitiated = userInitiated)
                    return
                }
                // Otherwise fall through to the next backoff attempt.
            }
        }

        if (!reconnected || myGeneration != recoveryGeneration) return
        restoreSession(myGeneration, userInitiated)
    }

    /**
     * Records a recovery outcome and updates the circuit breaker
     * (RecoveryController.swift:217-234). Only AUTO (not user) failures count.
     */
    private fun recordAutoRecoveryOutcome(success: Boolean, userInitiated: Boolean) {
        if (success) {
            consecutiveAutoRecoveryFailures = 0
            _autoRecoverySuspended.value = false
            return
        }
        if (userInitiated) return
        consecutiveAutoRecoveryFailures += 1
        if (consecutiveAutoRecoveryFailures >= MAX_AUTO_RECOVERY_FAILURES) {
            _autoRecoverySuspended.value = true
        }
    }

    /**
     * Restores auth + the active session on the freshly-reconnected transport
     * (RecoveryController.swift:237-280). Failure here is TERMINAL — it accounts
     * the outcome ONCE and returns; it never re-enters the backoff loop.
     */
    private suspend fun restoreSession(generation: ULong, userInitiated: Boolean) {
        _phase.value = RecoveryPhase.AUTHENTICATING
        try {
            reauth()
            if (generation != recoveryGeneration) return
            _phase.value = RecoveryPhase.RESUMING
            resumeActive()
            if (generation != recoveryGeneration) return
        } catch (_: CancellationException) {
            return // restore cancelled (RecoveryController.swift:250-252)
        } catch (error: Throwable) {
            if (generation != recoveryGeneration) return
            recoveryFailed = true
            // App-level errors leave the connection intact; transport-level
            // errors time the connection out (RecoveryController.swift:257-271).
            if (isApplicationLevelError(error)) {
                _sessionAttachFailed.value = true
            } else {
                _connectionTimedOut.value = true
            }
            // BOTH branches still count toward the breaker
            // (RecoveryController.swift:272).
            recordAutoRecoveryOutcome(success = false, userInitiated = userInitiated)
            return
        }

        recordAutoRecoveryOutcome(success = true, userInitiated = userInitiated)
        if (generation != recoveryGeneration) return
        fetchSessions()
    }

    /**
     * Cancels any in-flight recovery and clears recovery UI state. Bumps the
     * generation so in-flight tasks bail at their next checkpoint, and suspends
     * the breaker so the next send failure doesn't immediately re-enter auto
     * recovery (RecoveryController.swift:284-300).
     */
    fun cancel() {
        recoveryGeneration += 1u
        recoveryJob?.cancel()
        recoveryJob = null
        _isRecovering.value = false
        // The cancelled pass's inner `finally` is generation-guarded (I2), so it
        // will NOT run its own `suppressSends(false)` (its captured generation no
        // longer matches the just-bumped value). Swift relies on the cancelled
        // Task's UNGATED defer to undo suppression; with the Android guard that
        // cleanup must happen here so a cancel can never strand
        // `suppressAllViewModelSends(true)`.
        suppressSends(false)
        isRecoveryDispatched = false
        recoveryFailed = true
        val now = nowMs()
        lastRecoveryEndedAt = now
        lastCancelledAt = now
        _autoRecoverySuspended.value = true
    }

    /**
     * Whether the recovery coroutine is still active (mirrors the Swift
     * `!Task.isCancelled` checkpoint at RecoveryController.swift:179).
     */
    private suspend fun currentlyActive(): Boolean = currentCoroutineContext().isActive

    // MARK: - Test hooks

    /** Read of the internal breaker failure counter (test parity assertions). */
    internal val consecutiveAutoFailuresForTest: Int get() = consecutiveAutoRecoveryFailures

    /** Seeds the breaker state for tests (Swift `_testOnly_setAutoRecoverySuspended`). */
    internal fun setBreakerForTest(suspended: Boolean, failures: Int) {
        _autoRecoverySuspended.value = suspended
        consecutiveAutoRecoveryFailures = failures
    }
}
