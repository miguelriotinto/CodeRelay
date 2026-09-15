import XCTest
@testable import CodeRelayClient

/// The shared one-time cleanup both apps run after voice transcription was
/// removed (spec §7.2 / §11): legacy defaults gone, model directory gone,
/// Bedrock secret gone, and the done-flag set only when all of that succeeded.
final class SpeechRemovalMigrationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var modelsDir: URL!
    private let doneKey = "test.speechRemovalMigrationDone"
    private let legacyKeys = ["a.legacy", "b.legacy", "c.whisperDownloaded"]

    override func setUp() {
        super.setUp()
        let suite = "SpeechRemovalMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        modelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRemoval-\(UUID().uuidString)/Models", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: modelsDir.deletingLastPathComponent())
        defaults = nil
        super.tearDown()
    }

    private func seedLegacyState() throws {
        for key in legacyKeys { defaults.set("x", forKey: key) }
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: modelsDir.appendingPathComponent("qwen35-0.8b-q4km.gguf"))
    }

    private func run(delete: () throws -> Void = {}) -> Bool {
        SpeechRemovalMigration.run(
            defaults: defaults, doneKey: doneKey, legacyKeys: legacyKeys,
            modelsDirectory: modelsDir, deleteBedrockToken: delete
        )
    }

    func testRemovesKeysDirectoryAndSecretThenMarksDone() throws {
        try seedLegacyState()
        var deleteCalls = 0
        XCTAssertTrue(run(delete: { deleteCalls += 1 }))
        XCTAssertEqual(deleteCalls, 1)
        for key in legacyKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsDir.path))
        XCTAssertTrue(defaults.bool(forKey: doneKey))
    }

    func testIsOneShot() throws {
        try seedLegacyState()
        var deleteCalls = 0
        _ = run(delete: { deleteCalls += 1 })
        defaults.set("again", forKey: "a.legacy")
        XCTAssertFalse(run(delete: { deleteCalls += 1 }), "already done → false")
        XCTAssertEqual(deleteCalls, 1)
        XCTAssertEqual(defaults.string(forKey: "a.legacy"), "again")
    }

    func testMissingModelDirectoryIsNotAFailure() {
        XCTAssertTrue(run())
        XCTAssertTrue(defaults.bool(forKey: doneKey))
    }

    func testKeychainFailureLeavesFlagUnsetSoItRetries() throws {
        try seedLegacyState()
        struct Boom: Error {}
        XCTAssertFalse(run(delete: { throw Boom() }))
        XCTAssertFalse(defaults.bool(forKey: doneKey))
        XCTAssertNil(defaults.object(forKey: "a.legacy"), "defaults are still scrubbed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsDir.path), "directory is still deleted")
    }

    func testRetryAfterFailureCompletes() throws {
        try seedLegacyState()
        struct Boom: Error {}
        _ = run(delete: { throw Boom() })
        XCTAssertTrue(run())
        XCTAssertTrue(defaults.bool(forKey: doneKey))
    }
}
