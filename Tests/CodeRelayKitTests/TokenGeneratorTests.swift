import XCTest
@testable import CodeRelayKit

final class TokenGeneratorTests: XCTestCase {

    // MARK: - Token Generation

    func testGeneratedTokenIs43Characters() {
        let (plaintext, _) = TokenGenerator.generate()
        XCTAssertEqual(plaintext.count, 43, "Token should be 43 characters (32 bytes base64url no padding)")
    }

    func testGeneratedTokenIsBase64URL() {
        let (plaintext, _) = TokenGenerator.generate()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for scalar in plaintext.unicodeScalars {
            XCTAssertTrue(allowed.contains(scalar), "Character '\(scalar)' is not valid base64URL")
        }
    }

    // MARK: - Hashing

    func testHashIsDeterministic() {
        let input = "test-token-value"
        let hash1 = TokenGenerator.hash(input)
        let hash2 = TokenGenerator.hash(input)
        XCTAssertEqual(hash1, hash2, "Hash should be deterministic")
    }

    func testDifferentTokensProduceDifferentHashes() {
        let hash1 = TokenGenerator.hash("token-one")
        let hash2 = TokenGenerator.hash("token-two")
        XCTAssertNotEqual(hash1, hash2, "Different tokens should produce different hashes")
    }

    func testGenerateProducesMatchingHash() {
        let (plaintext, info) = TokenGenerator.generate()
        let expectedHash = TokenGenerator.hash(plaintext)
        XCTAssertEqual(info.tokenHash, expectedHash, "TokenInfo hash should match hash of plaintext")
    }

    // MARK: - Validation

    func testValidatePositive() {
        let (plaintext, info) = TokenGenerator.generate()
        XCTAssertTrue(TokenGenerator.validate(plaintext, against: info.tokenHash), "Should validate correct token")
    }

    func testValidateNegative() {
        let (_, info) = TokenGenerator.generate()
        XCTAssertFalse(TokenGenerator.validate("wrong-token", against: info.tokenHash), "Should reject wrong token")
    }

    // MARK: - TokenInfo Codable

    func testTokenInfoCodableRoundTrip() throws {
        let (_, info) = TokenGenerator.generate(label: "my-label")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(info)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TokenInfo.self, from: data)

        XCTAssertEqual(decoded.id, info.id)
        XCTAssertEqual(decoded.tokenHash, info.tokenHash)
        XCTAssertEqual(decoded.label, info.label)
        XCTAssertEqual(decoded.label, "my-label")
        XCTAssertEqual(
            decoded.createdAt.timeIntervalSinceReferenceDate,
            info.createdAt.timeIntervalSinceReferenceDate,
            accuracy: 1.0
        )
        XCTAssertNil(decoded.lastUsedAt)
    }

    // MARK: - Uniqueness

    func testHundredGeneratedTokensAreUnique() {
        var tokens = Set<String>()
        for _ in 0..<100 {
            let (plaintext, _) = TokenGenerator.generate()
            tokens.insert(plaintext)
        }
        XCTAssertEqual(tokens.count, 100, "All 100 generated tokens should be unique")
    }

    // MARK: - TokenInfo.isExpired

    func testIsExpiredWhenExpiresAtIsNil() {
        let info = TokenInfo(id: "test", tokenHash: "abc", expiresAt: nil)
        XCTAssertFalse(info.isExpired, "Token with nil expiresAt should never be expired")
    }

    func testIsExpiredWhenExpiresAtIsPast() {
        let pastDate = Date().addingTimeInterval(-3600)
        let info = TokenInfo(id: "test", tokenHash: "abc", expiresAt: pastDate)
        XCTAssertTrue(info.isExpired, "Token with past expiresAt should be expired")
    }

    func testIsExpiredWhenExpiresAtIsFuture() {
        let futureDate = Date().addingTimeInterval(3600)
        let info = TokenInfo(id: "test", tokenHash: "abc", expiresAt: futureDate)
        XCTAssertFalse(info.isExpired, "Token with future expiresAt should not be expired")
    }

    // MARK: - Expiry Generation

    func testGenerateWithExpiryDays() {
        let (_, info) = TokenGenerator.generate(label: "expiring", expiryDays: 7)
        XCTAssertNotNil(info.expiresAt)
        let expected = Date().addingTimeInterval(7 * 86400)
        XCTAssertEqual(
            info.expiresAt!.timeIntervalSinceReferenceDate,
            expected.timeIntervalSinceReferenceDate,
            accuracy: 2.0
        )
    }

    func testGenerateWithZeroExpiryDays() {
        let (_, info) = TokenGenerator.generate(expiryDays: 0)
        XCTAssertNotNil(info.expiresAt)
        XCTAssertEqual(
            info.expiresAt!.timeIntervalSinceReferenceDate,
            Date().timeIntervalSinceReferenceDate,
            accuracy: 2.0,
            "Zero expiry days should set expiresAt to approximately now"
        )
    }

    func testGenerateWithNilExpiryDays() {
        let (_, info) = TokenGenerator.generate(expiryDays: nil)
        XCTAssertNil(info.expiresAt, "Nil expiry days should produce nil expiresAt")
    }

    // MARK: - Hash Format

    func testHashOutputIs64HexChars() {
        let hash = TokenGenerator.hash("test-token")
        XCTAssertEqual(hash.count, 64, "SHA-256 hex digest should be 64 characters")
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        for scalar in hash.unicodeScalars {
            XCTAssertTrue(hexChars.contains(scalar), "Hash should only contain lowercase hex: \(scalar)")
        }
    }

    func testBase64URLContainsNoInvalidChars() {
        for _ in 0..<20 {
            let (plaintext, _) = TokenGenerator.generate()
            XCTAssertFalse(plaintext.contains("+"), "Base64URL should not contain +")
            XCTAssertFalse(plaintext.contains("/"), "Base64URL should not contain /")
            XCTAssertFalse(plaintext.contains("="), "Base64URL should not contain padding =")
        }
    }
}
