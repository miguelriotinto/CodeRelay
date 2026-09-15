import XCTest
@testable import CodeRelayClient

/// The shared one-time cleanup both apps run after voice transcription was
/// removed (spec §7.2 / §11): legacy defaults gone, model directory gone,
/// Bedrock secret gone, and the done-flag set only when all of that succeeded.
final class SpeechRemovalMigrationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var sandbox: URL!
    private var modelsDir: URL!
    /// Stands in for WhisperKit's `Documents/huggingface` default.
    private var hubDir: URL!
    private let doneKey = "test.speechRemovalMigrationDone"
    private let legacyKeys = ["a.legacy", "b.legacy", "c.whisperDownloaded"]

    override func setUp() {
        super.setUp()
        let suite = "SpeechRemovalMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRemoval-\(UUID().uuidString)", isDirectory: true)
        modelsDir = sandbox.appendingPathComponent("Models", isDirectory: true)
        hubDir = sandbox.appendingPathComponent("huggingface", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sandbox)
        defaults = nil
        super.tearDown()
    }

    private func seedLegacyState() throws {
        for key in legacyKeys { defaults.set("x", forKey: key) }
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: modelsDir.appendingPathComponent("qwen35-0.8b-q4km.gguf"))
    }

    private func run(directories: [URL]? = nil, delete: () throws -> Void = {}) -> Bool {
        SpeechRemovalMigration.run(
            defaults: defaults, doneKey: doneKey, legacyKeys: legacyKeys,
            directories: directories ?? [modelsDir], deleteBedrockToken: delete
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

    /// The two model families lived in different places (LLM weights in the
    /// store's own directory, Whisper's CoreML weights under WhisperKit's
    /// `Documents/huggingface` default), so every directory has to be removed —
    /// and one of them being absent must still mark the migration done.
    func testRemovesEveryDirectoryAndToleratesAnAbsentOne() throws {
        try seedLegacyState()
        try FileManager.default.createDirectory(at: hubDir, withIntermediateDirectories: true)
        try Data("coreml".utf8).write(to: hubDir.appendingPathComponent("openai_whisper-small.en"))
        let absent = sandbox.appendingPathComponent("never-existed", isDirectory: true)

        XCTAssertTrue(run(directories: [modelsDir, hubDir, absent]))

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hubDir.path))
        XCTAssertTrue(defaults.bool(forKey: doneKey), "an absent directory is not a failure")
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
