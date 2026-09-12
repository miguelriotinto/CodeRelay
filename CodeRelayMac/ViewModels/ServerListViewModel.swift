import Foundation
import SwiftUI
import CodeRelayClient

@MainActor
final class ServerListViewModel: ObservableObject {

    @Published private(set) var connections: [ConnectionConfig] = []
    @Published private(set) var statuses: [UUID: ServerStatus] = [:]
    @Published var selectedConnectionId: UUID?

    private let statusChecker = ServerStatusChecker(interval: 5)

    init() {
        statusChecker.$statuses.assign(to: &$statuses)
        loadConnections()
    }

    // MARK: - CRUD

    func loadConnections() {
        connections = CodeRelayMacApp.savedConnections.loadAll()
        let lastId = AppSettings.shared.lastServerId
        if let uuid = UUID(uuidString: lastId), connections.contains(where: { $0.id == uuid }) {
            selectedConnectionId = uuid
        } else {
            selectedConnectionId = connections.first?.id
        }
        statusChecker.refresh(connections: connections)
    }

    func addOrUpdate(_ connection: ConnectionConfig) {
        _ = CodeRelayMacApp.savedConnections.add(connection)
        loadConnections()
    }

    func delete(id: UUID) {
        _ = CodeRelayMacApp.savedConnections.delete(id: id)
        loadConnections()
    }

    // MARK: - Selection

    func selectedConnection() -> ConnectionConfig? {
        guard let id = selectedConnectionId else { return nil }
        return connections.first { $0.id == id }
    }

    func markAsLastUsed(_ id: UUID) {
        AppSettings.shared.lastServerId = id.uuidString
    }

    // MARK: - Lifecycle

    func stopAllPolling() {
        statusChecker.stopPolling()
    }
}
