import Foundation
import CodeRelayKit

/// One-time move from the single-server layout to per-server namespaces
/// (multi-server spec §9). Runs before the first `ServerHub.start()`.
///
/// Only the bookmark the old `lastServerId` names keeps `enabled = true`, so
/// the upgrade looks exactly like the previous build (G8); turning on other
/// servers is an explicit action on the management screen. Legacy maps that
/// belong to no surviving bookmark are dropped rather than guessed onto one.
@MainActor
public enum HubMigration {

    // The migration is called once, from `ServerHub.init`; its inputs are the hub's own.
    // swiftlint:disable function_parameter_count
    @discardableResult
    public static func run(defaults: UserDefaults,
                           keyPrefix: String,
                           deviceId: String,
                           bookmarks: SavedConnectionStore,
                           lastServerIdKey: String,
                           stateStore: HubStateStore) -> Bool {
        // swiftlint:enable function_parameter_count
        guard !stateStore.isMigrated else { return false }
        var all = bookmarks.loadAll()
        let lastId = defaults.string(forKey: lastServerIdKey).flatMap(UUID.init(uuidString:))
        let keep: UUID? = {
            if let lastId, all.contains(where: { $0.id == lastId }) { return lastId }
            if all.count == 1 { return all[0].id }
            return nil
        }()

        let legacy = SessionOwnershipStore(keyPrefix: keyPrefix, deviceId: deviceId, defaults: defaults)
        if let keep {
            let target = SessionOwnershipStore(keyPrefix: "\(keyPrefix).\(keep.uuidString)",
                                               deviceId: deviceId, defaults: defaults)
            target.saveNames(legacy.loadNames())
            target.saveAgents(legacy.loadAgents())
            target.saveCollapsedGroups(legacy.loadCollapsedGroups())
            if let active = legacy.loadActiveSession() {
                stateStore.saveActiveRef(SessionRef(serverId: keep, sessionId: active))
            }
        }
        for key in [legacy.namesKey, legacy.agentsKey, legacy.activeSessionKey, legacy.collapsedGroupsKey, lastServerIdKey] {
            defaults.removeObject(forKey: key)
        }
        for i in all.indices { all[i].enabled = (all[i].id == keep) }
        bookmarks.saveAll(all)
        stateStore.markMigrated()
        return true
    }
}
