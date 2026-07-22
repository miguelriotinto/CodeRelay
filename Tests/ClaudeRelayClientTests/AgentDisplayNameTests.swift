import XCTest
@testable import ClaudeRelayClient
import ClaudeRelayKit

final class AgentDisplayNameTests: XCTestCase {
    func testNilForNoAgent() {
        XCTAssertNil(AgentDisplayName.friendly(nil))
    }
    func testClaude() {
        XCTAssertEqual(AgentDisplayName.friendly("claude"), "Claude Code")
    }
    func testCodex() {
        XCTAssertEqual(AgentDisplayName.friendly("codex"), "Codex")
    }
    func testOpencodeIsTwoWords() {
        XCTAssertEqual(AgentDisplayName.friendly("opencode"), "Open Code")
    }
    func testUnknownIdFallsBackToRawId() {
        XCTAssertEqual(AgentDisplayName.friendly("mystery"), "mystery")
    }
}
