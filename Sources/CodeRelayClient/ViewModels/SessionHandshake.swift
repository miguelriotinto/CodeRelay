import Foundation
import os.log
import CodeRelayKit

private let handshakeLog = Logger(subsystem: "com.coderelay.client", category: "Handshake")

/// The one and only way the session pane gets populated:
///
///     open the socket → authenticate → ask the server which sessions this
///     client owns → render them
///
/// ALWAYS, on every entry into a live workspace: cold launch, foreground,
/// wake-from-sleep, network restored. No conditionals, no "only if the pane is
/// empty", no path that skips a step.
///
/// **Why this type exists.** That flow used to be spread across
/// `WorkspaceView.task`, `SessionCoordinator.start()`,
/// `RecoveryController.handleForegroundTransition` and `fetchSessions` — four
/// call sites racing each other over one socket, each with its own idea of
/// whether auth had happened. Five shipped fixes (#39–#43) each closed one race
/// and the pane still came up empty. The fix is not another guard: it's making
/// the sequence a single, single-flight, retrying unit that nothing else can
/// interleave with.
///
/// **Invariants this type enforces:**
/// 1. *Single-flight.* Concurrent callers (launch `.task` + `scenePhase`
///    foreground + network-restored all fire within ~100 ms of each other on a
///    cold launch) share ONE in-flight handshake. Nobody issues a second
///    `auth_request` or a parallel `session_list`.
/// 2. *No silent failure.* Every attempt either renders the server's list or
///    retries; total failure surfaces a real error. The old launch path caught
///    and dropped every error, so one transient RPC failure meant a
///    permanently blank pane.
/// 3. *Ordered.* Auth completes before `session_list` is sent. The auth
///    round-trip doubles as the liveness proof for the socket, so no separate
///    ping is needed (and a fresh socket can't be mistaken for a dead one).
/// 4. *Uninterruptible.* While a handshake runs, `RecoveryController` refuses
///    to reconnect — the #43 root cause was recovery tearing the socket out
///    from under the launch fetch.
@MainActor
public final class SessionHandshake {

    /// Why the handshake is running. Controls exactly one thing: whether
    /// sessions that vanished since the persisted baseline are reported.
    public enum Reason: Sendable {
        /// Cold app launch (or a macOS `MainWindow` hub re-created while the app
        /// kept running). Reports: the baseline from the last run is the
        /// "before", so sessions taken or ended while the app was closed are
        /// announced (spec §3b).
        case launch
        /// The app was already open and is coming back: foreground, wake from
        /// sleep, network restored, post-reconnect. Reports.
        case wake
        /// The slot was just built because the user enabled this server, or
        /// rebuilt after a bookmark edit. Silent: resets the baseline from the
        /// fresh list and reports nothing — a server that was off for days must
        /// not open with a list of old losses.
        case enable

        var label: String {
            switch self {
            case .launch: return "launch"
            case .wake:   return "wake"
            case .enable: return "enable"
            }
        }

        var reportsLosses: Bool {
            switch self {
            case .launch, .wake: return true
            case .enable:        return false
            }
        }
    }

