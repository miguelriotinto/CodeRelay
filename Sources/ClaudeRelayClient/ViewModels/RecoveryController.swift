import Foundation
import os.log
import ClaudeRelayKit

private let recoveryLog = Logger(subsystem: "com.claude.relay.client", category: "Recovery")

/// Owns the recovery state machine: auto-suspend circuit breaker, generation
/// tokens, cooldown tracking, and the `handleForegroundTransition` /
/// `restoreSession` flow. Extracted from `SharedSessionCoordinator` in the
/// v0.3.2 hardening follow-up so the coordinator can stay under the SwiftLint
/// type-body ceiling without losing call-site ergonomics (all public entry
/// points on `SharedSessionCoordinator` forward to the controller unchanged).
///
/// The controller holds an `unowned` reference back to the coordinator —
/// ownership flows coordinator → controller, and the controller never
/// outlives its coordinator.
///
/// Call-site invariant: every method is `@MainActor`-isolated, matching the
/// coordinator. Recovery state (`isRecovering`, `recoveryFailed`,
/// `recoveryPhase`, etc.) is intentionally kept on the coordinator because
/// SwiftUI binds to those `@Published` properties — collapsing them into a
/// value type stays deferred (see plan Task 3.5).
@MainActor
final class RecoveryController {

    private unowned let coordinator: SharedSessionCoordinator
    private let connection: RelayConnection

    // MARK: - Breaker + generation state

    /// Monotonic token bumped at the start of every recovery pass. A scheduled
    /// `onSendFailed`-triggered recovery only runs if the token it captured
    /// still matches — prevents a failed recovery from immediately queueing
    /// another.
    private var recoveryGeneration: UInt64 = 0
    /// Timestamp of the last recovery completion (success or failure). Used
    /// to enforce a cooldown on auto-triggered recoveries via `onSendFailed`.
    private var lastRecoveryEndedAt: Date = .distantPast
    /// Consecutive auto-triggered recovery failures. Reset on success or on
    /// any user-initiated recovery (foreground, network restored, explicit).
    private var consecutiveAutoRecoveryFailures = 0
    /// A socket connected within this many seconds is trusted as alive without a
    /// ping round-trip, so the foreground/launch transition won't reconnect it
    /// out from under the launch `fetchSessions`.
    static let freshConnectionWindow: TimeInterval = 6
    /// Minimum delay between `onSendFailed`-triggered recoveries, in seconds.
    private let autoRecoveryCooldown: TimeInterval = 3
    /// After this many back-to-back auto-recovery failures we stop responding
    /// to `onSendFailed` until an explicit user/foreground/network signal
    /// arrives.
    private let maxAutoRecoveryFailures = 3
    /// True when auto-retry has been circuit-broken. Cleared on explicit
    /// recovery entry.
    private var autoRecoverySuspended = false
    /// True once the server rejected the token as invalid. Unlike the
    /// failure-count breaker, this trips on the FIRST auth rejection and is
    /// cleared ONLY by user-initiated recovery (e.g. after re-pairing). This
    /// is what stops the silent reconnect storm against a known-bad token.
    private var authRejected = false
    /// Synchronous entry lock, distinct from `isRecovering` (which is set
    /// after `await isAlive()`). Prevents concurrent recovery dispatches
    /// from racing across the suspension point at the top of
    /// `handleForegroundTransition`.
    private var isRecoveryDispatched = false
    /// Timestamp set by `cancel`. `triggerUserRecovery` ignores calls within
    /// 1 s of a cancel to avoid sheet-dismiss → scenePhase → re-trigger.
    private var lastCancelledAt: Date = .distantPast

    init(coordinator: SharedSessionCoordinator, connection: RelayConnection) {
        self.coordinator = coordinator
        self.connection = connection
    }

    // MARK: - Breaker

    /// Clears the auto-recovery circuit breaker. No-op when the breaker is
    /// already idle so healthy steady-state traffic doesn't thrash.
    func resetAutoRecoveryBreaker() {
        guard autoRecoverySuspended || consecutiveAutoRecoveryFailures > 0 else { return }
        consecutiveAutoRecoveryFailures = 0
        autoRecoverySuspended = false
        recoveryLog.info("Auto-recovery breaker reset after healthy ping")
    }

    // MARK: - Entry points

