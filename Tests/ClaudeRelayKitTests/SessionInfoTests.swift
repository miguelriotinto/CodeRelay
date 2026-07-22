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

    func testWorkingDirRoundTrips() throws {
        let info = SessionInfo(id: UUID(), name: "s", state: .activeAttached, tokenId: "t",
                               createdAt: Date(timeIntervalSince1970: 1), cols: 80, rows: 24,
                               workingDir: "/repo/x")
        let back = try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(back.workingDir, "/repo/x")
    }

    func testWorkingDirDefaultsNilAndAbsentKeyDecodesNil() throws {
        XCTAssertNil(base().workingDir)
        let json = #"{"id":"\#(UUID().uuidString)","state":"active-attached","tokenId":"t","createdAt":1,"cols":80,"rows":24}"#
        let decoded = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
        XCTAssertNil(decoded.workingDir)
    }

    func testWorkingDirPreservedByCopyHelpersAndEnriched() {
        let info = SessionInfo(id: UUID(), name: "s", state: .activeAttached, tokenId: "t",
                               createdAt: Date(), cols: 80, rows: 24, workingDir: "/repo/y")
        XCTAssertEqual(info.transitioning(to: .activeDetached).workingDir, "/repo/y")
        XCTAssertEqual(info.with(name: "r").workingDir, "/repo/y")
        XCTAssertEqual(info.with(tokenId: "t2").workingDir, "/repo/y")
        // enriched without workingDir preserves the existing value
        XCTAssertEqual(info.enriched(activity: .active, agent: nil).workingDir, "/repo/y")
        // enriched with a new workingDir overrides
        XCTAssertEqual(info.enriched(activity: .active, agent: nil, workingDir: "/repo/z").workingDir, "/repo/z")
    }
}
