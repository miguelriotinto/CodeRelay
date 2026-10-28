import Foundation
import CodeRelayKit

/// Where one server stands, for its sidebar header (spec §7.2, §8.1).
public enum ServerSectionStatus: Equatable, Sendable {
    case connecting
    case live
    case reconnecting
    case offline
    case authFailed(String)
    case disabled

    public var isLive: Bool { self == .live }

    // Six named inputs beat a one-use parameter struct; every caller is a test or `publish()`.
    // swiftlint:disable function_parameter_count
    /// Pure derivation from a coordinator's published flags. Order matters:
    /// a rejected token beats everything (recovery will not retry it), recovery
    /// beats the raw socket state, and a connected socket still mid-handshake
    /// is "connecting" rather than "live".
    public static func derive(enabled: Bool,
                              connection: RelayConnection.ConnectionState,
                              isRecovering: Bool,
                              isPerformingHandshake: Bool,
                              authRejected: Bool,
                              recoveryFailed: Bool) -> ServerSectionStatus {
        // swiftlint:enable function_parameter_count
        guard enabled else { return .disabled }
        if authRejected { return .authFailed("Token rejected by the relay") }
        if isRecovering { return .reconnecting }
        switch connection {
        case .connected: return isPerformingHandshake ? .connecting : .live
        case .connecting: return .connecting
        default: return .offline
        }
    }
}

/// One server's slice of the sidebar.
public struct ServerSection: Identifiable, Equatable {
    public var id: UUID { config.id }
    public var config: ConnectionConfig
    public var status: ServerSectionStatus
    /// Live list while `status.isLive`; the last live list otherwise (D4).
    public var sessions: [SessionInfo]
    public var isCached: Bool
    public var rollups: [WorkspaceRollup]
    public var awaitingInput: Int
    public var isCollapsed: Bool
    /// Another bookmark learned the same instance id (spec §10, §12).
    public var isDuplicateInstance: Bool = false

    public init(config: ConnectionConfig, status: ServerSectionStatus, sessions: [SessionInfo],
                isCached: Bool, rollups: [WorkspaceRollup], awaitingInput: Int, isCollapsed: Bool,
                isDuplicateInstance: Bool = false) {
        self.config = config
        self.status = status
        self.sessions = sessions
        self.isCached = isCached
        self.rollups = rollups
        self.awaitingInput = awaitingInput
        self.isCollapsed = isCollapsed
        self.isDuplicateInstance = isDuplicateInstance
    }

    /// Header label: the relay's own name when learned, else the bookmark name.
    public var title: String { config.displayName ?? config.name }
}

/// Cross-server counts for badges and the menu bar (spec §7.6). Cached
/// sections contribute nothing.
public struct HubAggregate: Equatable {
    public var liveServers = 0
    public var totalServers = 0
    public var enabledServers = 0
    public var sessionsAwaitingInput = 0
    public var workingSessions = 0
    public init() {}
}
