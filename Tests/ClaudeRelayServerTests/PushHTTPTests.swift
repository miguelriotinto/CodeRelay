import XCTest
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class PushHTTPTests: XCTestCase {
    func testRedactStripsBearerToken() {
        let input = "request failed authorization: bearer eyJhbGciOi.J9.abc-DEF_123 more text"
        let out = PushHTTP.redact(input)
        XCTAssertFalse(out.contains("eyJhbGciOi"), "token must be redacted")
        XCTAssertTrue(out.contains("bearer <redacted>"))
        XCTAssertTrue(out.contains("more text"), "surrounding text preserved")
    }

    func testRedactIsCaseInsensitive() {
        XCTAssertEqual(PushHTTP.redact("Bearer SECRET"), "bearer <redacted>")
    }

    func testRedactLeavesNonBearerUntouched() {
        XCTAssertEqual(PushHTTP.redact("plain error"), "plain error")
    }
}

// MARK: - CompositePushSender routing

private actor RecordingSender: PushSending {
    let label: String
    private(set) var calls = 0
    init(_ label: String) { self.label = label }
    func send(deviceToken: String, platform: PushPlatform, topic: String?, title: String,
              body: String, deepLink: String, collapseKey: String) async -> PushResult {
        calls += 1
        return .delivered
    }
    func callCount() -> Int { calls }
}

final class CompositePushSenderTests: XCTestCase {
    func testRoutesByPlatform() async {
        let apns = RecordingSender("apns")
        let fcm = RecordingSender("fcm")
        let composite = CompositePushSender(apns: apns, fcm: fcm)

        _ = await composite.send(deviceToken: "t", platform: .apns, topic: nil, title: "x", body: "y",
                                 deepLink: "z", collapseKey: "k")
        _ = await composite.send(deviceToken: "t", platform: .fcm, topic: nil, title: "x", body: "y",
                                 deepLink: "z", collapseKey: "k")

        let apnsCalls = await apns.callCount()
        let fcmCalls = await fcm.callCount()
        XCTAssertEqual(apnsCalls, 1)
        XCTAssertEqual(fcmCalls, 1)
    }

    func testMissingProviderFailsGracefully() async {
        let composite = CompositePushSender(apns: nil, fcm: nil)
        let result = await composite.send(deviceToken: "t", platform: .apns, topic: nil, title: "x", body: "y",
                                          deepLink: "z", collapseKey: "k")
        XCTAssertEqual(result, .failed("no sender configured for apns"))
    }
}
