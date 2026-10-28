import Foundation
import Combine
@testable import CodeRelayClient
@testable import CodeRelayKit

/// A scriptable stand-in for a per-server coordinator. Every hub test drives
/// the hub through this, so hub behaviour is proven against the protocol, not
/// against a live socket.
@MainActor
final class FakeServerSlot: ServerSlotCoordinating {
    let config: ConnectionConfig
    @Published var sessions: [SessionInfo] = []
    @Published var activeSessionId: UUID?
    @Published var isRecovering = false
    @Published var recoveryFailed = false
    @Published var isAuthRejected = false
    @Published var isPerformingHandshake = false
    @Published var connectionState: RelayConnection.ConnectionState = .disconnected
    @Published var serverIdentity: ServerIdentity?
    @Published var sessionLoadPhase: SessionLoadPhase?
    let activityCoordinator: ActivityCoordinator

    var activeSessions: [SessionInfo] { sessions.filter { !$0.state.isTerminal } }

    // Spies
    private(set) var startCount = 0
    private(set) var switchedTo: [UUID] = []
    private(set) var detachActiveCount = 0
    private(set) var createCount = 0
    private(set) var foregroundCount = 0
    private(set) var userRecoveryCount = 0
    private(set) var tornDown = false
    private(set) var pushSyncs: [(Bool, Bool)] = []
    private(set) var remoteAttaches: [UUID] = []
    private(set) var fetchCount = 0
    /// Order of calls across slots, written into a shared log by the test.
    var log: ((String) -> Void)?
    /// Makes `detachActive` hang until released (for the budget test).
    var detachGate: CheckedContinuation<Void, Never>?
    var detachHangs = false
    /// Makes `start()` / `handleForegroundTransition` park until released, so a
    /// test can prove the hub does not serialise the other servers behind them.
    var startHangs = false
    var startGate: CheckedContinuation<Void, Never>?
    var foregroundHangs = false
    var foregroundGate: CheckedContinuation<Void, Never>?
    /// `switchToSession` leaves `activeSessionId` untouched (a failed resume).
    var switchFails = false

    init(config: ConnectionConfig, defaults: UserDefaults) {
        self.config = config
        let store = SessionOwnershipStore(keyPrefix: "fake.\(config.id.uuidString)", deviceId: "d", defaults: defaults)
        self.activityCoordinator = ActivityCoordinator(ownershipStore: store, initialAgents: [:])
    }

    func start() async {
        startCount += 1; log?("start:\(config.name)")
        if startHangs { await withCheckedContinuation { startGate = $0 } }
    }
    func switchToSession(id: UUID) async {
        switchedTo.append(id); log?("switch:\(config.name)")
        if !switchFails { activeSessionId = id }
    }
    func createNewSession() async { createCount += 1; let id = UUID(); activeSessionId = id; log?("create:\(config.name)") }
    func detachActive() async {
        detachActiveCount += 1; log?("detach:\(config.name)")
        if detachHangs { await withCheckedContinuation { detachGate = $0 } }
        activeSessionId = nil
    }
    func handleForegroundTransition(userInitiated: Bool) async {
        foregroundCount += 1; log?("fg:\(config.name)")
        if foregroundHangs { await withCheckedContinuation { foregroundGate = $0 } }
    }
    func triggerUserRecovery() { userRecoveryCount += 1; log?("recover:\(config.name)") }
    func tearDown() { tornDown = true; log?("teardown:\(config.name)") }
    func syncPushRegistration(pushEnabled: Bool, notifyOnFinished: Bool) async {
        pushSyncs.append((pushEnabled, notifyOnFinished)); log?("push:\(pushEnabled)")
    }
    func attachRemoteSession(id: UUID, serverName: String?) async { remoteAttaches.append(id); activeSessionId = id }
    func fetchSessions(force: Bool) async { fetchCount += 1 }

    // Helpers
    func goLive(with sessions: [SessionInfo]) {
        connectionState = .connected
        isPerformingHandshake = false
        self.sessions = sessions
    }
    func goOffline() { connectionState = .disconnected }
}

/// Shared test scaffolding for hub tests.
@MainActor
final class HubHarness {
    let defaults: UserDefaults
    let bookmarks: SavedConnectionStore
    let tokens: FakeTokens
    let state: HubStateStore
    private(set) var hub: ServerHub<FakeServerSlot>!
    /// Every fake the factory produced, in build order.
    private(set) var built: [FakeServerSlot] = []
    /// Bookmarks whose fake should park in `start()` until released.
    var startHangs: Set<UUID> = []
    /// When `gatedSleep` is on, every hub sleep parks here until `releaseSleeps()`.
    private var sleepGates: [CheckedContinuation<Void, Never>] = []
    private(set) var sleepCalls = 0

    final class FakeTokens: TokenProviding, TokenDeleting {
        var tokens: [UUID: String] = [:]
        func loadToken(for connectionId: UUID) throws -> String? { tokens[connectionId] }
        func deleteTokenIgnoringErrors(for connectionId: UUID) { tokens[connectionId] = nil }
    }

    init(configs: [ConnectionConfig], tokensFor: [UUID]? = nil, stagger: Duration = .milliseconds(150),
         maxEnabled: Int = 8, gatedSleep: Bool = false) {
        let suite = "HubTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        bookmarks = SavedConnectionStore(key: "hub.bookmarks", defaults: defaults)
        bookmarks.saveAll(configs)
        tokens = FakeTokens()
        for c in configs where tokensFor?.contains(c.id) ?? true { tokens.tokens[c.id] = "tok-\(c.name)" }
        state = HubStateStore(keyPrefix: "hub.test", deviceId: "d", defaults: defaults)
        let d = defaults
        hub = ServerHub(bookmarks: bookmarks, tokens: tokens, stateStore: state, keyPrefix: "hub.test",
                        factory: { [unowned self] config, _ in
                            let slot = FakeServerSlot(config: config, defaults: d)
                            slot.startHangs = self.startHangs.contains(config.id)
                            self.built.append(slot)
                            return slot
                        },
                        maxEnabled: maxEnabled, stagger: stagger,
                        sleep: { [unowned self] _ in
                            self.sleepCalls += 1
                            if gatedSleep { await withCheckedContinuation { self.sleepGates.append($0) } }
                        })
    }

    func releaseSleeps() { let gates = sleepGates; sleepGates.removeAll(); for g in gates { g.resume() } }
    func releaseStart(_ id: UUID) { slot(id)?.startGate?.resume(); slot(id)?.startGate = nil }

    func slot(_ id: UUID) -> FakeServerSlot? { hub.slot(for: id) }
}

/// Lets the hub's main-queue hops (objectWillChange → slotDidChange) land.
@MainActor
func hubSettle() async {
    try? await Task.sleep(for: .milliseconds(30))
}

func makeConfig(_ name: String, enabled: Bool = true) -> ConnectionConfig {
    ConnectionConfig(name: name, host: "\(name).local", enabled: enabled)
}

func makeSession(_ id: UUID = UUID(), dir: String? = "/repo", state: SessionState = .activeDetached,
                 agentState: AgentDetectedState? = nil) -> SessionInfo {
    SessionInfo(id: id, name: nil, state: state, tokenId: "tok", createdAt: Date(), cols: 80, rows: 24,
                activity: agentState == nil ? nil : .agentActive, agent: agentState == nil ? nil : "claude",
                agentState: agentState, title: nil, workingDir: dir)
}
