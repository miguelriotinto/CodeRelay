import XCTest
import ClaudeRelayKit
// Module is c99-sanitized from PRODUCT_NAME "Code[Relay]" — see project.yml.
@testable import Code_Relay_

@MainActor
final class MenuBarActivityTests: XCTestCase {

    private func makeSession(id: UUID = UUID(), state: SessionState = .activeAttached) -> SessionInfo {
        SessionInfo(id: id, state: state, tokenId: "tok", createdAt: Date(), cols: 80, rows: 24)
    }

    // MARK: - No agents

    func testActiveWhenNotAwaitingInput() {
        let s = makeSession()
        let (states, ids) = MenuBarViewModel.computeActivityStates(
            sessions: [s],
            awaitingInput: [],
            activeAgentLookup: { _ in nil }
        )
        XCTAssertEqual(states[s.id], .active)
        XCTAssertNil(ids[s.id])
    }

    func testIdleWhenAwaitingInput() {
        let s = makeSession()
        let (states, ids) = MenuBarViewModel.computeActivityStates(
            sessions: [s],
            awaitingInput: [s.id],
            activeAgentLookup: { _ in nil }
        )
        XCTAssertEqual(states[s.id], .idle)
        XCTAssertNil(ids[s.id])
    }

    // MARK: - With agents

    func testAgentActiveWhenRunning() {
        let s = makeSession()
        let (states, ids) = MenuBarViewModel.computeActivityStates(
            sessions: [s],
            awaitingInput: [],
            activeAgentLookup: { _ in "claude-code" }
        )
        XCTAssertEqual(states[s.id], .agentActive)
        XCTAssertEqual(ids[s.id], "claude-code")
    }

    func testAgentIdleWhenAwaitingInput() {
        let s = makeSession()
        let (states, ids) = MenuBarViewModel.computeActivityStates(
            sessions: [s],
            awaitingInput: [s.id],
            activeAgentLookup: { _ in "codex" }
        )
        XCTAssertEqual(states[s.id], .agentIdle)
        XCTAssertEqual(ids[s.id], "codex")
    }

    // MARK: - Mixed sessions

    func testMixedSessionStates() {
        let s1 = makeSession()
        let s2 = makeSession()
        let s3 = makeSession()

        let agents: [UUID: String] = [s1.id: "claude-code"]

        let (states, ids) = MenuBarViewModel.computeActivityStates(
            sessions: [s1, s2, s3],
            awaitingInput: [s2.id, s1.id],
            activeAgentLookup: { agents[$0] }
        )

        XCTAssertEqual(states[s1.id], .agentIdle)
        XCTAssertEqual(ids[s1.id], "claude-code")
        XCTAssertEqual(states[s2.id], .idle)
        XCTAssertNil(ids[s2.id])
        XCTAssertEqual(states[s3.id], .active)
        XCTAssertNil(ids[s3.id])
    }

    func testEmptySessionsReturnsEmptyMaps() {
        let (states, ids) = MenuBarViewModel.computeActivityStates(
            sessions: [],
            awaitingInput: [UUID()],
            activeAgentLookup: { _ in "ghost" }
        )
        XCTAssertTrue(states.isEmpty)
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - Visibility filter
    //
    // The dropdown drops terminal sessions and nothing else. These tests used to
    // pin a `filterOwned(sessions:owned:)` that also applied a local owned-set
    // filter; that was removed once the server's token-scoped list became the
    // ownership boundary, so an owned-set argument no longer exists to pass.
    // Cross-device sessions reaching the dropdown is now the server's call, not
    // this helper's — asserting otherwise here would re-pin deleted behaviour.

    func testVisibleSessionsKeepsNonTerminalSessions() {
        let attached = makeSession(id: UUID(), state: .activeAttached)
        let detached = makeSession(id: UUID(), state: .activeDetached)
        let result = MenuBarViewModel.visibleSessions([attached, detached])
        XCTAssertEqual(result.map { $0.id }, [attached.id, detached.id])
    }

    func testVisibleSessionsDropsTerminal() {
        let live = makeSession(id: UUID(), state: .activeAttached)
        let exited = makeSession(id: UUID(), state: .exited)
        let result = MenuBarViewModel.visibleSessions([live, exited])
        XCTAssertEqual(result.map { $0.id }, [live.id])
    }

    func testVisibleSessionsReturnsEmptyForNoSessions() {
        XCTAssertTrue(MenuBarViewModel.visibleSessions([]).isEmpty)
    }

    func testVisibleSessionsPreservesInputOrder() {
        let first  = makeSession()
        let second = makeSession()
        let third  = makeSession()
        let result = MenuBarViewModel.visibleSessions([first, second, third])
        XCTAssertEqual(result.map { $0.id }, [first.id, second.id, third.id])
    }
}
