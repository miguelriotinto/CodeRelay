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
    @Published public internal(set) var activeRef: SessionRef?
    @Published public private(set) var aggregate = HubAggregate()
    /// User-facing notices the hub produces (deep-link enable, cap refusal,
    /// sessions that ended while the user was away…).
    @Published public var notice: String?
    /// The one aggregated "Session Moved" alert across every server (session
    /// takeover spec §2, §5). Bound by the workspace root — never by a
    /// per-coordinator view, which is re-keyed when focus moves.
    @Published public var takenAlert: SessionLossAlert?
    /// UI-only: the server management sheet/window is being shown.
    @Published public var isShowingServerList = false

    public var activeCoordinator: Slot? { activeRef.flatMap { slots[$0.serverId] } }
    /// The coordinator the single-server surfaces (QR scan, Attach, the
    /// Reconnecting sheet, error alerts) should follow when nothing is selected:
    /// the active one, else the only enabled one, else the first live one. A
    /// one-server user keeps every pre-hub surface this way (G8).
    public var focusCoordinator: Slot? { focusServerId.flatMap { slots[$0] } }
    public var focusServerId: UUID? {
        if let active = activeRef, slots[active.serverId] != nil { return active.serverId }
        let enabled = bookmarks.filter(\.enabled)
        if enabled.count == 1, slots[enabled[0].id] != nil { return enabled[0].id }
        return sections.first(where: { $0.status.isLive && slots[$0.id] != nil })?.id
    }
    public var enabledCount: Int { bookmarks.filter(\.enabled).count }

    // MARK: - Dependencies

    let bookmarkStore: SavedConnectionStore
    let tokens: TokenProviding
    let stateStore: HubStateStore
    private let keyPrefix: String
    private let factory: Factory
    private let maxEnabled: Int
    private let stagger: Duration
    private let sleep: @MainActor (Duration) async -> Void
    /// When set, `start()` runs `HubMigration` once against this legacy key.
    private let lastServerIdKey: String?
    private let defaults: UserDefaults

    var bookmarks: [ConnectionConfig] = []
    var slots: [UUID: Slot] = [:]
    private var slotSubscriptions: [UUID: AnyCancellable] = [:]
    var cachedSessions: [UUID: [SessionInfo]] = [:]
    var missingToken: Set<UUID> = []
    private var collapsedServers: Set<UUID> = []
    var started = false
    /// `start()` has returned (every enabled slot was built or skipped). Deep
    /// links that arrive in between wait on `startGate`.
    var startCompleted = false
    var startGate: [CheckedContinuation<Void, Never>] = []
    /// The one selection waiting for its server to come live (D4, F3 restore,
    /// deep-link enable). Always equal to `activeRef` while set; every new
    /// selection replaces it, so an abandoned choice can never attach later.
    var pendingRef: SessionRef?
    /// Bumped by every selection path; a path that resumes after an `await`
    /// and finds another generation stops without touching anything (D9).
    var selectionGeneration: UInt64 = 0
    /// Selections between their first and last `await`; `reconcileSelection`
    /// stays out of the way while one is in flight.
    var selectionsInFlight = 0
    /// The last push settings the app synced; slots built later get the same.
    private var pushSettings: (enabled: Bool, notify: Bool)?
    /// Forwarded to the previous coordinator's `detachActive` bound (§7.5).
    public var detachBudget: Duration = .seconds(3)
    /// Cap on the session-loss hold around `start()` and a foreground fan-out:
    /// one dead server must not hold everyone's notice (spec §2, §6).
    public var fanOutBudget: Duration = .seconds(10)
    let lossCollector: SessionLossCollector

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
                sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                now: @escaping () -> Date = Date.init,
                lossSleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
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
        self.lossCollector = SessionLossCollector(now: now, sleep: lossSleep)
        lossCollector.onFlush = { [weak self] taken, ended in self?.presentLosses(taken: taken, ended: ended) }
    }

    // MARK: - Lifecycle (spec §7.3)

    /// Builds a coordinator per enabled bookmark — concurrently, each after its
    /// own stagger, so one unreachable relay's handshake never delays the next
    /// (D10) — then publishes. Returns once every build has finished or been
    /// skipped; `stop()` or cancellation makes the remaining builds no-ops.
    public func start() async {
        guard !started else { return }
        started = true
        startCompleted = false
        defer { startCompleted = true; drainStartGate() }
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
            pendingRef = saved
        } else {
            stateStore.saveActiveRef(nil)
        }
        let enabled = bookmarks.filter(\.enabled)
        let hold = openLossHold(count: enabled.count)
        await withTaskGroup(of: Void.self) { group in
            for (index, config) in enabled.enumerated() {
                let delay = stagger * index
                recordedSleeps.append(delay)
                group.addTask { @MainActor [weak self] in
                    defer { hold.latch.arrive() }
                    guard let self else { return }
                    await self.sleep(delay)
                    guard self.started, !Task.isCancelled else { return }
                    await self.buildSlot(for: config, reason: .launch)
                    await self.slots[config.id]?.awaitPassFinished()
                }
            }
        }
        await hold.closed.value
        publish()
    }

    private func drainStartGate() {
        let waiting = startGate
        startGate.removeAll()
        for c in waiting { c.resume() }
    }

    public func stop() {
        for (_, slot) in slots { slot.tearDown() }
        slots.removeAll()
        slotSubscriptions.removeAll()
        started = false
        pendingRef = nil
        publish()
    }

    /// Re-reads the bookmark store (after add/edit/delete on the management
    /// window) and reconciles coordinators: new enabled bookmarks get one,
    /// removed ones are torn down, edited ones (host/port/TLS) are rebuilt.
    public func reloadBookmarks() {
        var fresh = bookmarkStore.loadAll()
        // Add and pair save bookmarks enabled; the cap (D12) is enforced here so
        // a ninth server is stored disabled, with a notice, instead of dialled.
        var enabledNow = fresh.filter(\.enabled).count
        if enabledNow > maxEnabled {
            for i in fresh.indices.reversed() where fresh[i].enabled && slots[fresh[i].id] == nil && enabledNow > maxEnabled {
                fresh[i].enabled = false
                enabledNow -= 1
                notice = "Up to \(maxEnabled) servers can be enabled at once. \(fresh[i].name) was added disabled."
            }
            bookmarkStore.saveAll(fresh)
        }
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
                await self.buildSlot(for: config, reason: .enable)
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
            Task { [weak self] in await self?.buildSlot(for: config, reason: .enable); self?.publish() }
        } else {
            // Spec §10: unregister push on that relay first; the cached list is kept.
            tearDownSlot(serverId, unregisterPush: true)
        }
        publish()
        return true
    }

    public func slot(for serverId: UUID) -> Slot? { slots[serverId] }

    /// Tears the bookmark's coordinator down and builds a fresh one — after an
    /// edit that may have changed the token (the hub cannot see the keychain).
    public func rebuildSlot(_ serverId: UUID) {
        tearDownSlot(serverId)
        guard let config = bookmarks.first(where: { $0.id == serverId }), config.enabled else { publish(); return }
        Task { [weak self] in await self?.buildSlot(for: config, reason: .enable); self?.publish() }
    }

    // MARK: - Slots

    private func isWanted(_ serverId: UUID) -> Bool {
        started && bookmarks.first(where: { $0.id == serverId })?.enabled == true
    }

    /// `reason` is `.launch` from `start()` (announces losses since the last
    /// run) and `.enable` for every later build — enable, add/pair, edit —
    /// which resets the baseline silently (spec §3b).
    private func buildSlot(for config: ConnectionConfig, reason: SessionHandshake.Reason) async {
        // Re-read the flag: setEnabled(true) then setEnabled(false) can both run
        // before this task does, and `stop()` may have closed the window.
        guard slots[config.id] == nil, isWanted(config.id) else { return }
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
        slot.onSessionsLost = { [weak self, weak slot] report in
            guard let self, let slot, self.slots[config.id] === slot else { return }
            self.collectLosses(report, serverId: config.id)
        }
        slotSubscriptions[config.id] = slot.objectWillChange.sink { [weak self] _ in
            // Published values change AFTER willChange; read them on the next turn.
            DispatchQueue.main.async { self?.slotDidChange(config.id) }
        }
        onTestEvent?("start:\(config.name)")
        await slot.start(reason: reason)
        // The world may have moved while the handshake ran.
        guard isWanted(config.id), slots[config.id] === slot else {
            if slots[config.id] === slot { slots[config.id] = nil; slotSubscriptions[config.id] = nil }
            slot.tearDown()
            return
        }
        if let push = pushSettings {
            await slot.syncPushRegistration(pushEnabled: push.enabled, notifyOnFinished: push.notify)
        }
        publish()
    }

    /// Removes the slot from the hub at once (nothing publishes it any more),
    /// then detaches / unregisters within the budget and tears it down.
    private func tearDownSlot(_ serverId: UUID, unregisterPush: Bool = false) {
        guard let slot = detachFromHub(serverId) else { return }
        let wasActive = slot.activeSessionId != nil
        Task { await self.retire(slot, wasActive: wasActive, unregisterPush: unregisterPush) }
    }

    /// Forgets the slot and clears a selection that pointed at it. Returns the
    /// slot so the caller can retire it (sync callers in a Task, async inline).
    func detachFromHub(_ serverId: UUID) -> Slot? {
        guard let slot = slots[serverId] else { return nil }
        slots[serverId] = nil
        slotSubscriptions[serverId] = nil
        if activeRef?.serverId == serverId || pendingRef?.serverId == serverId {
            activeRef = nil
            pendingRef = nil
            stateStore.saveActiveRef(nil)
        }
        return slot
    }

    func retire(_ slot: Slot, wasActive: Bool, unregisterPush: Bool) async {
        await BoundedWait.run(budget: detachBudget) {
            if wasActive { await slot.detachActive() }
            if unregisterPush { await slot.syncPushRegistration(pushEnabled: false, notifyOnFinished: false) }
        }
        slot.tearDown()
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
        reconcileSelection(with: slot, serverId: serverId)
        publish()
        applyPendingSelection(for: serverId)
    }

    /// The coordinator owns the attachment; the hub mirrors it. Detach (⌘W),
    /// terminate, a stolen session, a failed resume, the Attach sheet and the QR
    /// scanner all move `activeSessionId` without going through the hub — and
    /// before this existed the stale highlight made the row un-reselectable.
    private func reconcileSelection(with slot: Slot, serverId: UUID) {
        guard selectionsInFlight == 0, pendingRef == nil else { return }
        let attached = slot.activeSessionId
        if let active = activeRef, active.serverId == serverId {
            guard attached != active.sessionId else { return }
            activeRef = attached.map { SessionRef(serverId: serverId, sessionId: $0) }
            stateStore.saveActiveRef(activeRef)
        } else if activeRef == nil, let attached {
            activeRef = SessionRef(serverId: serverId, sessionId: attached)
            stateStore.saveActiveRef(activeRef)
        }
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

    // MARK: - Fan-out (spec §7.3, D10)

    /// Foreground / wake / network-restored: every coordinator gets the event,
    /// staggered so N servers do not reconnect in lockstep. Offline ones are
    /// included — this is how they come back.
    public func handleForegroundTransition(userInitiated: Bool) async {
        let targets = bookmarks.filter(\.enabled).compactMap { slots[$0.id] }
        let hold = openLossHold(count: targets.count)
        await withTaskGroup(of: Void.self) { group in
            for (index, slot) in targets.enumerated() {
                let delay = stagger * index
                recordedSleeps.append(delay)
                group.addTask { @MainActor [weak self] in
                    defer { hold.latch.arrive() }
                    guard let self else { return }
                    await self.sleep(delay)
                    await slot.handleForegroundTransition(userInitiated: userInitiated)
                    // The trigger returns at once when a handshake or recovery
                    // is already running (the launch case); wait for that pass,
                    // whose list application is what reports (spec §6).
                    await slot.awaitPassFinished()
                }
            }
        }
        await hold.closed.value
        publish()
    }

    // MARK: - Session-loss notices (session takeover spec §2, §6)

    /// Opens a collector hold for one fan-out of `count` slots. It closes when
    /// every slot has arrived on the latch (trigger AND `awaitPassFinished`
    /// returned) or after `fanOutBudget`, whichever is first — raced through
    /// `BoundedWait`, because `awaitPassFinished` ignores cancellation. Reports
    /// arriving after the cap form the next (debounced) batch.
    private func openLossHold(count: Int) -> (latch: FanOutLatch, closed: Task<Void, Never>) {
        let latch = FanOutLatch(count: count)
        lossCollector.beginHold()
        let budget = fanOutBudget
        let closed = Task { @MainActor [lossCollector] in
            await BoundedWait.run(budget: budget) { await latch.wait() }
            lossCollector.endHold()
        }
        return (latch, closed)
    }

    private func collectLosses(_ report: SessionLossReport, serverId: UUID) {
        let config = bookmarks.first(where: { $0.id == serverId })
        let serverName = config.map { $0.displayName ?? $0.name } ?? ""
        func items(_ lost: [LostSession]) -> [SessionLossItem] {
            lost.map { SessionLossItem(serverId: serverId, serverName: serverName, session: $0) }
        }
        if !report.taken.isEmpty { lossCollector.report(items(report.taken), kind: .taken) }
        if !report.ended.isEmpty { lossCollector.report(items(report.ended), kind: .ended) }
    }

    private func presentLosses(taken: [SessionLossItem], ended: [SessionLossItem]) {
        if !taken.isEmpty {
            takenAlert = SessionLossAlert(title: SessionLossCopy.takenTitle(count: taken.count),
                                          message: SessionLossCopy.takenBody(taken))
        }
        if !ended.isEmpty { notice = SessionLossCopy.endedBody(ended) }
    }

    /// One server (the section's Retry) or all of them (menu bar / shortcut).
    public func triggerUserRecovery(serverId: UUID? = nil) {
        if let serverId { slots[serverId]?.triggerUserRecovery(); return }
        for (_, slot) in slots { slot.triggerUserRecovery() }
    }

    /// Push registration is per relay: each coordinator decides and sends for
    /// its own socket (spec §10).
    public func syncPushRegistration(pushEnabled: Bool, notifyOnFinished: Bool) async {
        pushSettings = (pushEnabled, notifyOnFinished)
        for (_, slot) in slots {
            await slot.syncPushRegistration(pushEnabled: pushEnabled, notifyOnFinished: notifyOnFinished)
        }
    }

    // MARK: - Collapse (per device)

    public func setCollapsed(_ serverId: UUID, _ collapsed: Bool) {
        if collapsed { collapsedServers.insert(serverId) } else { collapsedServers.remove(serverId) }
        stateStore.saveCollapsedServers(collapsedServers)
        publish()
    }
}
