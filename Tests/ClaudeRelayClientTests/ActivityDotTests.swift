import XCTest
import SwiftUI
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

final class ActivityDotTests: XCTestCase {

    func testEquatableIncludesAgentStateAndSeen() {
        let a = ActivityDot(activity: .agentIdle, agentId: "claude", agentState: .blocked, seen: false)
        let b = ActivityDot(activity: .agentIdle, agentId: "claude", agentState: .blocked, seen: false)
        let c = ActivityDot(activity: .agentIdle, agentId: "claude", agentState: .idle, seen: false)
        let d = ActivityDot(activity: .agentIdle, agentId: "claude", agentState: .blocked, seen: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c, "different agentState must not be equal")
        XCTAssertNotEqual(a, d, "different seen must not be equal")
    }

    func testDefaultsPreserveLegacyConstruction() {
        // The existing 3-arg call site must still compile and be seen/nil.
        let dot = ActivityDot(activity: .agentActive, agentId: "codex")
        XCTAssertNil(dot.agentState)
        XCTAssertTrue(dot.seen)
    }
}
