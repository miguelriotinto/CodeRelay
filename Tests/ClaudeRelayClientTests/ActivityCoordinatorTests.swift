import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

@MainActor
final class ActivityCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> ActivityCoordinator {
        let defaults = UserDefaults(suiteName: "ActivityCoordinatorTests-\(UUID().uuidString)")!
        let store = SessionOwnershipStore(keyPrefix: "test", deviceId: "dev", defaults: defaults)
        return ActivityCoordinator(ownershipStore: store, initialAgents: [:])
    }

    func testHandleActivityUpdateStoresAgentStateAndTitle() {
        let coord = makeCoordinator()
        let id = UUID()
        coord.handleActivityUpdate(sessionId: id, activity: .agentActive, agent: "claude",
                                   agentState: .working, title: "⠋ build")
        XCTAssertEqual(coord.agentState(for: id), .working)
        XCTAssertEqual(coord.title(for: id), "⠋ build")
    }

    func testBlockedStateMarksSessionUnseen() {
        let coord = makeCoordinator()
        let id = UUID()
        coord.handleActivityUpdate(sessionId: id, activity: .agentIdle, agent: "claude",
                                   agentState: .blocked, title: nil)
        XCTAssertTrue(coord.unseenSessions.contains(id), "A blocked agent should mark the session unseen")
    }

    func testDoneStateMarksSessionUnseen() {
        let coord = makeCoordinator()
        let id = UUID()
        // Agent goes idle after working: herdr's "done" — worth surfacing until seen.
        coord.handleActivityUpdate(sessionId: id, activity: .agentIdle, agent: "claude",
                                   agentState: .idle, title: nil)
        XCTAssertTrue(coord.unseenSessions.contains(id))
    }

    func testWorkingStateDoesNotMarkUnseen() {
        let coord = makeCoordinator()
        let id = UUID()
        coord.handleActivityUpdate(sessionId: id, activity: .agentActive, agent: "claude",
                                   agentState: .working, title: nil)
        XCTAssertFalse(coord.unseenSessions.contains(id))
    }

    func testMarkSeenClearsUnseen() {
        let coord = makeCoordinator()
        let id = UUID()
        coord.handleActivityUpdate(sessionId: id, activity: .agentIdle, agent: "claude",
                                   agentState: .blocked, title: nil)
        coord.markSeen(id)
        XCTAssertFalse(coord.unseenSessions.contains(id))
    }

    func testForgetSessionClearsAllNewMaps() {
        let coord = makeCoordinator()
        let id = UUID()
        coord.handleActivityUpdate(sessionId: id, activity: .agentIdle, agent: "claude",
                                   agentState: .blocked, title: "t")
        coord.forgetSession(id)
        XCTAssertNil(coord.agentState(for: id))
        XCTAssertNil(coord.title(for: id))
        XCTAssertFalse(coord.unseenSessions.contains(id))
    }

    func testAgentExitClearsAgentStateAndTitle() {
        let coord = makeCoordinator()
        let id = UUID()
        coord.handleActivityUpdate(sessionId: id, activity: .agentActive, agent: "claude",
                                   agentState: .working, title: "t")
        // Agent exits: activity becomes .idle with no agent — clear derived state.
        coord.handleActivityUpdate(sessionId: id, activity: .idle, agent: nil,
                                   agentState: nil, title: nil)
        XCTAssertNil(coord.agentState(for: id))
        XCTAssertNil(coord.title(for: id))
    }
}
