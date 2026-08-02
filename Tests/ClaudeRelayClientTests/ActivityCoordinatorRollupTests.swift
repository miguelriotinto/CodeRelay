import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

@MainActor
final class ActivityCoordinatorRollupTests: XCTestCase {
    private func makeCoordinator() -> ActivityCoordinator {
        let store = SessionOwnershipStore(keyPrefix: "test", deviceId: "dev",
                                          defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return ActivityCoordinator(ownershipStore: store, initialAgents: [:])
    }

    private func session(_ agent: String?, _ state: AgentDetectedState?, dir: String,
                         id: UUID = UUID()) -> SessionInfo {
        SessionInfo(id: id, name: nil, state: .activeAttached, tokenId: "t", createdAt: Date(),
                    cols: 80, rows: 24, activity: .agentActive, agent: agent,
                    agentState: state, title: nil, workingDir: dir)
    }

    func testRollupsGroupByWorkingDir() {
        let coord = makeCoordinator()
        let a = session("claude", .blocked, dir: "/repo/a")
        let b = session("codex", .working, dir: "/repo/b")
        let groups = coord.rollups(for: [a, b])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.title), ["a", "b"])
        XCTAssertEqual(groups.first?.state, .blocked)
    }

    /// The coordinator's `title` closure is what maps a path to a display name,
    /// so the ordering contract has to be pinned here too and not only in
    /// `WorkspaceRollupTests` — a regression in either the closure or the sort
    /// would reshuffle the real sidebar.
    func testRollupOrderIsAlphabeticalWithOtherLast() {
        let coord = makeCoordinator()
        let zeta = session("claude", .blocked, dir: "/repo/zeta")   // worst, sorts last
        let alpha = session("codex", .idle, dir: "/repo/alpha")
        let homeless = SessionInfo(id: UUID(), name: nil, state: .activeAttached, tokenId: "t",
                                   createdAt: Date(), cols: 80, rows: 24, activity: .agentActive,
                                   agent: "claude", agentState: .blocked, title: nil,
                                   workingDir: nil)
        XCTAssertEqual(coord.rollups(for: [zeta, homeless, alpha]).map(\.title),
                       ["alpha", "zeta", "Other"])
    }

    func testRollupsUseLiveAgentStatesOverSnapshot() {
        let coord = makeCoordinator()
        let s = session("claude", .working, dir: "/repo/a")
        coord.agentStates[s.id] = .blocked   // fresher observer event than the snapshot
        XCTAssertEqual(coord.rollups(for: [s]).first?.state, .blocked)
    }

    func testNilWorkingDirGroupsUnderOther() {
        let coord = makeCoordinator()
        let s = SessionInfo(id: UUID(), name: nil, state: .activeAttached, tokenId: "t",
                            createdAt: Date(), cols: 80, rows: 24, activity: .agentActive,
                            agent: "claude", agentState: .working, title: nil, workingDir: nil)
        XCTAssertEqual(coord.rollups(for: [s]).first?.title, "Other")
    }
}