    /// Retry schedule. Five attempts over ~3.75 s of delay. Front-loaded
    /// because the overwhelmingly common failure is a socket that was replaced
    /// microseconds ago (launch race, reconnect) and succeeds on the next try —
    /// while the tail accommodates a server that is still coming up.
    static let retryDelays: [Duration] = [
        .zero, .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2)
    ]

    private unowned let coordinator: SharedSessionCoordinator
    private let connection: RelayConnection

    /// The single in-flight handshake, if any. Concurrent callers await it.
    private var inFlight: Task<Bool, Never>?

    init(coordinator: SharedSessionCoordinator, connection: RelayConnection) {
        self.coordinator = coordinator
        self.connection = connection
    }

    // MARK: - Entry point

    /// Runs (or joins) the handshake. Returns true once the pane reflects the
    /// server's authoritative list for this token — including the legitimate
    /// "you own zero sessions" answer, which is a SUCCESS, not a retry case.
    @discardableResult
    func perform(reason: Reason) async -> Bool {
        // `.enable` is silent per SLOT, not per pass: drop the stale baseline
        // before any await, so a refresh that applies a list ahead of this
        // handshake has nothing to diff against either.
        if case .enable = reason { coordinator.clearLossBaseline() }

        // Single-flight. A second caller does not get its own pass: the
        // in-flight one is already doing precisely what it wants, and a
        // parallel `session_list` could cross-deliver (replies are matched by
        // response TYPE — the protocol has no request ids).
        if let existing = inFlight {
            handshakeLog.debug("\(reason.label, privacy: .public) handshake joining in-flight pass")
            return await existing.value
        }

        // Set synchronously — BEFORE the task exists — so a recovery trigger
        // that lands between here and the task's first line is still gated out.
        coordinator.isPerformingHandshake = true
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.run(reason: reason)
        }
        inFlight = task
        let result = await task.value
        // Only the originator clears the slot; joiners must not.
        if inFlight == task {
            inFlight = nil
            coordinator.isPerformingHandshake = false
            // Every outcome — success, failure, cancellation — ends the
            // handshake's turn narrating the empty pane.
            clearLoadPhase()
        }
        return result
    }

    /// Clears the in-flight slot on teardown so a coordinator that goes away
    /// mid-handshake doesn't leave the recovery gate armed.
    func invalidate() {
        inFlight?.cancel()
        inFlight = nil
        coordinator.isPerformingHandshake = false
        coordinator.sessionLoadPhase = nil
    }

    // MARK: - The flow

    private func run(reason: Reason) async -> Bool {
        guard !coordinator.isTornDown else { return false }

        for (attempt, delay) in Self.retryDelays.enumerated() {
            if delay != .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return false      // cancelled during backoff
                }
            }
            guard !coordinator.isTornDown else { return false }

            do {
                // 1. A socket. `state != .connected` covers both "never
                //    connected" and "the socket died since" — including the
                //    case where the receive loop failed without bumping the
                //    connection generation.
                if connection.state != .connected {
                    coordinator.recoveryPhase = .reconnecting
                    setLoadPhase(.connecting)
                    try await connection.forceReconnect()
                }

                // 2. Authenticate. This is also the liveness proof: the
                //    auth_request → auth_success round-trip exercises the full
                //    socket end to end. A separate ping would tell us less
                //    (the server answers pings pre-auth) and later.
                coordinator.recoveryPhase = .authenticating
                setLoadPhase(.authenticating)
                let controller = try await coordinator.ensureAuthenticated()
                guard !coordinator.isTornDown else { return false }

                // 3. Ask the server which sessions this client owns.
                //    `listSessions()` is TOKEN-scoped server-side — that IS the
                //    answer to "what do I own", and the server is authoritative.
                setLoadPhase(.loadingSessions)
                let owned = try await controller.listSessions()
                guard !coordinator.isTornDown else { return false }

                // 4. Render. `reconcile` diffs against the persisted
                //    baseline and returns what this token no longer lists.
                let lost = coordinator.reconcile(tokenScoped: owned)
                if reason.reportsLosses {
                    await coordinator.reportLosses(lost)
                }
                guard !coordinator.isTornDown else { return false }

                // A completed handshake means the connection is demonstrably
                // healthy: clear any stale failure banners from an earlier pass.
                coordinator.recoveryFailed = false
                coordinator.connectionTimedOut = false
                handshakeLog.info("""
                    \(reason.label, privacy: .public) handshake OK on attempt \
                    \(attempt + 1, privacy: .public): \(owned.count, privacy: .public) session(s)
                    """)
                return true

            } catch is CancellationError {
                handshakeLog.info("\(reason.label, privacy: .public) handshake cancelled")
                return false

            } catch let error as SessionController.SessionError where Self.isTokenRejection(error) {
                // Retrying a rejected token cannot succeed, and hammering the
                // server trips its rate limiter. Stop and tell the user to
                // re-pair; arm the recovery gate so nothing retries silently.
                handshakeLog.error("\(reason.label, privacy: .public) handshake: token rejected — not retrying")
                coordinator.recoveryController.markAuthRejected()
                fail(reason: reason, error: error)
                return false

            } catch {
                handshakeLog.error("""
                    \(reason.label, privacy: .public) handshake attempt \
                    \(attempt + 1, privacy: .public)/\(Self.retryDelays.count, privacy: .public) failed: \
                    \(error.localizedDescription, privacy: .public)
                    """)
                // Assume the socket is the problem, because it usually is: a
                // launch/reconnect race replaced it, or it died silently. Drop
                // both it and the auth bound to it so the next attempt starts
                // from a clean, freshly-authenticated socket rather than
                // retrying over the same broken transport.
                coordinator.authCoordinator.resetAuth()
                connection.disconnect()

                if attempt == Self.retryDelays.count - 1 {
                    fail(reason: reason, error: error)
                    return false
                }
            }
        }
        return false
    }

    // MARK: - Outcomes

    /// Surface a handshake that could not complete. Deliberately does NOT set
    /// `connectionTimedOut` — that tears the workspace down on iOS, and the
    /// right response to "couldn't load the list" is to let the user retry
    /// (pull-to-refresh, or the next foreground) against a workspace that is
    /// still on screen.
    // MARK: - Loading overlay

    /// The handshake narrates itself only while there is no pane to look at.
    /// With a session already on screen (a `.wake` pass), "Authenticating…"
    /// over a live terminal would be noise — and wrong, since the terminal is
    /// not what is loading.
    private func setLoadPhase(_ phase: SessionLoadPhase) {
        if coordinator.activeSessionId == nil { coordinator.sessionLoadPhase = phase }
    }

    /// Stands the overlay down at the end of a pass, unless an F3 restore is
    /// about to take it over (`switchToSession` then owns the phase).
    private func clearLoadPhase() {
        if coordinator.activeSessionId == nil, coordinator.pendingRestoreSessionId == nil {
            coordinator.sessionLoadPhase = nil
        }
    }

    private func fail(reason: Reason, error: Error) {
        coordinator.recoveryFailed = true
        let detail = coordinator.friendlyAttachErrorMessage(error)
        handshakeLog.error("\(reason.label, privacy: .public) handshake FAILED: \(detail, privacy: .public)")
        coordinator.presentError("Couldn't load your sessions from the server. \(detail)")
    }

    /// True for errors that mean "this token will never be accepted", as
    /// opposed to a transport hiccup worth retrying.
    private static func isTokenRejection(_ error: SessionController.SessionError) -> Bool {
        switch error {
        case .authenticationFailed, .versionIncompatible:
            return true
        // `connectionDesynchronized` is emphatically retriable: it means a
        // previous RPC timed out and left the socket uncorrelated, and this
        // catch's `resetAuth()` + `disconnect()` is precisely the cure — the
        // next attempt reconnects onto a clean socket.
        case .unexpectedResponse, .timeout, .connectionDesynchronized:
            return false
        }
    }

    // MARK: - Test hooks

    var _testOnly_hasInFlight: Bool { inFlight != nil }
}
