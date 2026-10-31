import Foundation
import Combine
import CodeRelayClient
import CodeRelayKit

@MainActor
final class SessionCoordinator: SharedSessionCoordinator {

    // MARK: - Mac-Only Published State

    @Published private(set) var isConnected = false
    @Published private(set) var isAuthenticated = false
    @Published var showQRScanner = false

    // MARK: - Dependencies

    private let config: ConnectionConfig

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

    /// - Parameter ownershipKeyPrefix: per-server UserDefaults namespace from
    ///   the hub (multi-server D8); nil keeps the single-server default.
    init(config: ConnectionConfig, token: String, ownershipKeyPrefix: String? = nil) {
        self.config = config
        super.init(connection: RelayConnection(), token: token, ownershipKeyPrefix: ownershipKeyPrefix)
        stateObserver = connection.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isConnected = (state == .connected)
            }
    }

    // MARK: - Start

    /// Wake and network-restored events are fanned out by the hub with a
    /// stagger (multi-server D10); this coordinator installs no observers of
    /// its own, or every wake would reconnect it twice.
    override func start(reason: SessionHandshake.Reason) async {
        // `.enable` clears the loss baseline before the dial; a failed dial
        // falls through to the handshake, which reconnects on its own. The
        // handshake (authenticate + fetch the sessions this client owns) is
        // also the only auth call on this path, so a wake trigger firing
        // mid-launch joins this pass instead of reconnecting underneath it.
        await dialAndHandshake(reason: reason) {
            try await connection.connect(config: config, token: token)
        }
    }

    override func didAuthenticate() {
        isAuthenticated = true
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
