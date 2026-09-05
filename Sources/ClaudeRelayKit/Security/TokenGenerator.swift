import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - Data Extension

extension Data {
    /// Base64URL encoding without padding (RFC 4648 Section 5).
    /// Single-pass transformation instead of 3 separate string scans.
    func base64URLEncodedString() -> String {
        var result = base64EncodedString()
        result.unicodeScalars.removeAll(where: { $0 == "=" })
        return String(result.map { ch in
            switch ch {
            case "+": return "-"
            case "/": return "_"
            default: return ch
            }
        })
    }
}

// MARK: - TokenGenerator

/// Generates cryptographically secure API tokens and provides hashing/validation utilities.
public enum TokenGenerator {

    /// Generates a new random token and its associated `TokenInfo`.
    ///
    /// - Parameters:
    ///   - label: Optional human-readable label for the token.
    ///   - expiryDays: Number of days until the token expires. `nil` means never expires.
    /// - Returns: A tuple of the plaintext token (43 chars, base64URL) and its `TokenInfo`.
    public static func generate(label: String? = nil, expiryDays: Int? = nil) -> (plaintext: String, info: TokenInfo) {
        // 32 cryptographically secure random bytes
        let bytes = SecureRandom.bytes(count: 32)

        // Base64URL encode (no padding) -> 43 characters
        let plaintext = Data(bytes).base64URLEncodedString()

        // SHA-256 hash of the plaintext
        let tokenHash = hash(plaintext)

        // Short ID from UUID
        let id = String(UUID().uuidString.prefix(8)).lowercased()

        let now = Date()
        let expiresAt = expiryDays.map { now.addingTimeInterval(Double($0) * 86400) }

        let info = TokenInfo(
            id: id,
            tokenHash: tokenHash,
            label: label,
            createdAt: now,
            expiresAt: expiresAt
        )

        return (plaintext, info)
    }

    /// Computes the SHA-256 hex digest of a token string.
    ///
    /// - Parameter token: The plaintext token.
    /// - Returns: Lowercase hex-encoded SHA-256 hash.
    public static func hash(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Validates a plaintext token against a stored hash.
    ///
    /// - Parameters:
    ///   - token: The plaintext token to validate.
    ///   - storedHash: The previously stored SHA-256 hex hash.
    /// - Returns: `true` if the token matches the stored hash.
    public static func validate(_ token: String, against storedHash: String) -> Bool {
        hash(token) == storedHash
    }
}
