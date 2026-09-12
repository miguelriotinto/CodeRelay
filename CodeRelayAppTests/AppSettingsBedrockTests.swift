import XCTest
@testable import CodeRelayApp

/// Exercises the pure migration + fallback helpers on `AppSettings`. The
/// Keychain round-trip is simulated via closures so tests don't depend on the
/// real `AuthManager` or the shared `UserDefaults` — the live debounce
/// pipeline is covered by SwiftUI smoke-testing on-device.
@MainActor
final class AppSettingsBedrockTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Each test gets its own in-memory suite so the shared
        // `UserDefaults.standard` is never touched.
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
            keychainLoad: { "secret-token" }
        )
        XCTAssertEqual(value, "secret-token")
    }

    func testLoadFallsBackToUserDefaultsWhenKeychainEmpty() {
        defaults.set("legacy-token", forKey: AppSettings.legacyBedrockKey)
        let value = AppSettings.loadBedrockToken(
            defaults: defaults,
            keychainLoad: { nil }
        )
        XCTAssertEqual(value, "legacy-token",
            "When the Keychain is empty, loadBedrockToken must surface the legacy plist copy.")
    }

    func testLoadFallsBackToUserDefaultsWhenKeychainThrows() {
        defaults.set("legacy-token", forKey: AppSettings.legacyBedrockKey)
        let value = AppSettings.loadBedrockToken(
            defaults: defaults,
            keychainLoad: { throw TestError.keychainUnavailable }
        )
        XCTAssertEqual(value, "legacy-token",
            "Keychain failures must not vanish the user's token — legacy value stays visible.")
    }

    func testLoadReturnsEmptyStringWhenBothEmpty() {
        let value = AppSettings.loadBedrockToken(
            defaults: defaults,
            keychainLoad: { nil }
        )
        XCTAssertEqual(value, "")
    }

    // MARK: - migrateBedrockToken

    func testMigrateNoOpWhenLegacyAbsent() {
        var savedTokens: [String] = []
        AppSettings.migrateBedrockToken(
            defaults: defaults,
            keychainLoad: { nil },
            keychainSave: { savedTokens.append($0) }
        )
        XCTAssertTrue(savedTokens.isEmpty)
        XCTAssertNil(defaults.string(forKey: AppSettings.legacyBedrockKey))
    }

    func testMigrateScrubsLegacyWhenKeychainAlreadyPopulated() {
        defaults.set("legacy-token", forKey: AppSettings.legacyBedrockKey)
        var savedTokens: [String] = []
        AppSettings.migrateBedrockToken(
            defaults: defaults,
            keychainLoad: { "existing-keychain-token" },
            keychainSave: { savedTokens.append($0) }
        )
        XCTAssertTrue(savedTokens.isEmpty,
            "Must not overwrite an existing Keychain value.")
        XCTAssertNil(defaults.string(forKey: AppSettings.legacyBedrockKey),
            "Legacy plist copy must be scrubbed once the Keychain is known good.")
    }

    func testMigrateConfirmsSaveBeforeScrubbingLegacy() {
        defaults.set("legacy-token", forKey: AppSettings.legacyBedrockKey)
        // Simulate a Keychain save that succeeds but re-read returns nothing
        // (partial failure, device state, etc.). Legacy must remain.
        var keychainState: String?
        AppSettings.migrateBedrockToken(
            defaults: defaults,
            keychainLoad: { keychainState },
            keychainSave: { _ in /* save but leave keychainState nil */ }
        )
        XCTAssertEqual(defaults.string(forKey: AppSettings.legacyBedrockKey), "legacy-token",
            "Legacy plist copy must be preserved when the Keychain re-read doesn't confirm the save.")
    }

    func testMigrateCopiesValueWhenSaveSucceeds() {
        defaults.set("legacy-token", forKey: AppSettings.legacyBedrockKey)
        var keychainState: String?
        AppSettings.migrateBedrockToken(
            defaults: defaults,
            keychainLoad: { keychainState },
            keychainSave: { keychainState = $0 }
        )
        XCTAssertEqual(keychainState, "legacy-token",
            "Value must land in the Keychain.")
        XCTAssertNil(defaults.string(forKey: AppSettings.legacyBedrockKey),
            "Legacy plist copy must be scrubbed once Keychain round-trip confirms.")
    }

    func testMigratePreservesLegacyWhenSaveThrows() {
        defaults.set("legacy-token", forKey: AppSettings.legacyBedrockKey)
        AppSettings.migrateBedrockToken(
            defaults: defaults,
            keychainLoad: { nil },
            keychainSave: { _ in throw TestError.keychainUnavailable }
        )
        XCTAssertEqual(defaults.string(forKey: AppSettings.legacyBedrockKey), "legacy-token",
            "A Keychain save failure must leave the legacy plist copy intact.")
    }
}

private enum TestError: Error {
    case keychainUnavailable
}
