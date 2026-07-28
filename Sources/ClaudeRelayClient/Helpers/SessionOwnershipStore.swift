import Foundation

/// UserDefaults-backed persistence for three coordinator dictionaries:
/// `names` (user/server-renamed session names), `owned` (session ids this
/// device created or attached), `agents` (last-seen agent per session).
///
/// Why: the coordinator previously maintained three `save*` helpers that each
/// re-encoded and wrote to `UserDefaults` on every change, even when nothing
/// had actually changed (see C-21). This store:
///
/// - Collapses the three persistence flows behind one API.
/// - Diff-checks before writing — `defaults.set` is called only when the
///   value actually changed since the last persisted snapshot.
/// - Centralizes the key construction (`"\(keyPrefix).name"` /
///   `"\(keyPrefix).ownedSessions.\(deviceId)"` / `"\(keyPrefix).agentSessions"`)
///   so individual helpers can't drift out of sync.
///
/// Not an `ObservableObject` — the coordinator keeps its own `@Published`
/// mirrors so SwiftUI can bind to them directly. The store is called on the
/// main actor because `UserDefaults` is not `Sendable`-safe across isolation.
@MainActor
public final class SessionOwnershipStore {

    // MARK: - Keys

    /// Key for the UUID→name dictionary (plain per-app; device-independent).
    public let namesKey: String
    /// Key for the UUID→agentId dictionary (plain per-app; device-independent).
    public let agentsKey: String
    /// Key for the last active/focused session id (per-device: which tab this
    /// device had selected — must not stomp another device's focus). F3.
    public let activeSessionKey: String
    /// Key for the set of collapsed workspace-group ids (per-device sidebar
    /// layout). F3.
    public let collapsedGroupsKey: String

    // MARK: - Dependencies

    private let defaults: UserDefaults

    /// JSON encoder for UUID-keyed dictionaries, which require String-keyed
    /// JSON (Foundation's default JSONEncoder refuses non-string keys).
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Cached last-persisted snapshots (for diff-check)

    private var persistedNames: [UUID: String] = [:]
    private var persistedAgents: [UUID: String] = [:]
    private var persistedActiveSession: UUID?
    private var persistedCollapsedGroups: Set<String> = []
    private var loaded = false

    // MARK: - Init

    public init(keyPrefix: String,
                deviceId: String,
                defaults: UserDefaults = .standard) {
        self.namesKey = "\(keyPrefix).sessionNames"
        self.agentsKey = "\(keyPrefix).agentSessions"
        // Per-device layout state (F3): scoped by deviceId so one device's
        // focus/collapse never overwrites another's.
        self.activeSessionKey = "\(keyPrefix).activeSession.\(deviceId)"
        self.collapsedGroupsKey = "\(keyPrefix).collapsedGroups.\(deviceId)"
        self.defaults = defaults
        loadSnapshots()
    }

    // MARK: - Loading

    /// Read the current on-disk state into the persisted snapshots. Called
    /// automatically at init; public so callers can force a reload when a
    /// test mutates defaults externally.
    public func loadSnapshots() {
        persistedNames = loadNames()
        persistedAgents = loadAgents()
        persistedActiveSession = loadActiveSession()
        persistedCollapsedGroups = loadCollapsedGroups()
        loaded = true
    }

    public func loadNames() -> [UUID: String] {
        guard let data = defaults.data(forKey: namesKey),
              let dict = try? decoder.decode([String: String].self, from: data) else {
            return [:]
        }
        return dict.reduce(into: [UUID: String]()) { result, pair in
            if let uuid = UUID(uuidString: pair.key) {
                result[uuid] = pair.value
            }
        }
    }

    public func loadAgents() -> [UUID: String] {
        guard let data = defaults.data(forKey: agentsKey),
              let dict = try? decoder.decode([String: String].self, from: data) else {
            return [:]
        }
        return dict.reduce(into: [UUID: String]()) { result, pair in
            if let uuid = UUID(uuidString: pair.key) {
                result[uuid] = pair.value
            }
        }
    }

    /// Load the persisted active/focused session id for this device (F3).
    public func loadActiveSession() -> UUID? {
        guard let str = defaults.string(forKey: activeSessionKey) else { return nil }
        return UUID(uuidString: str)
    }

    /// Load the persisted set of collapsed workspace-group ids (F3).
    public func loadCollapsedGroups() -> Set<String> {
        Set(defaults.stringArray(forKey: collapsedGroupsKey) ?? [])
    }

    // MARK: - Saving (diff-checked)

    /// Persist the names dictionary. No-op when the value matches what was
    /// last persisted (closes C-21: `fetchSessions` used to rewrite this
    /// unconditionally on every refresh).
    @discardableResult
    public func saveNames(_ names: [UUID: String]) -> Bool {
        guard names != persistedNames else { return false }
        let encoded = names.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
        if let data = try? encoder.encode(encoded) {
            defaults.set(data, forKey: namesKey)
            persistedNames = names
            return true
        }
        return false
    }

    @discardableResult
    public func saveAgents(_ agents: [UUID: String]) -> Bool {
        guard agents != persistedAgents else { return false }
        let encoded = agents.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
        if let data = try? encoder.encode(encoded) {
            defaults.set(data, forKey: agentsKey)
            persistedAgents = agents
            return true
        }
        return false
    }

    /// Persist the active/focused session id for this device (F3). Passing nil
    /// clears it. Diff-checked like the others.
    @discardableResult
    public func saveActiveSession(_ id: UUID?) -> Bool {
        guard id != persistedActiveSession else { return false }
        if let id {
            defaults.set(id.uuidString, forKey: activeSessionKey)
        } else {
            defaults.removeObject(forKey: activeSessionKey)
        }
        persistedActiveSession = id
        return true
    }

    /// Persist the set of collapsed workspace-group ids for this device (F3).
    @discardableResult
    public func saveCollapsedGroups(_ groups: Set<String>) -> Bool {
        guard groups != persistedCollapsedGroups else { return false }
        defaults.set(Array(groups), forKey: collapsedGroupsKey)
        persistedCollapsedGroups = groups
        return true
    }

    // MARK: - Stale pruning

    /// Prune persisted per-session UI state (names, agents) and the F3 active
    /// tab down to `serverIds` — the sessions the server still lists under this
    /// token. Ownership itself is NOT persisted anymore (the server is
    /// authoritative), so this only keeps the auxiliary local maps from growing
    /// unbounded. Diff-checked writes mean no UserDefaults churn when nothing
    /// was stale.
    public func pruneToServerSessions(
        serverIds: Set<UUID>,
        names: inout [UUID: String],
        agents: inout [UUID: String]
    ) {
        let staleNames = Set(names.keys).subtracting(serverIds)
        let staleAgents = Set(agents.keys).subtracting(serverIds)

        for id in staleNames { names.removeValue(forKey: id) }
        for id in staleAgents { agents.removeValue(forKey: id) }

        if !staleNames.isEmpty { saveNames(names) }
        if !staleAgents.isEmpty { saveAgents(agents) }

        // F3: a persisted active session the server no longer lists must not be
        // restored as a dead tab — clear it.
        if let active = persistedActiveSession, !serverIds.contains(active) {
            saveActiveSession(nil)
        }
    }

    // MARK: - Test Hooks

    public var _testOnly_persistedNames: [UUID: String] { persistedNames }
    public var _testOnly_persistedAgents: [UUID: String] { persistedAgents }
    public var _testOnly_persistedActiveSession: UUID? { persistedActiveSession }
    public var _testOnly_persistedCollapsedGroups: Set<String> { persistedCollapsedGroups }
}
