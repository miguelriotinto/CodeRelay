import Foundation
import ClaudeRelayKit

/// Common protocol implemented by the iOS and Mac `SessionCoordinator` classes.
///
/// Describes the session-lifecycle surface area shared between the two apps.
/// Platform-specific additions (menu commands, keyboard shortcuts, sleep/wake
/// handlers) are intentionally out of scope — this protocol only formalizes
/// what both apps have in common.
///
/// **Why this exists:** enables shared unit tests (via mocks conforming to
/// this protocol) and documents the stable core API that future shared
/// ViewModel extraction can build on.
@MainActor
public protocol SessionCoordinating: AnyObject {

    // MARK: - State

    /// All sessions returned by the most recent server list.
    var sessions: [SessionInfo] { get }

    /// The session currently attached in the UI, or nil if none is attached.
    var activeSessionId: UUID? { get }

    /// Maps session IDs to the coding agent currently running in them (server-reported).
    var agentSessions: [UUID: String] { get }

    /// Session IDs currently idle while a coding agent is running (server-reported).
    var sessionsAwaitingInput: Set<UUID> { get }

    // MARK: - Names

    /// Returns the display name for a session, falling back to the short ID.
    func name(for id: UUID) -> String

    /// Renames a session locally and broadcasts the rename to the server.
    func setName(_ name: String, for id: UUID)

    // MARK: - Activity

    /// Returns the agent ID running in this session, or nil.
    func activeAgent(for sessionId: UUID) -> String?

    /// Whether any coding agent is currently running in the given session.
    func isRunningAgent(sessionId: UUID) -> Bool

    // MARK: - Lifecycle

    /// Refresh the session list from the server. `force` bypasses the
    /// throttle debounce for post-mutation fetches (create / attach / switch)
    /// that must refresh immediately.
    func fetchSessions(force: Bool) async

    /// Create a new session, attach to it, and make it active.
    func createNewSession() async

    /// Detach from the current session (if any) and resume the target session.
    func switchToSession(id: UUID) async

    /// Terminate a session server-side and remove it from local state.
    func terminateSession(id: UUID) async

    /// List sessions running on the server that this device does not own.
    /// Used for cross-device attach flows.
    func fetchAttachableSessions() async -> [SessionInfo]

    /// Attach to a remote session, taking it over from its previous device.
    func attachRemoteSession(id: UUID, serverName: String?) async

    // MARK: - Recovery & Teardown

    /// Handle the app returning to the foreground. Pings the WebSocket, and
    /// if it's dead, reconnects + re-auths + resumes the active session.
    func handleForegroundTransition() async

    /// Cancel any in-flight recovery, detach the current session, and disconnect.
    func tearDown()
}

public extension SessionCoordinating {
    /// Refresh the session list, honoring the throttle debounce. Convenience
    /// forwarder so callers that don't need to force a refresh can omit the
    /// argument (Swift protocol requirements can't carry default values).
    func fetchSessions() async { await fetchSessions(force: false) }
}
