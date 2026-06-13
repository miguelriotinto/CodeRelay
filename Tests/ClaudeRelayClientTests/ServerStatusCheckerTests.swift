import XCTest
@testable import ClaudeRelayClient

@MainActor
final class ServerStatusCheckerTests: XCTestCase {

    func testDefaultStatusIsUnknownAndNotLive() {
        let status = ServerStatus()
        XCTAssertFalse(status.isLive)
        XCTAssertEqual(status.reachability, .unknown)
    }

    func testLiveStatusReportsLiveReachability() {
        let status = ServerStatus(isLive: true, reachability: .live)
        XCTAssertTrue(status.isLive)
        XCTAssertEqual(status.reachability, .live)
    }

    func testInvalidTokenStatusIsNotLive() {
        let status = ServerStatus(isLive: false, reachability: .invalidToken)
        XCTAssertFalse(status.isLive)
        XCTAssertEqual(status.reachability, .invalidToken)
    }

    func testMapInvalidTokenError() {
        let err = SessionController.SessionError.authenticationFailed(reason: "Invalid token")
        let status = ServerStatusChecker.statusForProbeFailure(err)
        XCTAssertFalse(status.isLive)
        XCTAssertEqual(status.reachability, .invalidToken)
    }

    func testMapTimeoutErrorIsUnreachable() {
        let err = SessionController.SessionError.timeout
        let status = ServerStatusChecker.statusForProbeFailure(err)
        XCTAssertFalse(status.isLive)
        XCTAssertEqual(status.reachability, .unreachable)
    }
}
