import XCTest
@testable import ClaudeRelayKit

final class SessionStateTests: XCTestCase {

    // MARK: - Terminal State Detection

    func testTerminalStates() {
        let terminalStates: [SessionState] = [.exited, .failed, .terminated, .expired]
        for state in terminalStates {
            XCTAssertTrue(state.isTerminal, "\(state) should be terminal")
        }
    }

    func testNonTerminalStates() {
        let nonTerminal: [SessionState] = [.created, .starting, .activeAttached, .activeDetached, .resuming]
        for state in nonTerminal {
            XCTAssertFalse(state.isTerminal, "\(state) should not be terminal")
        }
    }

    // MARK: - Valid Transitions

    func testCreatedCanTransitionToStarting() {
        XCTAssertTrue(SessionState.created.canTransition(to: .starting))
    }

    func testStartingCanTransitionToActiveAttached() {
        XCTAssertTrue(SessionState.starting.canTransition(to: .activeAttached))
    }

    func testStartingCanTransitionToFailed() {
        XCTAssertTrue(SessionState.starting.canTransition(to: .failed))
    }

    func testActiveAttachedCanTransitionToActiveDetached() {
        XCTAssertTrue(SessionState.activeAttached.canTransition(to: .activeDetached))
    }

    func testActiveAttachedCanTransitionToExited() {
        XCTAssertTrue(SessionState.activeAttached.canTransition(to: .exited))
    }

    func testActiveAttachedCanTransitionToFailed() {
        XCTAssertTrue(SessionState.activeAttached.canTransition(to: .failed))
    }

    func testActiveAttachedCanTransitionToTerminated() {
        XCTAssertTrue(SessionState.activeAttached.canTransition(to: .terminated))
    }

    func testActiveDetachedCanTransitionToResuming() {
        XCTAssertTrue(SessionState.activeDetached.canTransition(to: .resuming))
    }

    func testActiveDetachedCanTransitionToActiveAttached() {
        // Cross-device attach: the other device disconnected (session is
        // activeDetached) and this device attaches directly.
        XCTAssertTrue(SessionState.activeDetached.canTransition(to: .activeAttached))
    }

    func testActiveDetachedCanTransitionToExpired() {
        XCTAssertTrue(SessionState.activeDetached.canTransition(to: .expired))
    }

    func testActiveDetachedCanTransitionToExited() {
        XCTAssertTrue(SessionState.activeDetached.canTransition(to: .exited))
    }

    func testActiveDetachedCanTransitionToFailed() {
        XCTAssertTrue(SessionState.activeDetached.canTransition(to: .failed))
    }

    func testActiveDetachedCanTransitionToTerminated() {
        XCTAssertTrue(SessionState.activeDetached.canTransition(to: .terminated))
    }

    func testResumingCanTransitionToActiveAttached() {
        XCTAssertTrue(SessionState.resuming.canTransition(to: .activeAttached))
    }

    func testResumingCanTransitionToFailed() {
        XCTAssertTrue(SessionState.resuming.canTransition(to: .failed))
    }

    func testResumingCanTransitionToTerminated() {
        XCTAssertTrue(SessionState.resuming.canTransition(to: .terminated))
    }

    // MARK: - Invalid Transitions

    func testCreatedCannotTransitionToActiveAttached() {
        XCTAssertFalse(SessionState.created.canTransition(to: .activeAttached))
    }

    func testCreatedCannotTransitionToExited() {
        XCTAssertFalse(SessionState.created.canTransition(to: .exited))
    }

    func testTerminalStatesCannotTransition() {
        let terminalStates: [SessionState] = [.exited, .failed, .terminated, .expired]
        let allStates: [SessionState] = [
            .created, .starting, .activeAttached, .activeDetached,
            .resuming, .exited, .failed, .terminated, .expired
        ]
        for terminal in terminalStates {
            for target in allStates {
                XCTAssertFalse(terminal.canTransition(to: target),
                    "\(terminal) should not transition to \(target)")
            }
        }
    }

    // MARK: - Failed Reachable from All Active States

    func testFailedReachableFromAllActiveStates() {
        let activeStates: [SessionState] = [.starting, .activeAttached, .activeDetached, .resuming]
        for state in activeStates {
            XCTAssertTrue(state.canTransition(to: .failed),
                "\(state) should be able to transition to failed")
        }
    }

    // MARK: - Terminated Reachable from Non-Terminal States Only

    func testTerminatedReachableFromExpectedStates() {
        let canReachTerminated: [SessionState] = [.activeAttached, .activeDetached, .resuming]
        for state in canReachTerminated {
            XCTAssertTrue(state.canTransition(to: .terminated),
                "\(state) should be able to transition to terminated")
        }
    }

    func testTerminatedNotReachableFromTerminalStates() {
        let terminalStates: [SessionState] = [.exited, .failed, .terminated, .expired]
        for state in terminalStates {
            XCTAssertFalse(state.canTransition(to: .terminated),
                "\(state) should not transition to terminated")
        }
    }

    // MARK: - Raw Values (Codable)

    func testRawValues() {
        XCTAssertEqual(SessionState.created.rawValue, "created")
        XCTAssertEqual(SessionState.starting.rawValue, "starting")
        XCTAssertEqual(SessionState.activeAttached.rawValue, "active-attached")
        XCTAssertEqual(SessionState.activeDetached.rawValue, "active-detached")
        XCTAssertEqual(SessionState.resuming.rawValue, "resuming")
        XCTAssertEqual(SessionState.exited.rawValue, "exited")
        XCTAssertEqual(SessionState.failed.rawValue, "failed")
        XCTAssertEqual(SessionState.terminated.rawValue, "terminated")
        XCTAssertEqual(SessionState.expired.rawValue, "expired")
    }

    // MARK: - SessionInfo Codable Round-Trip

    func testSessionInfoCodableRoundTrip() throws {
        let id = UUID()
        let now = Date()
        let info = SessionInfo(
            id: id,
            name: nil,
            state: .activeAttached,
            tokenId: "tok_abc123",
            createdAt: now,
            cols: 120,
            rows: 40
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(info)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionInfo.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.state, .activeAttached)
        XCTAssertEqual(decoded.tokenId, "tok_abc123")
        XCTAssertEqual(decoded.cols, 120)
        XCTAssertEqual(decoded.rows, 40)
    }
}
