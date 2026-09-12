import XCTest
@testable import CodeRelayApp

@MainActor
final class AppSettingsContinuousTests: XCTestCase {

    func testContinuousListeningDefaultsToFalse() {
        UserDefaults.standard.removeObject(forKey: "continuousListeningEnabled")
        XCTAssertFalse(AppSettings.shared.continuousListeningEnabled)
    }

    func testWakeWordDefaultsToClaude() {
        UserDefaults.standard.removeObject(forKey: "wakeWord")
        XCTAssertEqual(AppSettings.shared.wakeWord, "claude")
    }
}
