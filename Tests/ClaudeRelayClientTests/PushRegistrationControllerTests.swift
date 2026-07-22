import XCTest
@testable import ClaudeRelayClient

final class PushRegistrationControllerTests: XCTestCase {
    func testRegistersWhenEnabledPermittedTokenAndConnected() {
        let action = PushRegistrationController.decide(
            permissionGranted: true, deviceToken: "tok", connected: true,
            pushEnabledSetting: true, notifyOnFinished: true)
        XCTAssertEqual(action, .register(enabled: true, notifyOnFinished: true))
    }

    func testNoopWhenNotConnected() {
        let action = PushRegistrationController.decide(
            permissionGranted: true, deviceToken: "tok", connected: false,
            pushEnabledSetting: true, notifyOnFinished: false)
        XCTAssertEqual(action, .noop)
    }

    func testUnregisterWhenToggledOff() {
        let action = PushRegistrationController.decide(
            permissionGranted: true, deviceToken: "tok", connected: true,
            pushEnabledSetting: false, notifyOnFinished: false)
        XCTAssertEqual(action, .unregister)
    }

    func testUnregisterWhenPermissionRevoked() {
        let action = PushRegistrationController.decide(
            permissionGranted: false, deviceToken: "tok", connected: true,
            pushEnabledSetting: true, notifyOnFinished: false)
        XCTAssertEqual(action, .unregister)
    }

    func testNoopWhenEnabledButNoTokenYet() {
        let action = PushRegistrationController.decide(
            permissionGranted: true, deviceToken: nil, connected: true,
            pushEnabledSetting: true, notifyOnFinished: false)
        XCTAssertEqual(action, .noop)
    }

    func testNotifyOnFinishedPropagates() {
        let action = PushRegistrationController.decide(
            permissionGranted: true, deviceToken: "tok", connected: true,
            pushEnabledSetting: true, notifyOnFinished: false)
        XCTAssertEqual(action, .register(enabled: true, notifyOnFinished: false))
    }
}
