#if DEBUG
import Foundation
import CodeRelayClient
import CodeRelayKit

/// `CODERELAY_HUB_SEED=1` makes the first `ServerHub` publish three canned
/// sections (live-if-a-relay-answers, token-rejected, disabled) so the sidebar,
/// menu bar and server window can be screenshot-verified without three relays.
/// Everything lives in an isolated `UserDefaults` suite; the real bookmarks,
/// tokens and hub state are never touched.
@MainActor
enum HubPreviewSeed {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["CODERELAY_HUB_SEED"] == "1" }

    static let suiteName = "hub-seed"

    static func bookmarks() -> [ConnectionConfig] {
        [ConnectionConfig(name: "studio", host: "127.0.0.1", port: 9200, enabled: true),
         ConnectionConfig(name: "build-box", host: "10.0.0.9", port: 9200, enabled: true),
         ConnectionConfig(name: "laptop", host: "10.0.0.10", port: 9200, enabled: false)]
    }

    /// Only the first bookmark has a token, so the second renders `authFailed`
    /// without a single connection attempt. The first borrows the real token of
    /// the user's own loopback bookmark when there is one — a made-up token
    /// would burn the local relay's auth budget (10 failures / 60 s blocks the
    /// IP) and could lock the real app out of 127.0.0.1.
    final class Tokens: TokenProviding {
        let tokenId: UUID
        let borrowed: String?
        init(tokenId: UUID, borrowed: String?) { self.tokenId = tokenId; self.borrowed = borrowed }
        func loadToken(for connectionId: UUID) throws -> String? {
            connectionId == tokenId ? borrowed : nil
        }
    }

    private static func borrowLoopbackToken() -> String? {
        CodeRelayMacApp.savedConnections.loadAll()
            .first(where: { ["127.0.0.1", "localhost", "::1"].contains($0.host) })
            .flatMap { try? AuthManager.shared.loadToken(for: $0.id) }
    }

    /// A fresh suite with the three bookmarks saved and the migration already
    /// marked done, so `HubMigration` does not disable the second server.
    static func makeStores(keyPrefix: String, deviceId: String)
        -> (defaults: UserDefaults, bookmarks: SavedConnectionStore, tokens: Tokens, state: HubStateStore) {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let list = bookmarks()
        let store = SavedConnectionStore(key: "hub-seed.savedConnections", defaults: defaults)
        store.saveAll(list)
        let state = HubStateStore(keyPrefix: keyPrefix, deviceId: deviceId, defaults: defaults)
        state.markMigrated()
        return (defaults, store, Tokens(tokenId: list[0].id, borrowed: borrowLoopbackToken()), state)
    }
}
#endif
