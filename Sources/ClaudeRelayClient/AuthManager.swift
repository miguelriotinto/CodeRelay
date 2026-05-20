import Foundation
import Security

/// Storage seam for AuthManager. Production uses `SystemKeychainStore`
/// (Security.framework). Tests inject `InMemoryKeychainStore` to avoid the
/// SPM-test-bundle entitlement problem (errSecMissingEntitlement -25244).
public protocol KeychainStoring: Sendable {
    /// Adds a generic-password item. Caller is responsible for deleting any
    /// existing entry first if it intends an "upsert".
    func add(service: String, account: String, data: Data) throws

    /// Returns the stored data, or nil if no entry exists.
    func get(service: String, account: String) throws -> Data?

    /// Deletes the entry. No-op if no entry exists (does not throw).
    func delete(service: String, account: String) throws
}

/// Production keychain store backed by Security.framework.
public struct SystemKeychainStore: KeychainStoring {
    public init() {}

    public func add(service: String, account: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthManagerError.keychainError(status: status)
        }
    }

    public func get(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AuthManagerError.keychainError(status: status)
        }
        return result as? Data
    }

    public func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthManagerError.keychainError(status: status)
        }
    }
}

/// Keychain wrapper for storing authentication tokens associated with ClaudeRelay connections.
public final class AuthManager: Sendable {
    public static let shared = AuthManager()

    private let service = "com.coderemote.relay"
    private let keychain: any KeychainStoring

    public init(keychain: any KeychainStoring = SystemKeychainStore()) {
        self.keychain = keychain
    }

    // MARK: - Public API

    /// Saves an authentication token to the Keychain for the given connection.
    public func saveToken(_ token: String, for connectionId: UUID) throws {
        guard let data = token.data(using: .utf8) else {
            throw AuthManagerError.encodingFailed
        }
        let account = connectionId.uuidString
        // Delete any existing entry first to avoid duplicates.
        try? keychain.delete(service: service, account: account)
        try keychain.add(service: service, account: account, data: data)
    }

    /// Loads an authentication token from the Keychain for the given connection.
    /// Returns `nil` if no token is stored.
    public func loadToken(for connectionId: UUID) throws -> String? {
        guard let data = try keychain.get(service: service, account: connectionId.uuidString) else {
            return nil
        }
        guard let token = String(data: data, encoding: .utf8) else {
            throw AuthManagerError.decodingFailed
        }
        return token
    }

    /// Deletes an authentication token from the Keychain for the given connection.
    public func deleteToken(for connectionId: UUID) throws {
        try keychain.delete(service: service, account: connectionId.uuidString)
    }

    // MARK: - Bedrock bearer token (C-25)

    /// Account key used for the Bedrock bearer token entry. Kept as a
    /// well-known string so both apps hit the same Keychain item and a future
    /// sharing / preferences-migration flow can look it up without reflection.
    private var bedrockAccount: String { "com.clauderelay.bedrock.bearerToken" }

    /// Saves the Bedrock bearer token to the Keychain. Empty string deletes
    /// the entry.
    public func saveBedrockToken(_ token: String) throws {
        if token.isEmpty {
            try deleteBedrockToken()
            return
        }
        guard let data = token.data(using: .utf8) else {
            throw AuthManagerError.encodingFailed
        }
        try? keychain.delete(service: service, account: bedrockAccount)
        try keychain.add(service: service, account: bedrockAccount, data: data)
    }

    /// Loads the Bedrock bearer token from the Keychain, or returns `nil` if
    /// no entry exists.
    public func loadBedrockToken() throws -> String? {
        guard let data = try keychain.get(service: service, account: bedrockAccount) else {
            return nil
        }
        guard let token = String(data: data, encoding: .utf8) else {
            throw AuthManagerError.decodingFailed
        }
        return token
    }

    /// Deletes the Bedrock bearer token Keychain entry. No-op when absent.
    public func deleteBedrockToken() throws {
        try keychain.delete(service: service, account: bedrockAccount)
    }
}

// MARK: - Errors

public enum AuthManagerError: Error, LocalizedError {
    case encodingFailed
    case decodingFailed
    case keychainError(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode token as UTF-8 data."
        case .decodingFailed:
            return "Failed to decode token from Keychain data."
        case .keychainError(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}
