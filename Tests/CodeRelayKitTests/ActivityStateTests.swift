import XCTest
@testable import CodeRelayKit

final class ActivityStateTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    func testAllCasesRoundTrip() throws {
        let cases: [ActivityState] = [.active, .idle, .agentActive, .agentIdle]
        for state in cases {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(ActivityState.self, from: data)
            XCTAssertEqual(state, decoded, "Round-trip failed for \(state)")
        }
    }

    func testRawValues() {
        XCTAssertEqual(ActivityState.active.rawValue, "active")
        XCTAssertEqual(ActivityState.idle.rawValue, "idle")
        XCTAssertEqual(ActivityState.agentActive.rawValue, "agent_active")
        XCTAssertEqual(ActivityState.agentIdle.rawValue, "agent_idle")
    }

    func testDecodesFromJSON() throws {
        let json = #""agent_idle""#
        let decoded = try decoder.decode(ActivityState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .agentIdle)
    }

    /// Backward compatibility: old servers/clients encoded "claude_active"/"claude_idle".
    /// A new client must still decode those values to the new cases.
    func testBackwardCompatDecodesLegacyClaudeValues() throws {
        let legacyActive = #""claude_active""#
        let legacyIdle = #""claude_idle""#
        XCTAssertEqual(try decoder.decode(ActivityState.self, from: Data(legacyActive.utf8)), .agentActive)
        XCTAssertEqual(try decoder.decode(ActivityState.self, from: Data(legacyIdle.utf8)), .agentIdle)
    }

    func testEquatable() {
        XCTAssertEqual(ActivityState.active, ActivityState.active)
        XCTAssertNotEqual(ActivityState.active, ActivityState.idle)
        XCTAssertNotEqual(ActivityState.agentActive, ActivityState.agentIdle)
    }

    func testIsAgentRunning() {
        XCTAssertFalse(ActivityState.active.isAgentRunning)
        XCTAssertFalse(ActivityState.idle.isAgentRunning)
        XCTAssertTrue(ActivityState.agentActive.isAgentRunning)
        XCTAssertTrue(ActivityState.agentIdle.isAgentRunning)
    }

    func testIsAwaitingInput() {
        XCTAssertFalse(ActivityState.active.isAwaitingInput)
        XCTAssertTrue(ActivityState.idle.isAwaitingInput)
        XCTAssertFalse(ActivityState.agentActive.isAwaitingInput)
        XCTAssertTrue(ActivityState.agentIdle.isAwaitingInput)
    }
}
