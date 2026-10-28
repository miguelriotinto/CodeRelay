import Foundation
import SwiftUI
import CodeRelayClient

/// The server management list (spec §8.1, §11). Enabled bookmarks are live in
/// the hub — their status comes from there. Only disabled bookmarks are probed
/// by the status poller (D11), so no bookmark is ever probed twice.
@MainActor
final class ServerListViewModel: ObservableObject {
    @Published private(set) var connections: [ConnectionConfig] = []
    @Published private(set) var statuses: [UUID: ServerStatus] = [:]
    @Published var selectedConnectionId: UUID?

    private let statusChecker = ServerStatusChecker(interval: 15)

    init() {
        statusChecker.$statuses.assign(to: &$statuses)
        loadConnections()
    }

    static func pollTargets(_ connections: [ConnectionConfig]) -> [ConnectionConfig] {
        connections.filter { !$0.enabled }
    }

    func loadConnections() {
        connections = CodeRelayMacApp.savedConnections.loadAll()
        if selectedConnectionId == nil || !connections.contains(where: { $0.id == selectedConnectionId }) {
            selectedConnectionId = connections.first?.id
        }
        statusChecker.refresh(connections: Self.pollTargets(connections))
    }

    func addOrUpdate(_ connection: ConnectionConfig) {
        _ = CodeRelayMacApp.savedConnections.add(connection)
        loadConnections()
    }

    func stopAllPolling() { statusChecker.stopPolling() }
}
