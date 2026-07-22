import XCTest
@testable import ClaudeRelayClient
import ClaudeRelayKit

final class SessionStatusDotTests: XCTestCase {
    func testAttachedIsGreen() {
        XCTAssertEqual(SessionStatusColor.bucket(.activeAttached), .green)
    }
    func testDetachedIsYellow() {
        XCTAssertEqual(SessionStatusColor.bucket(.activeDetached), .yellow)
    }
    func testTransitionalIsYellow() {
        XCTAssertEqual(SessionStatusColor.bucket(.starting), .yellow)
        XCTAssertEqual(SessionStatusColor.bucket(.resuming), .yellow)
        XCTAssertEqual(SessionStatusColor.bucket(.created), .yellow)
    }
    func testTerminalIsNone() {
        XCTAssertEqual(SessionStatusColor.bucket(.exited), SessionStatusColor.none)
        XCTAssertEqual(SessionStatusColor.bucket(.failed), SessionStatusColor.none)
    }
}
