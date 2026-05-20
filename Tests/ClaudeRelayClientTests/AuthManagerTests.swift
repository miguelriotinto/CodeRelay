import XCTest
@testable import ClaudeRelayClient

/// Unit tests for `AuthManager`. Uses an in-memory `KeychainStoring` fake so
/// the SPM-test bundle (which has no Keychain entitlement) can exercise the
/// full save/load/delete API without ever touching the real Keychain.
///
/// The `SystemKeychainStore` path is exercised in production by the iOS and
/// macOS apps, where the bundle IS code-signed and entitled. Repeating those
/// integration smoke checks under SPM would only re-test Apple's API.
final class AuthManagerTests: XCTestCase {

    private var keychain: InMemoryKeychainStore!
    private var manager: AuthManager!
    private let testId = UUID()

    override func setUp() {
        super.setUp()
        keychain = InMemoryKeychainStore()
        manager = AuthManager(keychain: keychain)
    }

    override func tearDown() {
        manager = nil
        keychain = nil
        super.tearDown()
    }

    // MARK: - Per-connection token

    func testSaveAndLoadToken() throws {
        try manager.saveToken("test-token-123", for: testId)
        XCTAssertEqual(try manager.loadToken(for: testId), "test-token-123")
    }

    func testLoadReturnNilForMissingToken() throws {
        XCTAssertNil(try manager.loadToken(for: UUID()))
    }

    func testDeleteRemovesToken() throws {
        try manager.saveToken("delete-me", for: testId)
        try manager.deleteToken(for: testId)
        XCTAssertNil(try manager.loadToken(for: testId))
    }

    func testOverwriteExistingToken() throws {
        try manager.saveToken("old-token", for: testId)
        try manager.saveToken("new-token", for: testId)
        XCTAssertEqual(try manager.loadToken(for: testId), "new-token")
    }

    func testDeleteNonExistentTokenDoesNotThrow() {
        XCTAssertNoThrow(try manager.deleteToken(for: UUID()))
    }

    /// Two different connection IDs must not collide in the same keychain.
    func testDifferentConnectionsAreIsolated() throws {
        let idA = UUID(), idB = UUID()
        try manager.saveToken("token-a", for: idA)
        try manager.saveToken("token-b", for: idB)
        XCTAssertEqual(try manager.loadToken(for: idA), "token-a")
        XCTAssertEqual(try manager.loadToken(for: idB), "token-b")
    }

    // MARK: - Bedrock token (C-25)

    func testBedrockTokenSaveAndLoad() throws {
        try manager.saveBedrockToken("aws-bedrock-secret")
        XCTAssertEqual(try manager.loadBedrockToken(), "aws-bedrock-secret")
    }

    func testBedrockTokenLoadReturnsNilWhenMissing() throws {
        XCTAssertNil(try manager.loadBedrockToken())
    }

    func testBedrockTokenSaveEmptyDeletes() throws {
        try manager.saveBedrockToken("existing")
        try manager.saveBedrockToken("")
        XCTAssertNil(try manager.loadBedrockToken())
    }

    func testBedrockTokenOverwrite() throws {
        try manager.saveBedrockToken("old")
        try manager.saveBedrockToken("new")
        XCTAssertEqual(try manager.loadBedrockToken(), "new")
    }

    func testBedrockTokenDeleteIsIdempotent() {
        XCTAssertNoThrow(try manager.deleteBedrockToken())
        XCTAssertNoThrow(try manager.deleteBedrockToken())
    }

    /// The Bedrock token uses a fixed account string, so it must not collide
    /// with a per-connection token whose UUID stringification happens to be
    /// the same — that's a real worry only if someone refactors the account
    /// computation. Belt-and-braces.
    func testBedrockTokenIsolatedFromPerConnectionTokens() throws {
        try manager.saveBedrockToken("bedrock-secret")
        try manager.saveToken("conn-secret", for: testId)
        XCTAssertEqual(try manager.loadBedrockToken(), "bedrock-secret")
        XCTAssertEqual(try manager.loadToken(for: testId), "conn-secret")
    }

    // MARK: - Error propagation

    /// If the underlying store throws, the manager must surface the error
    /// rather than silently turning it into a nil load. Regression scope:
    /// previous versions caught the throw inside `try?` and returned nil,
    /// which masked unrecoverable keychain state.
    func testLoadPropagatesUnderlyingStoreError() {
        let throwing = ThrowingKeychainStore(error: AuthManagerError.keychainError(status: -25300))
        let mgr = AuthManager(keychain: throwing)
        XCTAssertThrowsError(try mgr.loadToken(for: testId))
        XCTAssertThrowsError(try mgr.loadBedrockToken())
    }

    func testSavePropagatesUnderlyingStoreError() {
        let throwing = ThrowingKeychainStore(error: AuthManagerError.keychainError(status: -25300))
        let mgr = AuthManager(keychain: throwing)
        XCTAssertThrowsError(try mgr.saveToken("x", for: testId))
        XCTAssertThrowsError(try mgr.saveBedrockToken("x"))
    }
}

// MARK: - Test doubles

/// In-memory KeychainStoring used by every AuthManagerTests case. Mimics the
/// real "delete-then-add" upsert flow that AuthManager performs.
final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Key: Data] = [:]

    private struct Key: Hashable {
        let service: String
        let account: String
    }

    func add(service: String, account: String, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        let key = Key(service: service, account: account)
        // Mirror SecItemAdd: refuse to overwrite. AuthManager always deletes
        // first, so a duplicate here is an honest test failure to surface.
        if items[key] != nil {
            throw AuthManagerError.keychainError(status: -25299) // errSecDuplicateItem
        }
        items[key] = data
    }

    func get(service: String, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[Key(service: service, account: account)]
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items.removeValue(forKey: Key(service: service, account: account))
    }
}

/// Always-throws store used to verify the manager's error propagation paths.
private struct ThrowingKeychainStore: KeychainStoring {
    let error: Error

    func add(service: String, account: String, data: Data) throws { throw error }
    func get(service: String, account: String) throws -> Data? { throw error }
    func delete(service: String, account: String) throws { throw error }
}
