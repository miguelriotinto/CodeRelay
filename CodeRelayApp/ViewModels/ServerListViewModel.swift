import Foundation
import SwiftUI
import Combine
import CodeRelayClient

/// The server management list (spec §8.1, §11). Enabled bookmarks are live in
/// the hub — their status comes from there. Only disabled bookmarks are probed
/// by the status poller (D11), so no bookmark is ever probed twice.
@MainActor
final class ServerListViewModel: ObservableObject {
    @Published private(set) var servers: [ConnectionConfig] = []
    @Published private(set) var serverStatuses: [UUID: ServerStatus] = [:]

    private let statusChecker = ServerStatusChecker(interval: 15)

    init() {
        statusChecker.$statuses.assign(to: &$serverStatuses)
        refreshServers()
    }

    deinit {
        let checker = statusChecker
        Task { @MainActor in checker.stopPolling() }
    }

    static func pollTargets(_ connections: [ConnectionConfig]) -> [ConnectionConfig] {
        connections.filter { !$0.enabled }
    }

    func refreshServers() {
        servers = CodeRelayApp.savedConnections.loadAll()
        statusChecker.refresh(connections: Self.pollTargets(servers))
    }

    func stopPolling() { statusChecker.stopPolling() }
}