    /// Auto-triggered recovery entry point (called from `onSendFailed`).
    /// Gated by: torn-down state, already-recovering, auto-suspend (circuit
    /// broken), and a cooldown since the last recovery ended. User-initiated
    /// recovery (foreground/network/explicit) goes through
    /// `handleForegroundTransition` directly, bypassing these gates — see
    /// `triggerUserRecovery`.
    func scheduleAutoRecovery() {
        guard !coordinator.isTornDown else { return }
        guard !coordinator.isPerformingHandshake else {
            recoveryLog.debug("scheduleAutoRecovery: handshake in flight, ignoring")
            return
        }
        guard !isRecoveryDispatched else {
            recoveryLog.debug("scheduleAutoRecovery: already dispatched, ignoring")
            return
        }
        guard !autoRecoverySuspended else {
            recoveryLog.info("scheduleAutoRecovery: auto-suspend active — awaiting user signal")
            return
        }
        guard !authRejected else {
            recoveryLog.info("scheduleAutoRecovery: token rejected — awaiting user re-pair")
            return
        }
        let elapsed = Date().timeIntervalSince(lastRecoveryEndedAt)
        guard elapsed >= autoRecoveryCooldown else {
            recoveryLog.debug("scheduleAutoRecovery: cooldown (\(elapsed, format: .fixed(precision: 2))s < \(self.autoRecoveryCooldown)s)")
            return
        }
        recoveryLog.info("scheduleAutoRecovery: queuing recovery attempt")
        isRecoveryDispatched = true
        coordinator.recoveryTask = Task { [weak self] in
            await self?.handleForegroundTransition(userInitiated: false)
        }
    }

    /// Explicit user-initiated recovery: foreground, network restored, QR
    /// rescan, etc. Clears the auto-suspend circuit breaker so auto-retry
    /// resumes after this attempt.
    ///
    /// Always routes through `handleForegroundTransition`, which probes the
    /// socket with a real ping (`isAlive()`) before deciding whether to
    /// reconnect. A previous fast-path here trusted `connection.state ==
    /// .connected` and called `fetchSessions()` directly — but on macOS sleep
    /// the system suspends the WebSocket without flipping `state` to
    /// `.disconnected`, so the fast-path silently skipped reconnect on wake.
    /// The overhead of one ping per foreground/wake hop is negligible
    /// compared to the user-visible cost of a missed reconnect.
    func triggerUserRecovery() {
        guard !coordinator.isTornDown else { return }
        // A handshake already IS "connect, authenticate, get the session list" —
        // the entirety of what recovery would do. Letting recovery in here is
        // precisely the cold-launch bug: `scenePhase → .active` fires while the
        // launch handshake is mid-flight, `forceReconnect()` swaps the socket,
        // and the in-flight `session_list` dies with it.
        guard !coordinator.isPerformingHandshake else {
            recoveryLog.debug("triggerUserRecovery: handshake in flight, ignoring")
            return
        }
        guard !isRecoveryDispatched else {
            recoveryLog.debug("triggerUserRecovery: already dispatched, ignoring")
            return
        }
        if Date().timeIntervalSince(lastCancelledAt) < 1 {
            recoveryLog.debug("triggerUserRecovery: within cancel debounce, ignoring")
            return
        }
        autoRecoverySuspended = false
        consecutiveAutoRecoveryFailures = 0
        authRejected = false
        isRecoveryDispatched = true
        coordinator.recoveryTask = Task { [weak self] in
            await self?.handleForegroundTransition(userInitiated: true)
        }
    }

    /// Arm the auth-rejected gate from outside the recovery flow (e.g. when
    /// the initial attach path observes an invalid token). Idempotent.
    /// Cleared by `triggerUserRecovery` when the user re-pairs.
    func markAuthRejected() {
        authRejected = true
    }

    // MARK: - Recovery flow

