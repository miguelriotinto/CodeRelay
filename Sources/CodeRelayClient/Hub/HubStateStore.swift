import Foundation
import CodeRelayKit

/// UserDefaults for the hub itself (spec §9): the global active ref, which
/// server sections are collapsed, and the one-time migration flag. Everything
/// per server stays in that server's `SessionOwnershipStore` namespace.
@MainActor
public final class HubStateStore {
    public let activeRefKey: String
    public let collapsedServersKey: String
    public let migratedKey: String
    private let defaults: UserDefaults

    public init(keyPrefix: String, deviceId: String, defaults: UserDefaults = .standard) {
        activeRefKey = "\(keyPrefix).hub.activeRef.\(deviceId)"
        collapsedServersKey = "\(keyPrefix).hub.collapsedServers.\(deviceId)"
        migratedKey = "\(keyPrefix).hub.migrated"
        self.defaults = defaults
    }

    public func loadActiveRef() -> SessionRef? {
        guard let data = defaults.data(forKey: activeRefKey) else { return nil }
        return try? JSONDecoder().decode(SessionRef.self, from: data)
    }

    public func saveActiveRef(_ ref: SessionRef?) {
        if let ref, let data = try? JSONEncoder().encode(ref) {
            defaults.set(data, forKey: activeRefKey)
        } else {
            defaults.removeObject(forKey: activeRefKey)
        }
    }

    public func loadCollapsedServers() -> Set<UUID> {
        Set((defaults.stringArray(forKey: collapsedServersKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    public func saveCollapsedServers(_ ids: Set<UUID>) {
        defaults.set(ids.map(\.uuidString).sorted(), forKey: collapsedServersKey)
    }

    public var isMigrated: Bool { defaults.bool(forKey: migratedKey) }
    public func markMigrated() { defaults.set(true, forKey: migratedKey) }
}
