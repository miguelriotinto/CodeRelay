import XCTest
// Module is c99-sanitized from PRODUCT_NAME "Code[Relay]" — see project.yml.
@testable import Code_Relay_

/// The macOS wiring of the shared `SpeechRemovalMigration` (spec §7.2 / §11).
/// The helper's edge cases are covered in `SpeechRemovalMigrationTests`
/// (CodeRelayClientTests).
@MainActor
final class AppSettingsSpeechRemovalTests: XCTestCase {

    private var defaults: UserDefaults!
    private var modelsDir: URL!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsSpeechRemovalTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        modelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRemoval-\(UUID().uuidString)/ClaudeRelay/Models", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: modelsDir.deletingLastPathComponent().deletingLastPathComponent())
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
