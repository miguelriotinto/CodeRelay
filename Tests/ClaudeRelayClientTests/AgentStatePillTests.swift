import XCTest
import SwiftUI
@testable import ClaudeRelayClient
import ClaudeRelayKit

final class AgentStatePillTests: XCTestCase {
    func testWords() {
        XCTAssertEqual(AgentStatePillModel.word(.idle), "Waiting")
        XCTAssertEqual(AgentStatePillModel.word(.working), "Working")
        XCTAssertEqual(AgentStatePillModel.word(.blocked), "Blocked")
        XCTAssertEqual(AgentStatePillModel.word(.unknown), "Unknown")
    }
    func testBlockedIsRed() {
        XCTAssertEqual(AgentStatePillModel.color(.blocked, agentId: "claude", seen: true), Color.red)
    }
    func testWorkingUsesAgentPalette() {
        XCTAssertEqual(
            AgentStatePillModel.color(.working, agentId: "claude", seen: true),
            AgentColorPalette.color(for: "claude")
        )
    }
    func testWaitingSeenIsGreenUnseenIsTeal() {
        XCTAssertEqual(AgentStatePillModel.color(.idle, agentId: "claude", seen: true), Color.green)
        XCTAssertEqual(AgentStatePillModel.color(.idle, agentId: "claude", seen: false), Color.teal)
    }
}