    /// - Parameter userInitiated: true when triggered by an explicit
    ///   user-intent signal (scenePhase active, network restored, manual
    ///   retry). Such signals clear the auto-suspend circuit breaker.
    ///   Auto-triggered calls (send failed) increment the failure counter
    ///   on loss.
    func handleForegroundTransition(userInitiated: Bool) async {
        defer { isRecoveryDispatched = false }
        guard !coordinator.isTornDown else { return }
        guard !coordinator.isPerformingHandshake else {
            recoveryLog.debug("handleForegroundTransition: handshake in flight, skipping")
            return
        }
        guard !coordinator.isRecovering else {
            recoveryLog.debug("handleForegroundTransition: already recovering, skipping")
            return
        }

        // A just-established socket (e.g. on cold launch, `scenePhase` flips to
        // `.active` right after connect()) is alive by construction — its first
        // ping/pong hasn't completed yet, so `isAlive()` would return false and
        // trigger a needless `forceReconnect()` that TEARS DOWN the launch
        // handshake mid-flight, leaving the pane empty. Trust a recently
        // connected socket and hand straight to the handshake. (Proven from
        // server logs: two auths ~3.5s apart at launch with a disconnect
        // between = this reconnect.)
        if connection.state == .connected,
           let connectedAt = connection.lastConnectedAt,
           Date().timeIntervalSince(connectedAt) < Self.freshConnectionWindow {
            recoveryLog.info("handleForegroundTransition: connection just established, handshaking")
            await coordinator.performHandshake(reason: .wake)
            return
        }

        // Ping first, rather than letting the handshake discover the problem:
        // after macOS sleep the socket is dead while `state` still reads
        // `.connected`, and the ping detects that in 5 s where the handshake's
        // auth would sit for its full 10 s timeout before retrying.
        let alive = await connection.isAlive()
        if alive {
            recoveryLog.info("handleForegroundTransition: connection alive, handshaking")
            await coordinator.performHandshake(reason: .wake)
            return
        }

        recoveryGeneration &+= 1
        let myGeneration = recoveryGeneration
        recoveryLog.info("Recovery start gen=\(myGeneration) userInitiated=\(userInitiated)")

        coordinator.recoveryPhase = .reconnecting
        coordinator.recoveryFailed = false
        coordinator.isRecovering = true
        coordinator.suppressAllViewModelSends(true)
        defer {
            coordinator.isRecovering = false
            coordinator.suppressAllViewModelSends(false)
            lastRecoveryEndedAt = Date()
        }

        // Extended from [0, 1, 2, 4] to accommodate launchd's typical respawn
        // latency. Coupled with `onHealthyPing`'s breaker reset, an immediate
        // post-reconnect ping clears the auto-suspend state, so longer total
        // backoff doesn't trap legitimate retries in the breaker.
        let delays: [UInt64] = [0, 1, 2, 4, 8, 15]
        var reconnected = false
        for (attempt, delay) in delays.enumerated() {
            guard !coordinator.isTornDown, myGeneration == recoveryGeneration, !Task.isCancelled else {
                recoveryLog.info("Recovery aborted during reconnect (gen=\(myGeneration))")
                return
            }
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    recoveryLog.info("Recovery cancelled during backoff (gen=\(myGeneration))")
                    return
                }
                guard !coordinator.isTornDown, myGeneration == recoveryGeneration else { return }
            }

