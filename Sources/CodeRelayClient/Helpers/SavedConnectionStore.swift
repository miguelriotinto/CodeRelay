import Foundation
import os.log

private let connectionStoreLog = Logger(
    subsystem: "com.coderelay.client", category: "SavedConnectionStore")

/// Persists a user's list of server connection bookmarks in UserDefaults.
///
/// Apps construct one of these at launch with a platform-scoped key:
///
///     static let store = SavedConnectionStore(key: "com.clauderelay.ios.savedConnections")
///     static let store = SavedConnectionStore(key: "com.clauderelay.mac.savedConnections")
///
/// Each platform gets its own key so bookmarks don't clobber each other if
/// UserDefaults ever syncs across devices.
///
/// ## Legacy-key migration
///
/// Pass `legacyKeys` to read from older storage locations when the current
/// key is empty. The first legacy key with data is copied into the current
/// key on next `loadAll()`. Legacy keys are **not** deleted — a user who
/// downgrades to a prior build still sees their bookmarks.
public struct SavedConnectionStore {

    public let key: String
    public let legacyKeys: [String]
    private let defaults: UserDefaults

    public init(
        key: String,
        legacyKeys: [String] = [],
        defaults: UserDefaults = .standard
    ) {
        self.key = key
        self.legacyKeys = legacyKeys
        self.defaults = defaults
    }

    /// Loads all saved connections. Transparently migrates from a legacy key
    /// on first call if the current key is empty.
    public func loadAll() -> [ConnectionConfig] {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ConnectionConfig].self, from: data) {
            return decoded
        }

        for legacyKey in legacyKeys {
            guard let data = defaults.data(forKey: legacyKey),
                  let decoded = try? JSONDecoder().decode([ConnectionConfig].self, from: data)
            else { continue }
            // Copy forward into the new key but leave the legacy key untouched
            // so downgrades still work within a TestFlight cycle.
            saveAll(decoded)
            return decoded
        }

        return []
    }

    public func saveAll(_ connections: [ConnectionConfig]) {
        do {
            let data = try JSONEncoder().encode(connections)
            defaults.set(data, forKey: key)
        } catch {
            connectionStoreLog.error(
                "Failed to encode \(connections.count, privacy: .public) saved connection(s) to UserDefaults key '\(self.key, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adds or replaces (by `id`) a connection; returns the updated list.
    @discardableResult
    public func add(_ connection: ConnectionConfig) -> [ConnectionConfig] {
        var all = loadAll()
        if let index = all.firstIndex(where: { $0.id == connection.id }) {
            all[index] = connection
        } else {
            all.append(connection)
        }
        saveAll(all)
        return all
    }

    /// Removes a connection by `id`; returns the updated list.
    @discardableResult
    public func delete(id: UUID) -> [ConnectionConfig] {
        var all = loadAll()
        all.removeAll { $0.id == id }
        saveAll(all)
        return all
    }
}
