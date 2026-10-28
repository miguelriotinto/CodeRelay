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

    init(config: ConnectionConfig, defaults: UserDefaults) {
        self.config = config
        let store = SessionOwnershipStore(keyPrefix: "fake.\(config.id.uuidString)", deviceId: "d", defaults: defaults)
        self.activityCoordinator = ActivityCoordinator(ownershipStore: store, initialAgents: [:])
    }

    func start() async { startCount += 1; log?("start:\(config.name)") }
    func switchToSession(id: UUID) async { switchedTo.append(id); activeSessionId = id; log?("switch:\(config.name)") }
    func createNewSession() async { createCount += 1; let id = UUID(); activeSessionId = id; log?("create:\(config.name)") }
    func detachActive() async {
        detachActiveCount += 1; log?("detach:\(config.name)")
        if detachHangs { await withCheckedContinuation { detachGate = $0 } }
        activeSessionId = nil
    }
    func handleForegroundTransition(userInitiated: Bool) async { foregroundCount += 1; log?("fg:\(config.name)") }
    func triggerUserRecovery() { userRecoveryCount += 1; log?("recover:\(config.name)") }
    func tearDown() { tornDown = true; log?("teardown:\(config.name)") }
    func syncPushRegistration(pushEnabled: Bool, notifyOnFinished: Bool) async { pushSyncs.append((pushEnabled, notifyOnFinished)) }
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

    final class FakeTokens: TokenProviding, TokenDeleting {
        var tokens: [UUID: String] = [:]
        func loadToken(for connectionId: UUID) throws -> String? { tokens[connectionId] }
        func deleteTokenIgnoringErrors(for connectionId: UUID) { tokens[connectionId] = nil }
    }

    init(configs: [ConnectionConfig], tokensFor: [UUID]? = nil, stagger: Duration = .milliseconds(150)) {
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
                        factory: { config, _ in FakeServerSlot(config: config, defaults: d) },
                        maxEnabled: 8, stagger: stagger,
                        sleep: { _ in })
    }

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
