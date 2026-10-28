import Foundation
import Combine
import CodeRelayKit
import os.log

private let hubLog = Logger(subsystem: "com.coderelay.client", category: "hub")

/// One workspace across several relays (multi-server spec §7).
///
/// Owns one per-server coordinator (`Slot`) for every ENABLED bookmark, merges
/// their published state into `sections`, and holds the single global active
/// session. It never talks to the network, runs recovery, or holds terminal
/// views — those stay in the coordinators, unchanged.
@MainActor
public final class ServerHub<Slot: ServerSlotCoordinating>: ObservableObject {

    public typealias Factory = @MainActor (ConnectionConfig, String) -> Slot

    // MARK: - Published state

    @Published public private(set) var sections: [ServerSection] = []
    @Published public private(set) var activeRef: SessionRef?
    @Published public private(set) var aggregate = HubAggregate()
    /// User-facing notices the hub produces (deep-link enable, cap refusal…).
    @Published public var notice: String?
    /// UI-only: the server management sheet/window is being shown.
    @Published public var isShowingServerList = false

    public var activeCoordinator: Slot? { activeRef.flatMap { slots[$0.serverId] } }
    public var enabledCount: Int { bookmarks.filter(\.enabled).count }

    // MARK: - Dependencies

    private let bookmarkStore: SavedConnectionStore
    private let tokens: TokenProviding
    private let stateStore: HubStateStore
    private let keyPrefix: String
    private let factory: Factory
    private let maxEnabled: Int
    private let stagger: Duration
    private let sleep: @MainActor (Duration) async -> Void

    private(set) var bookmarks: [ConnectionConfig] = []
    private var slots: [UUID: Slot] = [:]
    private var slotSubscriptions: [UUID: AnyCancellable] = [:]
    private var cachedSessions: [UUID: [SessionInfo]] = [:]
    private var missingToken: Set<UUID> = []
    private var collapsedServers: Set<UUID> = []
    private var started = false

    // Test hooks
    public var onTestEvent: ((String) -> Void)?
    public private(set) var recordedSleeps: [Duration] = []
    public func recordedSleepsReset() { recordedSleeps.removeAll() }

    public init(bookmarks: SavedConnectionStore,
                tokens: TokenProviding,
                stateStore: HubStateStore,
                keyPrefix: String,
                factory: @escaping Factory,
                maxEnabled: Int = 8,
                stagger: Duration = .milliseconds(150),
                sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.bookmarkStore = bookmarks
        self.tokens = tokens
        self.stateStore = stateStore
        self.keyPrefix = keyPrefix
        self.factory = factory
        self.maxEnabled = maxEnabled
        self.stagger = stagger
        self.sleep = sleep
        self.collapsedServers = stateStore.loadCollapsedServers()
    }

    // MARK: - Lifecycle (spec §7.3)

    /// Builds a coordinator per enabled bookmark, staggered, then publishes.
    public func start() async {
        guard !started else { return }
        started = true
        bookmarks = bookmarkStore.loadAll()
        var index = 0
        for config in bookmarks where config.enabled {
            let delay = stagger * index
            recordedSleeps.append(delay)
            await sleep(delay)
            await buildSlot(for: config)
            index += 1
        }
        publish()
    }

    public func stop() {
        for (_, slot) in slots { slot.tearDown() }
        slots.removeAll()
        slotSubscriptions.removeAll()
        started = false
        publish()
    }

    /// Re-reads the bookmark store (after add/edit/delete on the management
    /// window) and reconciles coordinators: new enabled bookmarks get one,
    /// removed ones are torn down, edited ones (host/port/TLS) are rebuilt.
    public func reloadBookmarks() {
        let fresh = bookmarkStore.loadAll()
        let freshById = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        for id in Array(slots.keys) {
            guard let now = freshById[id], now.enabled else { tearDownSlot(id); continue }
            if let old = bookmarks.first(where: { $0.id == id }),
               old.host != now.host || old.port != now.port || old.useTLS != now.useTLS {
                tearDownSlot(id)
            }
        }
        bookmarks = fresh
        publish()
        Task { [weak self] in
            guard let self else { return }
            for config in fresh where config.enabled && self.slots[config.id] == nil {
                await self.buildSlot(for: config)
            }
            self.publish()
        }
    }

