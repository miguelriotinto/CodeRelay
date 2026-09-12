import Foundation
import CodeRelayKit

/// Owns the authentication surface previously embedded in
/// `SharedSessionCoordinator`:
///
/// - `SessionController` instance bound to the connection
/// - Single-flight `authTask` so concurrent `ensureAuthenticated()` callers
///   share one in-flight `auth_request` instead of racing into "Already
///   authenticated" rejects on the server.
/// - `withAuth { ... }` helper that auto-retries once on stale-auth errors
///   (server replies "Not authenticated" after a transport reconnect).
///
/// The coordinator creates one `AuthCoordinator` per `RelayConnection` + token
/// pair and calls `withAuth { controller in ... }` for every session-lifecycle
/// operation.
@MainActor
public final class AuthCoordinator {

    // MARK: - Dependencies

    public let connection: RelayConnection
    public let token: String

    /// Fires once on each successful authentication. Replaces the previous
    /// `open func didAuthenticate()` subclass hook. Platform subclasses that
    /// used to override `didAuthenticate` now set this closure.
    public var onAuthenticated: (() -> Void)?

    // MARK: - State

    /// The current `SessionController`. Created on first `ensureAuthenticated`
    /// and reused across retries until `resetAuth()` drops it.
    public var sessionController: SessionController?

    /// Single-flight: concurrent callers to `ensureAuthenticated` await the
    /// same in-flight Task. Without this, two coordinated flows (e.g.
    /// scenePhase resume + user tap) each send their own `auth_request` and
    /// the second one hits the server's "Already authenticated" reject path.
    private var authTask: Task<SessionController, Error>?

    // MARK: - Init

    public init(connection: RelayConnection, token: String) {
        self.connection = connection
        self.token = token
    }

    // MARK: - API

    /// True when the cached `sessionController` reports auth valid for the
    /// current `connection.generation`. `forceReconnect()` bumps the
    /// generation; the controller's `isAuthValid` reads through it so the
    /// coordinator can detect the post-reconnect stale-auth state without
    /// having to explicitly invalidate.
    public var isAuthValid: Bool {
        sessionController?.isAuthValid == true
    }

    /// Clear the local auth bit so the next operation re-authenticates. Does
    /// NOT tear down the connection — used when the server replied "Not
    /// authenticated" after a reconnect.
    public func resetAuth() {
        sessionController?.resetAuth()
    }

    /// Return an authenticated `SessionController`. Concurrent callers share
    /// the same in-flight authentication Task.
    public func ensureAuthenticated() async throws -> SessionController {
        if let controller = sessionController, controller.isAuthValid {
            return controller
        }
        if let existing = authTask {
            return try await existing.value
        }
        let task = Task<SessionController, Error> { [weak self] in
            guard let self else { throw SessionController.SessionError.timeout }
            let controller = self.sessionController ?? SessionController(connection: self.connection)
            try await controller.authenticate(token: self.token)
            self.sessionController = controller
            self.onAuthenticated?()
            return controller
        }
        authTask = task
        defer { if authTask == task { authTask = nil } }
        return try await task.value
    }

    /// Run `body` with an authenticated controller. If the body throws an
    /// `isNotAuthenticated`-shaped error (server sees a fresh unauthenticated
    /// handler after a reconnect), reset auth and retry exactly once.
    public func withAuth<T>(_ body: (SessionController) async throws -> T) async throws -> T {
        let controller = try await ensureAuthenticated()
        do {
            return try await body(controller)
        } catch let error as SessionController.SessionError where error.isNotAuthenticated {
            sessionController?.resetAuth()
            let retryController = try await ensureAuthenticated()
            return try await body(retryController)
        }
    }

    /// Cancel any in-flight authentication attempt, but keep the existing
    /// `sessionController` intact. Used by `cancelRecovery` so the user can
    /// reconnect without immediately forcing a fresh `auth_request`.
    public func cancelInFlight() {
        authTask?.cancel()
        authTask = nil
    }

    /// Cancel any in-flight authentication AND drop the cached controller.
    /// Used by `tearDown` when the coordinator is going away permanently.
    public func invalidate() {
        authTask?.cancel()
        authTask = nil
        sessionController = nil
    }
}
