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

    /// - Parameters:
    ///   - bookmarks/tokens: injectable so tests run over an isolated store and
    ///     stub tokens — the one-time migration REWRITES the bookmark store it is
    ///     given, so a test over the real one would disable the user's servers.
    static func make(defaults: UserDefaults = .standard,
                     bookmarks: SavedConnectionStore = CodeRelayApp.savedConnections,
                     tokens: TokenProviding = AuthManager.shared) -> IOSServerHub {
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
            bookmarks: bookmarks,
            tokens: tokens,
            stateStore: HubStateStore(keyPrefix: SessionCoordinator.keyPrefix,
                                      deviceId: DeviceIdentifier().currentID, defaults: defaults),
            keyPrefix: SessionCoordinator.keyPrefix,
            lastServerIdKey: lastServerIdKey,
            defaults: defaults,
            factory: { config, token in makeCoordinator(config: config, token: token) })
    }
}