    /// Flips a bookmark's `enabled` flag and persists it. Returns false when the
    /// cap refuses (D12) — the caller shows `notice`.
    @discardableResult
    public func setEnabled(_ serverId: UUID, _ enabled: Bool) -> Bool {
        guard var config = bookmarks.first(where: { $0.id == serverId }) else { return false }
        if enabled, config.enabled == false, enabledCount >= maxEnabled {
            notice = "Up to \(maxEnabled) servers can be enabled at once. Disable one first."
            return false
        }
        config.enabled = enabled
        bookmarkStore.add(config)
        bookmarks = bookmarkStore.loadAll()
        if enabled {
            Task { [weak self] in await self?.buildSlot(for: config); self?.publish() }
        } else {
            tearDownSlot(serverId)
        }
        publish()
        return true
    }

    public func slot(for serverId: UUID) -> Slot? { slots[serverId] }

    // MARK: - Slots

    private func buildSlot(for config: ConnectionConfig) async {
        guard slots[config.id] == nil else { return }
        let token: String?
        do { token = try tokens.loadToken(for: config.id) } catch { token = nil }
        guard let token else {
            missingToken.insert(config.id)
            hubLog.error("No token for bookmark \(config.id.uuidString, privacy: .public); section marked authFailed")
            publish()
            return
        }
        missingToken.remove(config.id)
        let slot = factory(config, token)
        slots[config.id] = slot
        slotSubscriptions[config.id] = slot.objectWillChange.sink { [weak self] _ in
            // Published values change AFTER willChange; read them on the next turn.
            DispatchQueue.main.async { self?.slotDidChange(config.id) }
        }
        onTestEvent?("start:\(config.name)")
        await slot.start()
        publish()
    }

    private func tearDownSlot(_ serverId: UUID) {
        if activeRef?.serverId == serverId {
            let slot = slots[serverId]
            activeRef = nil
            stateStore.saveActiveRef(nil)
            Task { await slot?.detachActive() }
        }
        slots[serverId]?.tearDown()
        slots[serverId] = nil
        slotSubscriptions[serverId] = nil
    }

    private func slotDidChange(_ serverId: UUID) {
        guard let slot = slots[serverId] else { return }
        // Learn the relay's identity once and persist it on the bookmark (§5.2).
        if let identity = slot.serverIdentity,
           var config = bookmarks.first(where: { $0.id == serverId }),
           config.instanceId != identity.id || config.displayName != (identity.name.isEmpty ? nil : identity.name) {
            config.instanceId = identity.id
            config.displayName = identity.name.isEmpty ? nil : identity.name
            bookmarkStore.add(config)
            bookmarks = bookmarkStore.loadAll()
        }
        publish()
    }

    // MARK: - Publishing (spec §7.2, §7.6)

    func publish() {
        var agg = HubAggregate()
        agg.totalServers = bookmarks.count
        agg.enabledServers = enabledCount
        var built: [ServerSection] = bookmarks.map { config in
            let slot = slots[config.id]
            var status = ServerSectionStatus.derive(
                enabled: config.enabled,
                connection: slot?.connectionState ?? .disconnected,
                isRecovering: slot?.isRecovering ?? false,
                isPerformingHandshake: slot?.isPerformingHandshake ?? false,
                authRejected: slot?.isAuthRejected ?? false,
                recoveryFailed: slot?.recoveryFailed ?? false)
            if config.enabled, missingToken.contains(config.id) {
                status = .authFailed("No token stored for this server")
            }
            let live = slot?.activeSessions ?? []
            if status.isLive {
                cachedSessions[config.id] = live
            }
            let shown = status.isLive ? live : (cachedSessions[config.id] ?? [])
            let rollups = slot?.activityCoordinator.rollups(for: shown) ?? []
            let awaiting = status.isLive ? (slot?.activityCoordinator.sessionsAwaitingInput.count ?? 0) : 0
            if status.isLive {
                agg.liveServers += 1
                agg.sessionsAwaitingInput += awaiting
                agg.workingSessions += shown.filter { $0.agentState == .working }.count
            }
            return ServerSection(config: config, status: status, sessions: shown,
                                 isCached: !status.isLive, rollups: rollups,
                                 awaitingInput: awaiting, isCollapsed: collapsedServers.contains(config.id))
        }
        var seen: [UUID: Int] = [:]
        for s in built { if let id = s.config.instanceId { seen[id, default: 0] += 1 } }
        for i in built.indices {
            if let id = built[i].config.instanceId { built[i].isDuplicateInstance = seen[id, default: 0] > 1 }
        }
        sections = built
        aggregate = agg
    }

    // MARK: - Collapse (per device)

    public func setCollapsed(_ serverId: UUID, _ collapsed: Bool) {
        if collapsed { collapsedServers.insert(serverId) } else { collapsedServers.remove(serverId) }
        stateStore.saveCollapsedServers(collapsedServers)
        publish()
    }
}
