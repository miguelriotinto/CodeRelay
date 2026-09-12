import XCTest
import Foundation
@testable import CodeRelayServer
import CodeRelayKit

final class TokenStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCreateAndValidate() async throws {
        let store = TokenStore(directory: tempDir)
        let (plaintext, created) = try await store.create(label: "test")

        let validated = await store.validate(token: plaintext)
        XCTAssertNotNil(validated)
        XCTAssertEqual(validated?.id, created.id)
        XCTAssertEqual(validated?.label, "test")
    }

    func testValidateRejectsWrongToken() async throws {
        let store = TokenStore(directory: tempDir)
        _ = try await store.create(label: nil)

        let result = await store.validate(token: "bogus")
        XCTAssertNil(result)
    }

    func testList() async throws {
        let store = TokenStore(directory: tempDir)
        _ = try await store.create(label: "a")
        _ = try await store.create(label: "b")

        let all = await store.list()
        XCTAssertEqual(all.count, 2)
    }

    func testDelete() async throws {
        let store = TokenStore(directory: tempDir)
        let (_, info) = try await store.create(label: "del")
        try await store.delete(id: info.id)

        let all = await store.list()
        XCTAssertTrue(all.isEmpty)
    }

    func testRotate() async throws {
        let store = TokenStore(directory: tempDir)
        let (oldPlaintext, oldInfo) = try await store.create(label: "rotate-me")

        let (newPlaintext, newInfo) = try await store.rotate(id: oldInfo.id)

        // Same id and label preserved
        XCTAssertEqual(newInfo.id, oldInfo.id)
        XCTAssertEqual(newInfo.label, oldInfo.label)

        // Old token no longer valid
        let oldResult = await store.validate(token: oldPlaintext)
        XCTAssertNil(oldResult)

        // New token is valid
        let newResult = await store.validate(token: newPlaintext)
        XCTAssertNotNil(newResult)
        XCTAssertEqual(newResult?.id, oldInfo.id)
    }

    func testExpiredTokenRejected() async throws {
        let store = TokenStore(directory: tempDir)
        // Create a token that expired yesterday (expiryDays = 0 won't work, so create manually)
        let (plaintext, _) = try await store.create(label: "expiring", expiryDays: 1)

        // Validate should work before expiry
        let valid = await store.validate(token: plaintext)
        XCTAssertNotNil(valid)

        // Now create a token that's already expired by using a negative-like approach:
        // We'll directly create a TokenInfo with an expiresAt in the past
        let hash = TokenGenerator.hash(plaintext)
        let loaded = await store.list()
        // Manually overwrite with an expired date by creating a fresh store
        let store2 = TokenStore(directory: tempDir)
        let (expiredPlaintext, _) = try await store2.create(label: "already-expired", expiryDays: -1)
        let result = await store2.validate(token: expiredPlaintext)
        XCTAssertNil(result, "Expired token should be rejected")
    }

    func testNonExpiringToken() async throws {
        let store = TokenStore(directory: tempDir)
        let (plaintext, info) = try await store.create(label: "forever", expiryDays: nil)

        XCTAssertNil(info.expiresAt)
        XCTAssertFalse(info.isExpired)

        let validated = await store.validate(token: plaintext)
        XCTAssertNotNil(validated)
    }

    func testExpiryPreservedOnRotate() async throws {
        let store = TokenStore(directory: tempDir)
        let (_, original) = try await store.create(label: "rotate-expiry", expiryDays: 30)

        XCTAssertNotNil(original.expiresAt)

        let (_, rotated) = try await store.rotate(id: original.id)
        XCTAssertEqual(rotated.expiresAt, original.expiresAt)
    }

    func testPersistence() async throws {
        let store1 = TokenStore(directory: tempDir)
        let (plaintext, info) = try await store1.create(label: "persist")

        // Create a completely new store instance pointing at the same directory
        let store2 = TokenStore(directory: tempDir)
        let validated = await store2.validate(token: plaintext)
        XCTAssertNotNil(validated)
        XCTAssertEqual(validated?.id, info.id)
        XCTAssertEqual(validated?.label, "persist")
    }

    func testFlushIfDirtyCancelsPendingFlushTaskSynchronously() async throws {
        // Create, validate to schedule a dirty-flush, then flush and verify
        // the dirty flag is cleared without waiting for the background 30s timer.
        let store = TokenStore(directory: tempDir)
        let (plaintext, _) = try await store.create(label: "task5")
        _ = await store.validate(token: plaintext)
        let dirtyAfterValidate = await store._testOnly_isDirty
        XCTAssertTrue(dirtyAfterValidate,
            "validate() should have scheduled a dirty flush")
        await store.flushIfDirty()
        let dirtyAfterFlush = await store._testOnly_isDirty
        XCTAssertFalse(dirtyAfterFlush,
            "flushIfDirty must clear the dirty flag synchronously, not wait for the 30s timer")
    }

    // MARK: - C-05: save-failure handling

    /// If the disk save fails during `flushIfDirty` (readonly directory, disk full),
    /// the dirty flag must remain set so the next successful write retries the flush.
    /// Silently clearing the flag would strand the unsaved `lastUsedAt` update.
    func testFlushIfDirtyKeepsDirtyFlagOnSaveFailure() async throws {
        let store = TokenStore(directory: tempDir)
        let (plaintext, _) = try await store.create(label: "rofail")

        // Dirty the store via validate (updates lastUsedAt in-memory).
        _ = await store.validate(token: plaintext)
        let dirtyBefore = await store._testOnly_isDirty
        XCTAssertTrue(dirtyBefore)

        // Make the directory read-only so the atomic tempfile-rename inside
        // `Data.write(to:options:.atomic)` fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tempDir.path)
        defer {
            // Restore so tearDown can remove the directory.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)
        }

        await store.flushIfDirty()

        let dirtyAfter = await store._testOnly_isDirty
        XCTAssertTrue(dirtyAfter,
            "flushIfDirty must keep the dirty flag set when the disk save fails")
    }

    /// Even if `create` cannot persist (readonly directory), the in-memory
    /// cache must remain consistent with the disk state — callers who see
    /// the error must not observe a cache that "already has" the new token.
    func testCreateTokenFailureDoesNotCorruptCache() async throws {
        let store = TokenStore(directory: tempDir)
        _ = try await store.create(label: "first")
        let countBefore = await store.list().count
        XCTAssertEqual(countBefore, 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tempDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)
        }

        do {
            _ = try await store.create(label: "second")
            XCTFail("Expected create to throw when the directory is read-only")
        } catch {
            // expected
        }

        let countAfter = await store.list().count
        XCTAssertEqual(countAfter, 1,
            "Failed create must not leak into the in-memory cache")
    }

    // MARK: - Rename

    func testRenameExistingToken() async throws {
        let store = TokenStore(directory: tempDir)
        let (_, info) = try await store.create(label: "original")

        let renamed = try await store.rename(id: info.id, label: "updated")
        XCTAssertEqual(renamed.id, info.id)
        XCTAssertEqual(renamed.label, "updated")

        let listed = await store.list()
        XCTAssertEqual(listed.first?.label, "updated")
    }

    func testRenameNonExistentTokenThrows() async throws {
        let store = TokenStore(directory: tempDir)
        do {
            _ = try await store.rename(id: "nonexistent", label: "x")
            XCTFail("Expected tokenNotFound error")
        } catch let error as TokenStore.TokenStoreError {
            if case .tokenNotFound(let id) = error {
                XCTAssertEqual(id, "nonexistent")
            } else {
                XCTFail("Wrong error case: \(error)")
            }
        }
    }

    func testRenamePersistsAcrossInstances() async throws {
        let store1 = TokenStore(directory: tempDir)
        let (_, info) = try await store1.create(label: "before")
        _ = try await store1.rename(id: info.id, label: "after")

        let store2 = TokenStore(directory: tempDir)
        let listed = await store2.list()
        XCTAssertEqual(listed.first?.label, "after")
    }

    // MARK: - Inspect

    func testInspectExistingToken() async throws {
        let store = TokenStore(directory: tempDir)
        let (_, created) = try await store.create(label: "inspectable")

        let inspected = try await store.inspect(id: created.id)
        XCTAssertEqual(inspected.id, created.id)
        XCTAssertEqual(inspected.label, "inspectable")
        XCTAssertEqual(inspected.tokenHash, created.tokenHash)
    }

    func testInspectNonExistentTokenThrows() async throws {
        let store = TokenStore(directory: tempDir)
        do {
            _ = try await store.inspect(id: "ghost")
            XCTFail("Expected tokenNotFound error")
        } catch let error as TokenStore.TokenStoreError {
            if case .tokenNotFound(let id) = error {
                XCTAssertEqual(id, "ghost")
            } else {
                XCTFail("Wrong error case: \(error)")
            }
        }
    }
}
