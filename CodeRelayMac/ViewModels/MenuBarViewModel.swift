import Foundation
import SwiftUI
import CodeRelayClient
import CodeRelayKit

/// Singleton that the menu bar dropdown and main window both write to.
/// When the main window connects, it registers its coordinator here.
@MainActor
final class ActiveCoordinatorRegistry: ObservableObject {
    static let shared = ActiveCoordinatorRegistry()

    /// The one hub the main window owns. Menu bar and app commands read the
    /// active coordinator through it.
    @Published private(set) var hub: MacServerHub?

    /// Convenience for callers that act on the attached session's relay.
    var coordinator: SessionCoordinator? { hub?.activeCoordinator }
    var serverName: String? {
        guard let hub, let ref = hub.activeRef else { return nil }
        return hub.sections.first(where: { $0.id == ref.serverId })?.title
    }

    private init() {}

    func register(hub: MacServerHub) { self.hub = hub }
    func clear() { hub = nil }
}

/// Menu bar dropdown's view model — derived from ActiveCoordinatorRegistry.
@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published private(set) var connectionLabel: String = "Not connected"
    @Published private(set) var connectionColor: Color = .secondary
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var activityStates: [UUID: ActivityState] = [:]
    @Published private(set) var agentIds: [UUID: String] = [:]
    @Published private(set) var activeSessionId: UUID?

    private var registryTask: Task<Void, Never>?
    private var hubTask: Task<Void, Never>?
    private var coordinatorTasks: [Task<Void, Never>] = []

    init() {
        observeRegistry()
    }

    private func observeRegistry() {
        registryTask?.cancel()
        let registry = ActiveCoordinatorRegistry.shared
        registryTask = Task { [weak self] in
            for await hub in registry.$hub.values {
                guard let self else { return }
                self.cancelCoordinatorTasks()
                self.hubTask?.cancel()
                if let hub {
                    self.followHub(hub)
                } else {
                    self.connectionLabel = "Not connected"
                    self.connectionColor = .secondary
                    self.sessions = []
                    self.activityStates = [:]
                    self.agentIds = [:]
                    self.activeSessionId = nil
                }
            }
        }
    }

    /// Re-follows the hub's active coordinator whenever the active ref moves to
    /// another server; Task 10 adds the per-server grouping on top.
    private func followHub(_ hub: MacServerHub) {
        hubTask = Task { [weak self] in
            for await ref in hub.$activeRef.values {
                guard let self else { return }
                self.cancelCoordinatorTasks()
                self.activeSessionId = ref?.sessionId
                if let coordinator = hub.activeCoordinator {
                    self.connectionLabel = ActiveCoordinatorRegistry.shared.serverName ?? "Connected"
                    self.connectionColor = coordinator.isConnected ? .green : .orange
                    self.followCoordinator(coordinator)
                } else {
                    self.connectionLabel = hub.sections.first(where: { $0.config.enabled })?.title ?? "Not connected"
                    self.connectionColor = hub.aggregate.liveServers > 0 ? .green : .secondary
                    self.sessions = []
                    self.activityStates = [:]
                    self.agentIds = [:]
                }
            }
        }
    }

    private func cancelCoordinatorTasks() {
        for task in coordinatorTasks { task.cancel() }
        coordinatorTasks.removeAll()
    }

    /// Spawns three independent tasks observing the coordinator's published
    /// state. Each task runs until the coordinator is replaced (new coordinator
    /// or nil), at which point cancelCoordinatorTasks() cancels them.
    private func followCoordinator(_ coordinator: SessionCoordinator) {
        // Cancel any pre-existing follow tasks before spawning new ones — avoids
        // stacking three tasks per coordinator swap during rapid reconnects.
        cancelCoordinatorTasks()

        let sessionsTask = Task { [weak self] in
            for await s in coordinator.$sessions.values {
                guard let self else { return }
                // The server's token-scoped list IS the set of sessions this
                // token owns; render it directly (minus terminal), matching the
                // sidebar's `coordinator.activeSessions`.
                self.sessions = Self.visibleSessions(s)
                self.recomputeActivityStates(coordinator: coordinator)
            }
        }
        let activeTask = Task { [weak self] in
            for await id in coordinator.$activeSessionId.values {
                guard let self else { return }
                self.activeSessionId = id
            }
        }
        let agentTask = Task { [weak self] in
            for await _ in coordinator.activityCoordinator.$agentSessions.values {
                guard let self else { return }
                self.recomputeActivityStates(coordinator: coordinator)
            }
        }
        coordinatorTasks = [sessionsTask, activeTask, agentTask]
    }

    private func recomputeActivityStates(coordinator: SessionCoordinator) {
        let (states, ids) = Self.computeActivityStates(
            sessions: sessions,
            awaitingInput: coordinator.sessionsAwaitingInput,
            activeAgentLookup: { coordinator.activeAgent(for: $0) }
        )
        activityStates = states
        agentIds = ids
    }

    /// Pure helper used by `followCoordinator` and unit tests. Drops terminal
    /// sessions; the server's token-scoped list is already the ownership
    /// boundary, so there is no local owned-set filter.
    static func visibleSessions(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.filter { !$0.state.isTerminal }
    }

    static func computeActivityStates(
        sessions: [SessionInfo],
        awaitingInput: Set<UUID>,
        activeAgentLookup: (UUID) -> String?
    ) -> (states: [UUID: ActivityState], agentIds: [UUID: String]) {
        var states: [UUID: ActivityState] = [:]
        var ids: [UUID: String] = [:]
        for session in sessions {
            let awaiting = awaitingInput.contains(session.id)
            if let agentId = activeAgentLookup(session.id) {
                states[session.id] = awaiting ? .agentIdle : .agentActive
                ids[session.id] = agentId
            } else {
                states[session.id] = awaiting ? .idle : .active
            }
        }
        return (states, ids)
    }

    deinit {
        registryTask?.cancel()
        hubTask?.cancel()
        for task in coordinatorTasks { task.cancel() }
    }
}
