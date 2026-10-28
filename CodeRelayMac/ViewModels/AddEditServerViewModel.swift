import Foundation
import SwiftUI
import CodeRelayClient

@MainActor
final class AddEditServerViewModel: ObservableObject {

    // MARK: - Form State

    @Published var name: String = ""
    @Published var host: String = ""
    @Published var port: String = "9200"
    @Published var useTLS: Bool = false
    @Published var token: String = ""
    @Published var validationError: String?

    // MARK: - Context

    /// Existing connection being edited, or nil for add-mode. Kept whole so an
    /// edit preserves `enabled`, `instanceId` and `displayName` — rebuilding the
    /// config from the form silently re-enabled disabled bookmarks.
    private let existing: ConnectionConfig?
    private var editingId: UUID? { existing?.id }

    init(existing: ConnectionConfig? = nil) {
        self.existing = existing
        if let existing {
            self.name = existing.name
            self.host = existing.host
            self.port = String(existing.port)
            self.useTLS = existing.useTLS
            // Load token from Keychain for display/edit.
            if let stored = try? AuthManager.shared.loadToken(for: existing.id) {
                self.token = stored
            }
        }
    }

    var isEditing: Bool { editingId != nil }

    // MARK: - Validation

    func validate() -> Bool {
        validationError = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationError = "Name is required"
            return false
        }

        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty else {
            validationError = "Host is required"
            return false
        }

        guard let portValue = UInt16(port), portValue >= 1 else {
            validationError = "Port must be a number between 1 and 65535"
            return false
        }

        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationError = "Token is required"
            return false
        }

        return true
    }

    // MARK: - Save

    /// Builds a ConnectionConfig from the current form state. Caller is
    /// responsible for calling addOrUpdate on the list view model and for
    /// saving the token via AuthManager.
    func buildConnection() -> ConnectionConfig? {
        guard validate() else { return nil }
        let portValue = UInt16(port) ?? 9200
        var config = existing ?? ConnectionConfig(name: "", host: "")
        config.name = name.trimmingCharacters(in: .whitespaces)
        config.host = host.trimmingCharacters(in: .whitespaces)
        config.port = portValue
        config.useTLS = useTLS
        return config
    }

    /// Persists the token to Keychain. Call after successfully adding the connection.
    func saveToken(for connectionId: UUID) throws {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        try AuthManager.shared.saveToken(trimmed, for: connectionId)
    }
}
