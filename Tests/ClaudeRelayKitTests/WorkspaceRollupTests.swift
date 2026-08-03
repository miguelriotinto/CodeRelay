import XCTest
@testable import ClaudeRelayKit

final class WorkspaceRollupTests: XCTestCase {
    private func session(_ agent: String?, _ state: AgentDetectedState?, dir: String?,
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

    /// Groups sessions by key and rolls each group up to its *worst* member
    /// state. Order is asserted separately below — `/repo/a` is both worst and
    /// alphabetically first here, so this case cannot distinguish the two.
    func testGroupPicksWorstStateWithinAGroup() {
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

    // MARK: - Ordering
    //
    // Every case below is built so alphabetical and severity ordering
    // *disagree*: the previous worst-state-first comparator fails each one. The
    // pre-existing tests all used `/repo/a`-blocked + `/repo/b`-idle, where the
    // two orders agree, so none of them pinned the ordering at all.

    private func rollup(id: String, title: String) -> WorkspaceRollup {
        WorkspaceRollup(id: id, title: title, sessionIds: [], state: .seen, attentionCount: 0)
    }

    private func titledGroups(_ sessions: [SessionInfo]) -> [String] {
        WorkspaceRollup.group(sessions: sessions, agentStates: [:], unseen: [],
            groupKey: { $0.workingDir ?? WorkspaceRollup.otherGroupKey },
            title: {
                $0 == WorkspaceRollup.otherGroupKey
                    ? WorkspaceRollup.otherTitle
                    : ($0 as NSString).lastPathComponent
            }).map(\.title)
    }

    func testOrderIsAlphabeticalNotBySeverity() {
        // `zeta` is blocked (worst) but must still sort last.
        let alpha = session("claude", .idle, dir: "/repo/alpha")
        let zeta = session("claude", .blocked, dir: "/repo/zeta")
        XCTAssertEqual(titledGroups([zeta, alpha]), ["alpha", "zeta"])
    }

    func testOrderIsStableAcrossStateChanges() {
        // The same two directories, with severities swapped. A severity-first
        // sort flips the list; the user sees the sidebar reshuffle under them.
        let quiet = session("claude", .idle, dir: "/repo/alpha")
        let busy = session("claude", .blocked, dir: "/repo/zeta")
        let flipped = [
            session("claude", .blocked, dir: "/repo/alpha"),
            session("claude", .idle, dir: "/repo/zeta")
        ]
        XCTAssertEqual(titledGroups([quiet, busy]), titledGroups(flipped))
    }

    func testOrderIsCaseInsensitive() {
        // Codepoint ordering (`<`) puts every uppercase letter before every
        // lowercase one, so `apple` would sort after `Zebra`.
        let zebra = session("claude", .idle, dir: "/repo/Zebra")
        let apple = session("claude", .idle, dir: "/repo/apple")
        XCTAssertEqual(titledGroups([zebra, apple]), ["apple", "Zebra"])
    }

    func testOrderIsNaturalNumeric() {
        // Lexical ordering would put `repo10` before `repo9`.
        let nine = session("claude", .idle, dir: "/w/repo9")
        let ten = session("claude", .idle, dir: "/w/repo10")
        XCTAssertEqual(titledGroups([ten, nine]), ["repo9", "repo10"])
    }

    func testOtherGroupIsPinnedLastRegardlessOfState() {
        // "Other" sorts before "zeta" alphabetically and is blocked (worst), so
        // both the old comparator and a naive title sort get this wrong.
        let homeless = session("claude", .blocked, dir: nil)
        let zeta = session("claude", .idle, dir: "/repo/zeta")
        let alpha = session("claude", .idle, dir: "/repo/alpha")
        XCTAssertEqual(titledGroups([homeless, zeta, alpha]), ["alpha", "zeta", "Other"])
    }

    func testRepoLiterallyNamedOtherStillSortsAlphabetically() {
        // The pin is keyed on the group *key*, not the title, so a real repo
        // called "Other" is not swept to the bottom with the catch-all.
        let other = session("claude", .idle, dir: "/repo/Other")
        let zeta = session("claude", .idle, dir: "/repo/zeta")
        XCTAssertEqual(titledGroups([zeta, other]), ["Other", "zeta"])
    }

    func testOrderIsTotalForDuplicateTitles() {
        // Two clones of one repo produce the same title. Without the `id`
        // tiebreak the comparator calls them equal, and since `buckets` is a
        // Dictionary (hash order) and `sorted(by:)` is not guaranteed stable,
        // they could swap between calls.
        //
        // Asserted on the comparator directly, as *antisymmetry*: for any two
        // distinct rollups exactly one of the two orderings must hold. Going
        // through `group` cannot test this — String hashing is seeded per
        // process, so which of the two lands first without a tiebreak is luck.
        // Measured: a `case .orderedSame: return false` mutant passed a
        // group-order assertion on this very pair, and fails the check below.
        let work = rollup(id: "/work/app", title: "app")
        let fork = rollup(id: "/fork/app", title: "app")
        XCTAssertTrue(WorkspaceRollup.orderedBefore(fork, work), "expected the lower id to sort first")
        XCTAssertFalse(WorkspaceRollup.orderedBefore(work, fork), "comparator is not antisymmetric")

        // And end-to-end: with the tiebreak in place the group order is
        // deterministic regardless of how the dictionary happened to iterate.
        let ordered = WorkspaceRollup.group(
            sessions: [session("claude", .idle, dir: "/work/app"),
                       session("claude", .blocked, dir: "/fork/app")],
            agentStates: [:], unseen: [],
            groupKey: { $0.workingDir ?? "~" }, title: { ($0 as NSString).lastPathComponent })
        XCTAssertEqual(ordered.map(\.id), ["/fork/app", "/work/app"])
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
