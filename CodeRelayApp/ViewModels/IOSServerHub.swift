import Foundation
import CodeRelayClient

typealias IOSServerHub = ServerHub<SessionCoordinator>

/// Builds the one hub the app owns (multi-server spec §7, §8.2).
@MainActor
enum IOSServerHubFactory {
    /// The single-server build's `@AppStorage("lastConnectedServerId")`; the
    /// hub's one-time migration reads and retires it (spec §9).
    static let lastServerIdKey = "lastConnectedServerId"

    /// One coordinator per bookmark, each with its own ownership namespace so
    /// two relays never share a session-name map (D8).
    static func makeCoordinator(config: ConnectionConfig, token: String) -> SessionCoordinator {
        SessionCoordinator(config: config, token: token,
                           ownershipKeyPrefix: "\(SessionCoordinator.keyPrefix).\(config.id.uuidString)")
    }

    static func make(defaults: UserDefaults = .standard) -> IOSServerHub {
        #if DEBUG
        if HubPreviewSeed.isEnabled {
            let seed = HubPreviewSeed.makeStores(keyPrefix: SessionCoordinator.keyPrefix,
                                                 deviceId: DeviceIdentifier().currentID)
            return ServerHub(
                bookmarks: seed.bookmarks,
                tokens: seed.tokens,
                stateStore: seed.state,
                keyPrefix: SessionCoordinator.keyPrefix,
                lastServerIdKey: lastServerIdKey,
                defaults: seed.defaults,
                factory: { config, token in makeCoordinator(config: config, token: token) })
        }
        #endif
        return ServerHub(
            bookmarks: CodeRelayApp.savedConnections,
            tokens: AuthManager.shared,
            stateStore: HubStateStore(keyPrefix: SessionCoordinator.keyPrefix,
                                      deviceId: DeviceIdentifier().currentID, defaults: defaults),
            keyPrefix: SessionCoordinator.keyPrefix,
            lastServerIdKey: lastServerIdKey,
            defaults: defaults,
            factory: { config, token in makeCoordinator(config: config, token: token) })
    }
}
