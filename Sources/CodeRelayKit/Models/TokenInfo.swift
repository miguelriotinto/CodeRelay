import Foundation

/// Represents metadata about an API token (the plaintext is never stored).
public struct TokenInfo: Codable, Sendable, Identifiable {
    /// Short identifier derived from UUID (first 8 characters, lowercase).
    public let id: String

    /// SHA-256 hex digest of the plaintext token.
    public let tokenHash: String

    /// Optional human-readable label.
    public var label: String?

    /// When the token was created.
    public let createdAt: Date

    /// When the token was last used for authentication.
    public var lastUsedAt: Date?

    /// When the token expires. `nil` means the token never expires.
    public let expiresAt: Date?

    /// Whether the token has expired.
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    public init(
        id: String,
        tokenHash: String,
        label: String? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.tokenHash = tokenHash
        self.label = label
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
    }
}
