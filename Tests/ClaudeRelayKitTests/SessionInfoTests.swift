import XCTest
@testable import ClaudeRelayKit

final class SessionInfoTests: XCTestCase {

    private func base() -> SessionInfo {
        SessionInfo(id: UUID(), name: "s", state: .activeAttached, tokenId: "t",
                    createdAt: Date(), cols: 80, rows: 24)
    }

    func testDefaultsAreNil() {
        let info = base()
        XCTAssertNil(info.agentState)
        XCTAssertNil(info.title)
    }

    func testEnrichedCarriesAgentStateAndTitle() {
        let info = base().enriched(activity: .agentIdle, agent: "claude",
                                   agentState: .blocked, title: "✳ proj")
        XCTAssertEqual(info.activity, .agentIdle)
        XCTAssertEqual(info.agent, "claude")
        XCTAssertEqual(info.agentState, .blocked)
        XCTAssertEqual(info.title, "✳ proj")
    }

    func testCopyHelpersPreserveAgentStateAndTitle() {
        let info = SessionInfo(id: UUID(), name: "s", state: .activeAttached, tokenId: "t",
                               createdAt: Date(), cols: 80, rows: 24,
                               activity: .agentActive, agent: "codex",
                               agentState: .working, title: "⠙ x")
        XCTAssertEqual(info.transitioning(to: .activeDetached).agentState, .working)
        XCTAssertEqual(info.transitioning(to: .activeDetached).title, "⠙ x")
        XCTAssertEqual(info.with(name: "renamed").agentState, .working)
        XCTAssertEqual(info.with(tokenId: "t2").title, "⠙ x")
    }

    func testCodableRoundTripWithNewFields() throws {
        let info = base().enriched(activity: .agentIdle, agent: "claude",
                                   agentState: .idle, title: "t")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(SessionInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }
}
