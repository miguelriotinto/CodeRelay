import XCTest
// Module is c99-sanitized from PRODUCT_NAME "Code[Relay]" — see project.yml.
@testable import Code_Relay_

/// The macOS wiring of the shared `SpeechRemovalMigration` (spec §7.2 / §11).
/// The helper's edge cases are covered in `SpeechRemovalMigrationTests`
/// (CodeRelayClientTests).
@MainActor
final class AppSettingsSpeechRemovalTests: XCTestCase {

    private var defaults: UserDefaults!
    private var sandbox: URL!
    private var modelsDir: URL!
    /// Stands in for WhisperKit's `Documents/huggingface` download base.
    private var hubDir: URL!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsSpeechRemovalTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRemoval-\(UUID().uuidString)", isDirectory: true)
        modelsDir = sandbox.appendingPathComponent("ClaudeRelay/Models", isDirectory: true)
        hubDir = sandbox.appendingPathComponent("huggingface", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sandbox)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testLegacyKeyListCoversEveryOldMacSetting() {
        XCTAssertEqual(
            Set(AppSettings.legacySpeechDefaultsKeys),
            ["com.clauderelay.mac.smartCleanupEnabled", "com.clauderelay.mac.promptEnhancementEnabled",
             "com.clauderelay.mac.continuousListeningEnabled", "com.clauderelay.mac.wakeWord",
             "com.clauderelay.mac.bedrockRegion", "com.clauderelay.mac.bedrockBearerToken",
             "com.clauderelay.mac.whisperDownloaded"]
        )
        XCTAssertEqual(AppSettings.speechRemovalMigrationKey, "com.clauderelay.mac.speechRemovalMigrationDone")
        XCTAssertEqual(
            Array(AppSettings.legacySpeechModelsDirectory.pathComponents.suffix(2)),
            ["ClaudeRelay", "Models"]
        )
    }

    /// Both model homes must be scrubbed: the LLM weights under Application
    /// Support, and the Whisper CoreML weights WhisperKit put in
    /// `Documents/huggingface` (it was called with no `downloadBase`).
    func testLegacyDirectoriesCoverBothModelHomes() {
        let directories = AppSettings.legacySpeechDirectories
        XCTAssertEqual(directories.count, 2)
        XCTAssertEqual(directories.first, AppSettings.legacySpeechModelsDirectory)
        XCTAssertEqual(directories.last, AppSettings.legacyWhisperHubDirectory)
        XCTAssertEqual(AppSettings.legacyWhisperHubDirectory.lastPathComponent, "huggingface")
        XCTAssertEqual(
            AppSettings.legacyWhisperHubDirectory.deletingLastPathComponent().standardizedFileURL,
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        )
    }

    func testOneLaunchScrubsOldKeysDirectoriesAndBedrockSecret() throws {
        for key in AppSettings.legacySpeechDefaultsKeys { defaults.set("x", forKey: key) }
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hubDir, withIntermediateDirectories: true)
        try Data("coreml".utf8).write(to: hubDir.appendingPathComponent("openai_whisper-small.en"))
        var deleteCalls = 0

        let ok = AppSettings.migrateSpeechRemoval(
            defaults: defaults, directories: [modelsDir, hubDir], deleteBedrockToken: { deleteCalls += 1 }
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(deleteCalls, 1)
        for key in AppSettings.legacySpeechDefaultsKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hubDir.path), "Whisper weights must go too")
        XCTAssertTrue(defaults.bool(forKey: AppSettings.speechRemovalMigrationKey))
        XCTAssertFalse(AppSettings.migrateSpeechRemoval(
            defaults: defaults, directories: [modelsDir, hubDir], deleteBedrockToken: { deleteCalls += 1 }
        ))
        XCTAssertEqual(deleteCalls, 1, "second launch is a no-op")
    }

    /// An install that only ever downloaded one of the two models still
    /// completes: a missing directory is not a failure.
    func testOneAbsentDirectoryStillMarksTheMigrationDone() throws {
        try FileManager.default.createDirectory(at: hubDir, withIntermediateDirectories: true)

        let ok = AppSettings.migrateSpeechRemoval(
            defaults: defaults, directories: [modelsDir, hubDir], deleteBedrockToken: {}
        )

        XCTAssertTrue(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hubDir.path))
        XCTAssertTrue(defaults.bool(forKey: AppSettings.speechRemovalMigrationKey))
    }
}
