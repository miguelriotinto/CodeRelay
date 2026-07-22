import XCTest
@testable import ClaudeRelayKit

final class WorkspaceRollupTests: XCTestCase {
    private func session(_ agent: String?, _ state: AgentDetectedState?, dir: String,
                         id: UUID = UUID()) -> SessionInfo {
        SessionInfo(id: id, name: nil, state: .activeAttached, tokenId: "t", createdAt: Date(),
                    cols: 80, rows: 24, activity: .agentActive, agent: agent,
                    agentState: state, title: nil, workingDir: dir)
    }

    func testRollupStateBlockedIsHighest() {
        XCTAssertEqual(WorkspaceRollup.rollupState(for: session("claude", .blocked, dir: "/r"), unseen: []), .blocked)
    }

    func testFinishedUnseenVsSeen() {
        let s = session("claude", .idle, dir: "/r")
        XCTAssertEqual(WorkspaceRollup.rollupState(for: s, unseen: [s.id]), .finishedUnseen)
        XCTAssertEqual(WorkspaceRollup.rollupState(for: s, unseen: []), .seen)
    }

    func testNoAgentIsSeen() {
        XCTAssertEqual(WorkspaceRollup.rollupState(for: session(nil, nil, dir: "/r"), unseen: []), .seen)
    }

    func testGroupPicksWorstAndSortsBySeverity() {
        let a = session("claude", .working, dir: "/repo/a")
        let b = session("claude", .blocked, dir: "/repo/a")
        let c = session("codex", .idle, dir: "/repo/b")
        let groups = WorkspaceRollup.group(sessions: [a, b, c], agentStates: [:], unseen: [],
            groupKey: { $0.workingDir ?? "~" }, title: { ($0 as NSString).lastPathComponent })
        XCTAssertEqual(groups.first?.id, "/repo/a")
        XCTAssertEqual(groups.first?.state, .blocked)
        XCTAssertEqual(groups.first?.attentionCount, 1)
        XCTAssertEqual(groups.first?.sessionIds.count, 2)
        XCTAssertEqual(groups.count, 2)
    }

    func testLiveAgentStatesOverrideStaleSnapshot() {
        // Snapshot says working; a fresher observer event says blocked → blocked wins.
        let s = session("claude", .working, dir: "/repo/a")
        let groups = WorkspaceRollup.group(sessions: [s], agentStates: [s.id: .blocked], unseen: [],
            groupKey: { $0.workingDir ?? "~" }, title: { $0 })
        XCTAssertEqual(groups.first?.state, .blocked)
    }

    func testLiveStateWinsEvenWhenSnapshotAgentIsNil() {
        // A live observer reports a newly-started agent before the SessionInfo
        // snapshot's `agent` field catches up (agent == nil). The live state
        // must still drive the rollup — not fall through to .seen.
        let s = session(nil, nil, dir: "/repo/a")
        XCTAssertEqual(WorkspaceRollup.rollupState(for: s, unseen: [], liveState: .blocked), .blocked)
        let groups = WorkspaceRollup.group(sessions: [s], agentStates: [s.id: .working], unseen: [],
            groupKey: { $0.workingDir ?? "~" }, title: { $0 })
        XCTAssertEqual(groups.first?.state, .working)
    }
}
