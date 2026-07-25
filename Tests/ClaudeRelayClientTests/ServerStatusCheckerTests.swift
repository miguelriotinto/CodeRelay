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

    // MARK: - Poll lifecycle (regression for the macOS reconnect storm)

    func testStartThenStopPollingClearsTheLoop() {
        let checker = ServerStatusChecker(interval: 5)
        let config = ConnectionConfig(name: "s", host: "127.0.0.1", port: 9200)
        checker.startPolling(connections: [config])
        XCTAssertTrue(checker._testOnly_isPolling, "startPolling should install a poll loop")
        checker.stopPolling()
        XCTAssertFalse(checker._testOnly_isPolling, "stopPolling must clear the loop")
    }

    func testStartPollingWithNoConnectionsDoesNotLoop() {
        let checker = ServerStatusChecker(interval: 5)
        checker.startPolling(connections: [])
        XCTAssertFalse(checker._testOnly_isPolling,
                       "an empty server list must not start a forever-probing loop")
    }
}
