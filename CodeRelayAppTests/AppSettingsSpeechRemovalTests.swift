import XCTest
@testable import CodeRelayApp

/// The iOS wiring of the shared `SpeechRemovalMigration` (spec §7.2 / §11):
/// the right legacy keys, the right done flag, and the Bedrock secret gone
/// after one launch. The helper's own edge cases are covered in
/// `SpeechRemovalMigrationTests` (CodeRelayClientTests).
@MainActor
final class AppSettingsSpeechRemovalTests: XCTestCase {

    private var defaults: UserDefaults!
    private var modelsDir: URL!

    override func setUp() {
        super.setUp()
        let suite = "AppSettingsSpeechRemovalTests.\(UUID().uuidString)"
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

    func testLegacyKeyListCoversEveryOldIOSSetting() {
        XCTAssertEqual(
            Set(AppSettings.legacySpeechDefaultsKeys),
            ["smartCleanupEnabled", "promptEnhancementEnabled", "bedrockRegion", "bedrockBearerToken",
             "continuousListeningEnabled", "wakeWord", "speechModelStore.whisperDownloaded"]
        )
        XCTAssertEqual(AppSettings.speechRemovalMigrationKey, "speechRemovalMigrationDone")
        XCTAssertEqual(AppSettings.legacySpeechModelsDirectory.lastPathComponent, "Models")
    }

    func testOneLaunchScrubsOldKeysDirectoryAndBedrockSecret() throws {
        for key in AppSettings.legacySpeechDefaultsKeys { defaults.set("x", forKey: key) }
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        var deleteCalls = 0

        let ok = AppSettings.migrateSpeechRemoval(
            defaults: defaults, modelsDirectory: modelsDir, deleteBedrockToken: { deleteCalls += 1 }
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(deleteCalls, 1)
        for key in AppSettings.legacySpeechDefaultsKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsDir.path))
        XCTAssertTrue(defaults.bool(forKey: AppSettings.speechRemovalMigrationKey))
        XCTAssertFalse(AppSettings.migrateSpeechRemoval(defaults: defaults, modelsDirectory: modelsDir, deleteBedrockToken: { deleteCalls += 1 }))
        XCTAssertEqual(deleteCalls, 1, "second launch is a no-op")
    }
}
