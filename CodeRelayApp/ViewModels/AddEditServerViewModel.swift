import Foundation
import SwiftUI
import CodeRelayClient

/// Drives the Add/Edit Server form. Configuration only — no connection logic.
@MainActor
final class AddEditServerViewModel: ObservableObject {

    enum Mode {
        case add
        case edit(ConnectionConfig)
    }

    // MARK: - Form Fields

    @Published var name: String = ""
    @Published var host: String = ""
    @Published var port: String = "9200"
    @Published var token: String = ""
    @Published var useTLS: Bool = false
    @Published var showDeleteConfirmation: Bool = false

    let mode: Mode

    var isValid: Bool { !host.isEmpty }

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var navigationTitle: String {
        switch mode {
        case .add: return "Add Server"
        case .edit: return "Edit Server"
        }
    }

    // MARK: - Private

    private let existingId: UUID?

    // MARK: - Init

    init(mode: Mode) {
        self.mode = mode
        if case .edit(let config) = mode {
            existingId = config.id
            name = config.name
            host = config.host
            port = String(config.port)
            useTLS = config.useTLS
            token = (try? AuthManager.shared.loadToken(for: config.id)) ?? ""
        } else {
            existingId = nil
        }
    }

    // MARK: - Actions

    /// Validates, persists to SavedConnectionStore + Keychain, returns the saved config.
    func save() -> ConnectionConfig? {
        guard isValid else { return nil }
        guard let portNumber = UInt16(port), portNumber >= 1 else { return nil }

        let config = ConnectionConfig(
            id: existingId ?? UUID(),
            name: name.isEmpty ? host : name,
            host: host,
            port: portNumber,
            useTLS: useTLS
        )

        CodeRelayApp.savedConnections.add(config)

        if !token.isEmpty {
            try? AuthManager.shared.saveToken(token, for: config.id)
        }

        return config
    }

    var serverName: String {
        if case .edit(let config) = mode { return config.name }
        return ""
    }
}
