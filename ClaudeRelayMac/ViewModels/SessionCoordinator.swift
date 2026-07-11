import Foundation
import Combine
import ClaudeRelayClient
import ClaudeRelayKit

@MainActor
final class SessionCoordinator: SharedSessionCoordinator {

    // MARK: - Mac-Only Published State

    @Published private(set) var isConnected = false
    @Published private(set) var isAuthenticated = false
    @Published var showQRScanner = false

    // MARK: - Dependencies

    private let config: ConnectionConfig
    private var recoveryObservers: [NSObjectProtocol] = []

    // MARK: - Configuration

    // SwiftLint wants `static` on a final class, but the parent's declaration is
    // `open class var`, so the override MUST use `class`.
    // swiftlint:disable:next static_over_final_class
    override class var keyPrefix: String { "com.clauderelay.mac" }

    override func sessionNamingTheme() -> SessionNamingTheme {
        AppSettings.shared.sessionNamingTheme
    }

    // MARK: - Init

    private var stateObserver: AnyCancellable?

    init(config: ConnectionConfig, token: String) {
        self.config = config
        super.init(connection: RelayConnection(), token: token)
        stateObserver = connection.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isConnected = (state == .connected)
            }
    }

    // MARK: - Start

    func start() async {
        do {
            try await connection.connect(config: config, token: token)
            registerRecoveryObservers()
            _ = try await ensureAuthenticated()
            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    override func didAuthenticate() {
        isAuthenticated = true
    }

    /// After a replay + server SIGWINCH, also re-sync SwiftTerm's local geometry
    /// and force a full repaint — clears any residual glyph overlap on the
    /// reused terminal view without waiting for the next output frame.
    override func didCompleteReplay(sessionId: UUID) {
        NotificationCenter.default.post(name: .terminalForceRedraw, object: nil)
    }

    // MARK: - Recovery Observers

    private func registerRecoveryObservers() {
        startNetworkRecovery()
        let wakeObs = NotificationCenter.default.addObserver(
            forName: SleepWakeObserver.systemDidWake,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerUserRecovery()
            }
        }
        recoveryObservers = [wakeObs]
    }

    private func unregisterRecoveryObservers() {
        for obs in recoveryObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        recoveryObservers.removeAll()
    }

    // MARK: - Teardown

    override func tearDown() {
        unregisterRecoveryObservers()
        super.tearDown()
    }

    // MARK: - Navigation

    static func nextIndex(current: Int, count: Int) -> Int? {
        guard count > 1 else { return nil }
        let next = (current + 1) % count
        return next == current ? nil : next
    }

    static func previousIndex(current: Int, count: Int) -> Int? {
        guard count > 1 else { return nil }
        let prev = (current - 1 + count) % count
        return prev == current ? nil : prev
    }

    func switchToNextSession() {
        guard let current = activeSessionId,
              let idx = activeSessions.firstIndex(where: { $0.id == current }),
              let next = Self.nextIndex(current: idx, count: activeSessions.count) else { return }
        let target = activeSessions[next].id
        Task { await switchToSession(id: target) }
    }

    func switchToPreviousSession() {
        guard let current = activeSessionId,
              let idx = activeSessions.firstIndex(where: { $0.id == current }),
              let prev = Self.previousIndex(current: idx, count: activeSessions.count) else { return }
        let target = activeSessions[prev].id
        Task { await switchToSession(id: target) }
    }

    func switchToSession(atIndex index: Int) {
        guard index >= 0, index < activeSessions.count else { return }
        let target = activeSessions[index].id
        guard target != activeSessionId else { return }
        Task { await switchToSession(id: target) }
    }

    // MARK: - Mac-Only Operations

    func detachSession(id: UUID) async {
        do {
            try await withAuth { controller in
                if self.activeSessionId == id {
                    try await controller.detach()
                }
            }
            if activeSessionId == id {
                terminalViewModels[id]?.prepareForSwitch()
                terminalViewModels[id] = nil
                activeSessionId = nil
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    override func terminateSession(id: UUID) async {
        await super.terminateSession(id: id)
        if activeSessionId == nil, let next = activeSessions.first {
            await switchToSession(id: next.id)
        }
    }
}