            do {
                try await connection.forceReconnect()
                reconnected = true
                break
            } catch is CancellationError {
                recoveryLog.info("Recovery cancelled during forceReconnect (gen=\(myGeneration))")
                return
            } catch {
                recoveryLog.error("forceReconnect attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)")
                if attempt == delays.count - 1 {
                    guard !coordinator.isTornDown, myGeneration == recoveryGeneration else { return }
                    coordinator.recoveryFailed = true
                    coordinator.connectionTimedOut = true
                    recordAutoRecoveryOutcome(success: false, userInitiated: userInitiated)
                    return
                }
            }
        }

        guard reconnected, !coordinator.isTornDown, myGeneration == recoveryGeneration else { return }
        await restoreSession(generation: myGeneration, userInitiated: userInitiated)
    }

    /// Records the outcome of a recovery pass and updates the circuit breaker.
    private func recordAutoRecoveryOutcome(success: Bool, userInitiated: Bool) {
        if success {
            consecutiveAutoRecoveryFailures = 0
            autoRecoverySuspended = false
            recoveryLog.info("Recovery succeeded — counters reset")
            return
        }
        if userInitiated {
            recoveryLog.info("User-initiated recovery failed — not counting toward auto-suspend")
            return
        }
        consecutiveAutoRecoveryFailures += 1
        recoveryLog.info("Auto-recovery failure \(self.consecutiveAutoRecoveryFailures)/\(self.maxAutoRecoveryFailures)")
        if consecutiveAutoRecoveryFailures >= maxAutoRecoveryFailures {
            autoRecoverySuspended = true
            recoveryLog.error("Auto-recovery suspended after \(self.maxAutoRecoveryFailures) consecutive failures")
        }
    }

    /// Restores auth + active session on the current connection.
    func restoreSession(generation: UInt64, userInitiated: Bool) async {
        coordinator.recoveryPhase = .authenticating
        coordinator.sessionController?.resetAuth()
        do {
            let controller = try await coordinator.ensureAuthenticated()
            guard !coordinator.isTornDown, generation == recoveryGeneration else { return }
            if let activeId = coordinator.activeSessionId {
                coordinator.recoveryPhase = .resuming
                coordinator.terminalViewModels[activeId]?.resetForReplay()
                try await controller.resumeSession(id: activeId)
                guard !coordinator.isTornDown, generation == recoveryGeneration else { return }
                coordinator.wireTerminalOutput(to: activeId)
            }
        } catch is CancellationError {
            recoveryLog.info("restoreSession cancelled (gen=\(generation))")
            return
        } catch {
            recoveryLog.error("restoreSession failed (gen=\(generation)): \(error.localizedDescription, privacy: .public)")
            guard !coordinator.isTornDown, generation == recoveryGeneration else { return }
            coordinator.recoveryFailed = true
            // App-level errors leave the connection intact — user can retry without reconnecting
            if SharedSessionCoordinator.isApplicationLevelError(error) {
                if case SessionController.SessionError.authenticationFailed = error {
                    // Token rejected: stop auto-recovery entirely until the
                    // user re-pairs. Prevents the reconnect storm that trips
                    // the server's rate limiter.
                    authRejected = true
                }
                // Session no longer exists / invalid transition / etc. The
                // socket itself is fine — clear the active session and surface
                // a recoverable error. Don't tear the workspace down via
                // connectionTimedOut.
                if let activeId = coordinator.activeSessionId {
                    coordinator.evictTerminal(for: activeId)
                    coordinator.activeSessionId = nil
                }
                coordinator.sessionAttachError = coordinator.friendlyAttachErrorMessage(error)
                coordinator.sessionAttachFailed = true
            } else {
                coordinator.connectionTimedOut = true
            }
            recordAutoRecoveryOutcome(success: false, userInitiated: userInitiated)
            return
        }

        recoveryLog.info("restoreSession success (gen=\(generation))")
        recordAutoRecoveryOutcome(success: true, userInitiated: userInitiated)
        guard !coordinator.isTornDown, generation == recoveryGeneration else { return }
        // Same contract as every other entry: the pane is repopulated from the
        // server's token-scoped list, and a session another device took while we
        // were disconnected is announced here (we missed its live push).
        await coordinator.performHandshake(reason: .wake)
    }

    /// Cancels any in-flight recovery and clears recovery UI state. Bumps
    /// the generation so in-flight tasks bail at their next checkpoint.
    func cancel() {
        recoveryLog.info("cancelRecovery requested")
        recoveryGeneration &+= 1
        coordinator.recoveryTask?.cancel()
        coordinator.recoveryTask = nil
        coordinator.authCoordinator.cancelInFlight()
        coordinator.isRecovering = false
        isRecoveryDispatched = false
        coordinator.recoveryFailed = true
        let now = Date()
        lastRecoveryEndedAt = now
        lastCancelledAt = now
        // Explicit cancel means the user doesn't want us re-entering
        // auto-recovery immediately on the next send failure — let them
        // re-enter via scenePhase or a fresh network restore.
        autoRecoverySuspended = true
    }

    /// Called by `SharedSessionCoordinator.tearDown()` so any in-flight
    /// dispatch flag is cleared before the coordinator drops the task.
    func invalidate() {
        isRecoveryDispatched = false
    }

    // MARK: - Test hooks

    var _testOnly_autoRecoverySuspended: Bool { autoRecoverySuspended }
    var _testOnly_consecutiveAutoRecoveryFailures: Int { consecutiveAutoRecoveryFailures }
    var _testOnly_authRejected: Bool { authRejected }
    func _testOnly_setAuthRejected(_ value: Bool) { authRejected = value }

    func _testOnly_setAutoRecoverySuspended(_ suspended: Bool, failures: Int) {
        autoRecoverySuspended = suspended
        consecutiveAutoRecoveryFailures = failures
    }
}
