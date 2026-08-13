import XCTest
// Module is c99-sanitized from PRODUCT_NAME "Code[Relay]" — see project.yml.
@testable import Code_Relay_

@MainActor
final class AppSettingsBedrockTests: XCTestCase {

    private var defaults: UserDefaults!
    private let legacyKey = AppSettings.legacyBedrockKey

    override func setUp() {
        super.setUp()
        let suite = "AppSettingsBedrockTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    // MARK: - loadBedrockToken

    func testLoadReturnsKeychainValueWhenPresent() {
        let value = AppSettings.loadBedrockToken(
            defaults: defaults,
            legacyKey: legacyKey,
            keychainLoad: { "secret-token" }
        )
        XCTAssertEqual(value, "secret-token")
    }

    func testLoadFallsBackToUserDefaultsWhenKeychainEmpty() {
        defaults.set("legacy-token", forKey: legacyKey)
        let value = AppSettings.loadBedrockToken(
            defaults: defaults,
            legacyKey: legacyKey,
            keychainLoad: { nil }
        )
        XCTAssertEqual(value, "legacy-token")
    }

    func testLoadFallsBackToUserDefaultsWhenKeychainThrows() {
        defaults.set("legacy-token", forKey: legacyKey)
        let value = AppSettings.loadBedrockToken(
            defaults: defaults,
            legacyKey: legacyKey,
            keychainLoad: { throw TestError.keychainUnavailable }
        )
        XCTAssertEqual(value, "legacy-token")
    }

    func testLoadReturnsEmptyStringWhenBothEmpty() {
        let value = AppSettings.loadBedrockToken(
            defaults: defaults,
            legacyKey: legacyKey,
            keychainLoad: { nil }
        )
        XCTAssertEqual(value, "")
    }

    // MARK: - migrateBedrockToken

    func testMigrateNoOpWhenLegacyAbsent() {
        var saved: [String] = []
        AppSettings.migrateBedrockToken(
            defaults: defaults,
            legacyKey: legacyKey,
            keychainLoad: { nil },
            keychainSave: { saved.append($0) }
        )
        XCTAssertTrue(saved.isEmpty)
        XCTAssertNil(defaults.string(forKey: legacyKey))
    }

    func testMigrateScrubsLegacyWhenKeychainAlreadyPopulated() {
        defaults.set("legacy-token", forKey: legacyKey)
        var saved: [String] = []
        AppSettings.migrateBedrockToken(
            defaults: defaults,
            legacyKey: legacyKey,
            keychainLoad: { "existing" },
            keychainSave: { saved.append($0) }
        )
        XCTAssertTrue(saved.isEmpty)
        XCTAssertNil(defaults.string(forKey: legacyKey))
    }

    func testMigrateCopiesAndScrubsOnSuccessfulRoundTrip() {
        defaults.set("legacy-token", forKey: legacyKey)
        var state: String?
        AppSettings.migrateBedrockToken(
            defaults: defaults,
            legacyKey: legacyKey,
            keychainLoad: { state },
            keychainSave: { state = $0 }
        )
        XCTAssertEqual(state, "legacy-token")
        XCTAssertNil(defaults.string(forKey: legacyKey))
    }

    func testMigratePreservesLegacyWhenSaveThrows() {
        defaults.set("legacy-token", forKey: legacyKey)
        AppSettings.migrateBedrockToken(
            defaults: defaults,
            legacyKey: legacyKey,
            keychainLoad: { nil },
            keychainSave: { _ in throw TestError.keychainUnavailable }
        )
        XCTAssertEqual(defaults.string(forKey: legacyKey), "legacy-token")
    }

    func testMigratePreservesLegacyWhenRereadFails() {
        defaults.set("legacy-token", forKey: legacyKey)
        let state: String? = nil
        AppSettings.migrateBedrockToken(
            defaults: defaults,
            legacyKey: legacyKey,
            keychainLoad: { state },
            keychainSave: { _ in /* save but leave state nil */ }
        )
        XCTAssertEqual(defaults.string(forKey: legacyKey), "legacy-token")
    }

    func testLegacyKeyUsesFullyQualifiedMacPrefix() {
        XCTAssertEqual(legacyKey, "com.clauderelay.mac.bedrockBearerToken",
            "Mac uses a namespaced key to avoid collision with iOS defaults.")
    }
}

private enum TestError: Error {
    case keychainUnavailable
}
