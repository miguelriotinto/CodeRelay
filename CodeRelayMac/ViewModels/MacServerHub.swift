import Foundation
import CodeRelayClient

typealias MacServerHub = ServerHub<SessionCoordinator>

/// Builds the one hub the main window owns (multi-server spec §7, §8.3).
@MainActor
enum MacServerHubFactory {
    /// The single-server build's "last used server" key; the hub's one-time
    /// migration reads and retires it (spec §9).
    static let lastServerIdKey = "com.clauderelay.mac.lastServerId"

    /// One coordinator per bookmark, each with its own ownership namespace so
    /// two relays never share a session-name map (D8).
    static func makeCoordinator(config: ConnectionConfig, token: String) -> SessionCoordinator {
        SessionCoordinator(config: config, token: token,
                           ownershipKeyPrefix: "\(SessionCoordinator.keyPrefix).\(config.id.uuidString)")
    }

    static func make(defaults: UserDefaults = .standard) -> MacServerHub {
        ServerHub(
            bookmarks: CodeRelayMacApp.savedConnections,
            tokens: AuthManager.shared,
            stateStore: HubStateStore(keyPrefix: SessionCoordinator.keyPrefix,
                                      deviceId: DeviceIdentifier().currentID, defaults: defaults),
            keyPrefix: SessionCoordinator.keyPrefix,
            lastServerIdKey: lastServerIdKey,
            defaults: defaults,
            factory: { config, token in makeCoordinator(config: config, token: token) })
    }
}
