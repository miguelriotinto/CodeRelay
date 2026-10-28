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
    /// When set, `start()` runs `HubMigration` once against this legacy key.
    private let lastServerIdKey: String?
    private let defaults: UserDefaults

    private(set) var bookmarks: [ConnectionConfig] = []
    private var slots: [UUID: Slot] = [:]
    private var slotSubscriptions: [UUID: AnyCancellable] = [:]
    private var cachedSessions: [UUID: [SessionInfo]] = [:]
    private var missingToken: Set<UUID> = []
    private var collapsedServers: Set<UUID> = []
    private var started = false
    /// Deep links that arrived before `start()` finished wait here.
    private var startGate: [CheckedContinuation<Void, Never>] = []
    /// serverId → sessionId chosen while that server was not live; applied by
    /// `slotDidChange` once a live list proves the session still exists (D4).
    private(set) var pendingSelection: [UUID: UUID] = [:]
    /// Forwarded to the previous coordinator's `detachActive` bound (§7.5).
    public var detachBudget: Duration = .seconds(3)

    // Test hooks
    public var onTestEvent: ((String) -> Void)?
    public private(set) var recordedSleeps: [Duration] = []
    public func recordedSleepsReset() { recordedSleeps.removeAll() }

    public init(bookmarks: SavedConnectionStore,
                tokens: TokenProviding,
                stateStore: HubStateStore,
                keyPrefix: String,
                lastServerIdKey: String? = nil,
                defaults: UserDefaults = .standard,
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
        self.lastServerIdKey = lastServerIdKey
        self.defaults = defaults
        self.collapsedServers = stateStore.loadCollapsedServers()
    }

    // MARK: - Lifecycle (spec §7.3)

    /// Builds a coordinator per enabled bookmark, staggered, then publishes.
    public func start() async {
        guard !started else { return }
        started = true
        if let lastServerIdKey {
            HubMigration.run(defaults: defaults, keyPrefix: keyPrefix, deviceId: DeviceIdentifier().currentID,
                             bookmarks: bookmarkStore, lastServerIdKey: lastServerIdKey, stateStore: stateStore)
        }
        bookmarks = bookmarkStore.loadAll()
        // F3 across servers (§9): restore the last active ref as a cached
        // selection; `applyPendingSelection` attaches it once that server's
        // live list proves the session still exists.
        if let saved = stateStore.loadActiveRef(),
           bookmarks.contains(where: { $0.id == saved.serverId && $0.enabled }) {
            activeRef = saved
            pendingSelection[saved.serverId] = saved.sessionId
        } else {
            stateStore.saveActiveRef(nil)
        }
        var index = 0
        for config in bookmarks where config.enabled {
            let delay = stagger * index
            recordedSleeps.append(delay)
            await sleep(delay)
            await buildSlot(for: config)
            index += 1
        }
        publish()
        for c in startGate { c.resume() }
        startGate.removeAll()
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
        applyPendingSelection(for: serverId)
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

    // MARK: - Selection (spec §7.5)

    /// Every row the sidebar shows, in sidebar order (live and cached sections),
    /// for keyboard next/previous across section boundaries.
    public var orderedRefs: [SessionRef] {
        sections.flatMap { section in
            section.sessions.map { SessionRef(serverId: section.id, sessionId: $0.id) }
        }
    }

    /// Makes `ref` the one attached session. Same server → the coordinator's own
    /// `switchToSession` (which detaches the previous session itself). Different
    /// server → `detachActive()` on the previous coordinator, bounded, THEN the
    /// attach. Offline server → remember the choice and trigger its recovery.
    public func select(_ ref: SessionRef) async {
        guard let section = sections.first(where: { $0.id == ref.serverId }) else { return }
        if activeRef == ref { return }
        let previous = activeRef
        activeRef = ref
        stateStore.saveActiveRef(ref)
        onTestEvent?("select:\(ref.serverId.uuidString.prefix(4))")

        if let previous, previous.serverId != ref.serverId, let from = slots[previous.serverId] {
            await detachBounded(from)
        }
        guard let to = slots[ref.serverId] else { return }
        if section.status.isLive {
            pendingSelection[ref.serverId] = nil
            await to.switchToSession(id: ref.sessionId)
        } else {
            pendingSelection[ref.serverId] = ref.sessionId
            to.triggerUserRecovery()
        }
        publish()
    }

    /// New session on `serverId`; detaches on any other server first (§7.5).
    public func createSession(on serverId: UUID) async {
        guard let to = slots[serverId] else { return }
        if let previous = activeRef, previous.serverId != serverId, let from = slots[previous.serverId] {
            await detachBounded(from)
        }
        await to.createNewSession()
        if let id = to.activeSessionId {
            activeRef = SessionRef(serverId: serverId, sessionId: id)
            stateStore.saveActiveRef(activeRef)
        }
        publish()
    }

    public func selectNext() async { await step(by: 1) }
    public func selectPrevious() async { await step(by: -1) }

    private func step(by delta: Int) async {
        let refs = orderedRefs
        guard refs.count > 1, let current = activeRef, let index = refs.firstIndex(of: current) else { return }
        let next = (index + delta + refs.count) % refs.count
        await select(refs[next])
    }

    /// Deletes a bookmark: detach if it is active, tear down, forget its token
    /// and its ownership namespace (§7.3, §11).
    public func removeServer(_ serverId: UUID) async {
        if activeRef?.serverId == serverId, let slot = slots[serverId] {
            activeRef = nil
            stateStore.saveActiveRef(nil)
            await detachBounded(slot)
        }
        tearDownSlot(serverId)
        bookmarkStore.delete(id: serverId)
        (tokens as? TokenDeleting)?.deleteTokenIgnoringErrors(for: serverId)
        bookmarks = bookmarkStore.loadAll()
        cachedSessions[serverId] = nil
        pendingSelection[serverId] = nil
        publish()
    }

    /// Awaits `slot.detachActive()` for at most `detachBudget`. A task group
    /// cannot express this: it waits for every child at scope exit, so a stuck
    /// detach would hold the switch hostage. The straggler is left to finish
    /// on its own; the coordinator's own budget bounds it.
    private func detachBounded(_ slot: Slot) async {
        await BoundedWait.run(budget: detachBudget) { await slot.detachActive() }
    }

    /// Called from `slotDidChange` after `publish()`: apply or drop a pending
    /// selection once the server is live again.
    private func applyPendingSelection(for serverId: UUID) {
        guard let wanted = pendingSelection[serverId],
              let slot = slots[serverId],
              let section = sections.first(where: { $0.id == serverId }), section.status.isLive else { return }
        pendingSelection[serverId] = nil
        if slot.activeSessions.contains(where: { $0.id == wanted }) {
            Task { await slot.switchToSession(id: wanted); self.publish() }
        } else {
            if activeRef == SessionRef(serverId: serverId, sessionId: wanted) {
                activeRef = nil
                stateStore.saveActiveRef(nil)
            }
            notice = "That session has ended"
            publish()
        }
    }

    // MARK: - Fan-out (spec §7.3, D10)

    /// Foreground / wake / network-restored: every coordinator gets the event,
    /// staggered so N servers do not reconnect in lockstep. Offline ones are
    /// included — this is how they come back.
    public func handleForegroundTransition(userInitiated: Bool) async {
        var index = 0
        for config in bookmarks where config.enabled {
            guard let slot = slots[config.id] else { continue }
            let delay = stagger * index
            recordedSleeps.append(delay)
            await sleep(delay)
            await slot.handleForegroundTransition(userInitiated: userInitiated)
            index += 1
        }
        publish()
    }

    /// One server (the section's Retry) or all of them (menu bar / shortcut).
    public func triggerUserRecovery(serverId: UUID? = nil) {
        if let serverId { slots[serverId]?.triggerUserRecovery(); return }
        for (_, slot) in slots { slot.triggerUserRecovery() }
    }

    /// Push registration is per relay: each coordinator decides and sends for
    /// its own socket (spec §10).
    public func syncPushRegistration(pushEnabled: Bool, notifyOnFinished: Bool) async {
        for (_, slot) in slots {
            await slot.syncPushRegistration(pushEnabled: pushEnabled, notifyOnFinished: notifyOnFinished)
        }
    }

    // MARK: - Deep links (spec §10)

    public enum DeepLinkOutcome: Equatable {
        case selected(SessionRef)
        case enabledAndSelected(SessionRef)
        case attachingRemote(serverId: UUID)
        case notFound(serverName: String?)
    }

    /// Routing precedence: instance id → unique session across live sections →
    /// single enabled server's cross-device attach → not found. A link that
    /// arrives before `start()` finished waits for it.
    public func handleDeepLink(_ link: SessionDeepLink) async -> DeepLinkOutcome {
        if !started || (slots.isEmpty && bookmarks.contains(where: \.enabled)) {
            await withCheckedContinuation { startGate.append($0) }
        }
        // 1. The relay named itself.
        if let instanceId = link.serverInstanceId,
           let config = bookmarks.first(where: { $0.instanceId == instanceId }) {
            let ref = SessionRef(serverId: config.id, sessionId: link.sessionId)
            if !config.enabled {
                if setEnabled(config.id, true) {
                    notice = "Enabled \(config.displayName ?? config.name) to open this session"
                    activeRef = ref
                    stateStore.saveActiveRef(ref)
                    pendingSelection[config.id] = link.sessionId
                    publish()
                    return .enabledAndSelected(ref)
                }
                return .notFound(serverName: config.displayName ?? config.name)
            }
            await select(ref)
            return .selected(ref)
        }
        // 2. Exactly one live section lists the session.
        let hits = sections.filter { $0.status.isLive && $0.sessions.contains(where: { $0.id == link.sessionId }) }
        if hits.count == 1 {
            let ref = SessionRef(serverId: hits[0].id, sessionId: link.sessionId)
            await select(ref)
            return .selected(ref)
        }
        // 3. One enabled server: the pre-hub cross-device attach.
        let enabled = bookmarks.filter(\.enabled)
        if enabled.count == 1, let slot = slots[enabled[0].id] {
            if let previous = activeRef, previous.serverId != enabled[0].id, let from = slots[previous.serverId] {
                await detachBounded(from)
            }
            await slot.attachRemoteSession(id: link.sessionId, serverName: nil)
            if let id = slot.activeSessionId {
                activeRef = SessionRef(serverId: enabled[0].id, sessionId: id)
                stateStore.saveActiveRef(activeRef)
            }
            publish()
            return .attachingRemote(serverId: enabled[0].id)
        }
        // 4. Nothing to route to.
        notice = "Session not found on any enabled server"
        return .notFound(serverName: nil)
    }

    // MARK: - Collapse (per device)

    public func setCollapsed(_ serverId: UUID, _ collapsed: Bool) {
        if collapsed { collapsedServers.insert(serverId) } else { collapsedServers.remove(serverId) }
        stateStore.saveCollapsedServers(collapsedServers)
        publish()
    }
}
