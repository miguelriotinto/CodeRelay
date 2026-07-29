import Foundation
import os.log
import ClaudeRelayKit

private let handshakeLog = Logger(subsystem: "com.claude.relay.client", category: "Handshake")

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
    /// sessions that vanished from the server's list are announced to the user.
    public enum Reason: Sendable {
        /// Cold app launch. Sessions another client took while this app was
        /// closed are simply absent from the list — the user is NOT told, per
        /// product spec: there is no "before" to compare against, and reporting
        /// it on every launch is noise.
        case launch
        /// The app was already open and is coming back: foreground, wake from
        /// sleep, network restored, post-reconnect. Here there IS a "before", so
        /// a session that dropped out of the list while we were away is
        /// announced as "attached from another device" — the live
        /// `session_stolen` push that would normally do it was missed because
        /// our socket was down.
        case wake

        var label: String {
            switch self {
            case .launch: return "launch"
            case .wake:   return "wake"
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
        }
        return result
    }

    /// Clears the in-flight slot on teardown so a coordinator that goes away
    /// mid-handshake doesn't leave the recovery gate armed.
    func invalidate() {
        inFlight?.cancel()
        inFlight = nil
        coordinator.isPerformingHandshake = false
    }

    // MARK: - The flow

    private func run(reason: Reason) async -> Bool {
        guard !coordinator.isTornDown else { return false }

        // Snapshot the pane BEFORE the fetch so a `.wake` pass can tell the
        // user which sessions another device took while we were away. Captured
        // with names, because `reconcile` prunes the name map to the server's
        // list — after it runs, the lost session's name is gone.
        let before: [(id: UUID, name: String)] = coordinator.activeSessions
            .map { ($0.id, coordinator.name(for: $0.id)) }

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
                    try await connection.forceReconnect()
                }

                // 2. Authenticate. This is also the liveness proof: the
                //    auth_request → auth_success round-trip exercises the full
                //    socket end to end. A separate ping would tell us less
                //    (the server answers pings pre-auth) and later.
                coordinator.recoveryPhase = .authenticating
                let controller = try await coordinator.ensureAuthenticated()
                guard !coordinator.isTornDown else { return false }

                // 3. Ask the server which sessions this client owns.
                //    `listSessions()` is TOKEN-scoped server-side — that IS the
                //    answer to "what do I own", and the server is authoritative.
                let owned = try await controller.listSessions()
                guard !coordinator.isTornDown else { return false }

                // 4. Render.
                coordinator.reconcile(tokenScoped: owned)
                if case .wake = reason {
                    announceSessionsTakenElsewhere(before: before)
                }

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

    /// Report a session that dropped out of the server's list while we were
    /// away. One OK-only notice is enough — this is a notification, not a queue.
    private func announceSessionsTakenElsewhere(before: [(id: UUID, name: String)]) {
        let stillOwned = Set(coordinator.sessions.map { $0.id })
        guard let lost = Self.firstLostSession(before: before, stillOwned: stillOwned) else { return }
        handshakeLog.info("wake handshake: session \(lost.id, privacy: .public) is no longer ours")
        coordinator.activityCoordinator.presentStolenAlert(sessionId: lost.id, name: lost.name)
    }

    /// The first session that was in the pane before the handshake and is not in
    /// the server's fresh token-scoped list — i.e. another device attached it
    /// while we were away. Pure, so the rule is testable without a server.
    ///
    /// `before` arrives ordered by `createdAt` (it comes from `activeSessions`),
    /// so the session reported is deterministic rather than set-iteration luck.
    static func firstLostSession(
        before: [(id: UUID, name: String)],
        stillOwned: Set<UUID>
    ) -> (id: UUID, name: String)? {
        before.first { !stillOwned.contains($0.id) }
    }

    /// Surface a handshake that could not complete. Deliberately does NOT set
    /// `connectionTimedOut` — that tears the workspace down on iOS, and the
    /// right response to "couldn't load the list" is to let the user retry
    /// (pull-to-refresh, or the next foreground) against a workspace that is
    /// still on screen.
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
