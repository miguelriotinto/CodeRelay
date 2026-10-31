import Foundation
import Combine
import CodeRelayKit

/// What the multi-server hub needs from one per-server coordinator (spec §7).
///
/// `SharedSessionCoordinator` conforms; tests use a scripted fake. The surface
/// is deliberately the coordinator's EXISTING API plus the four Phase-1 hooks
/// (`detachActive`, `serverIdentity`, `isAuthRejected`, `start`) — the hub must
/// not grow a parallel session model.
@MainActor
public protocol ServerSlotCoordinating: AnyObject, ObservableObject {
    var sessions: [SessionInfo] { get }
    var activeSessions: [SessionInfo] { get }
    var activeSessionId: UUID? { get }
    var isRecovering: Bool { get }
    var recoveryFailed: Bool { get }
    var isAuthRejected: Bool { get }
    var isPerformingHandshake: Bool { get }
    var connectionState: RelayConnection.ConnectionState { get }
    var serverIdentity: ServerIdentity? { get }
    var sessionLoadPhase: SessionLoadPhase? { get }
    var activityCoordinator: ActivityCoordinator { get }
    /// Sessions this server lost while away (or live, for a steal), classified.
    var onSessionsLost: ((SessionLossReport) -> Void)? { get set }

    func start() async
    func switchToSession(id: UUID) async
    func createNewSession() async
    func detachActive() async
    func handleForegroundTransition(userInitiated: Bool) async
    func triggerUserRecovery()
    func tearDown()
    func syncPushRegistration(pushEnabled: Bool, notifyOnFinished: Bool) async
    func attachRemoteSession(id: UUID, serverName: String?) async
    func fetchSessions(force: Bool) async
    /// Returns once no handshake, recovery or session fetch is in flight —
    /// including one already running when called; immediately when idle.
    func awaitPassFinished() async
}

/// Keychain lookup the hub uses to build a coordinator. `AuthManager` conforms.
public protocol TokenProviding: AnyObject {
    func loadToken(for connectionId: UUID) throws -> String?
}

/// Optional companion to `TokenProviding` for bookmark deletion.
public protocol TokenDeleting: AnyObject {
    func deleteTokenIgnoringErrors(for connectionId: UUID)
}

extension AuthManager: TokenProviding {}

extension AuthManager: TokenDeleting {
    public func deleteTokenIgnoringErrors(for connectionId: UUID) { try? deleteToken(for: connectionId) }
}
