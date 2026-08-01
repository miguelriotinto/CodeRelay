import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

/// Recording `ConnectionSurface` that answers only the RPCs a test opts into.
/// Anything not covered by `autoRespond` is deliberately left unanswered, which
/// is how these tests model the real failure: a serialized RPC chain that stalls.
@MainActor
private final class StallableConnection: ConnectionSurface {
    var generation: UInt64 = 1
    var isConnected = true

    var sentMessages: [ClientMessage] = []
    var autoRespond: ((ClientMessage) -> ServerMessage?)?

    private var subscribers: [UUID: (ServerMessage) -> Void] = [:]

    func send(_ message: ClientMessage) async throws {
        sentMessages.append(message)
        if let response = autoRespond?(message) { deliver(response) }
    }

    @discardableResult
    func addServerMessageSubscriber(_ handler: @escaping (ServerMessage) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        return id
    }

    func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }

    func deliver(_ message: ServerMessage) {
        for handler in subscribers.values { handler(message) }
    }

    var sentTypes: [String] { sentMessages.map(\.typeString) }

    /// The `skipReplay` flag of the last `session_resume` that went out, or nil
    /// if none did.
    var lastResumeSkipReplay: Bool? {
        for message in sentMessages.reversed() {
            if case .sessionResume(_, let skipReplay) = message { return skipReplay }
        }
        return nil
    }
}

/// Regression suite for the "switching sessions takes minutes" bug on macOS.
///
/// Both defects it covers are latency defects, so they are asserted
/// STRUCTURALLY rather than by wall-clock: what matters is that the UI's
/// selection is published without waiting on the wire, and that a switch back
/// to a locally-cached terminal doesn't ask the server to re-stream a
/// scrollback the client already has on screen.
@MainActor
final class SessionSwitchLatencyTests: XCTestCase {

    /// Polls until `condition` holds; fails on timeout. Condition-based rather
/// than a fixed number of yields — see `SessionControllerTests.waitUntil`.
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    /// Builds a coordinator whose `SessionController` is already authenticated
    /// over `conn`, so `withAuth` hands it straight back without an
    /// `auth_request` of its own. The response timeout is short so a withheld
    /// reply doesn't hold the test for the production 10 s.
    private func makeCoordinator(
        conn: StallableConnection
    ) async throws -> SharedSessionCoordinator {
        let coordinator = SharedSessionCoordinator(connection: RelayConnection(), token: "t1")
        let controller = SessionController(connection: conn, responseTimeout: .milliseconds(200))
        conn.autoRespond = { message in
            message.typeString == "auth_request"
                ? .authSuccess(protocolVersion: ClaudeRelayKit.protocolVersion)
                : nil
        }
        try await controller.authenticate(token: "t1")
        conn.autoRespond = nil
        conn.sentMessages.removeAll()
        coordinator.sessionController = controller
        return coordinator
    }

    private func session(_ id: UUID) -> SessionInfo {
        SessionInfo(id: id, name: "s", state: .activeDetached, tokenId: "t1",
                    createdAt: Date(timeIntervalSince1970: 0), cols: 80, rows: 24)
    }

    // MARK: - Optimistic selection

    /// The reported bug, reduced: with the server not answering `session_resume`,
    /// the sidebar highlight and the terminal container must STILL swap, because
    /// both key off `activeSessionId`.
    ///
    /// Before the fix, `activeSessionId` was assigned only after `detach` +
    /// `resume` + a forced `session_list` had all completed. Those RPCs share one
    /// serialized chain (replies carry no request ids), each with a 10 s timeout
    /// whose expiry poisons the socket — so one slow hop froze the UI for the
    /// length of a handshake-retry + recovery-backoff cascade. Minutes, as
    /// reported.
    func testSelectionIsPublishedWithoutWaitingForTheServer() async throws {
        let conn = StallableConnection()
        let coordinator = try await makeCoordinator(conn: conn)
        let first = UUID(), second = UUID()
        coordinator.reconcile(tokenScoped: [session(first), session(second)])
        coordinator.activeSessionId = first

        // `session_resume` is never answered: the switch's RPC chain stalls.
        conn.autoRespond = { message in
            message.typeString == "session_detach" ? .sessionDetached : nil
        }

        let switching = Task { await coordinator.switchToSession(id: second) }

        await waitUntil("the selection to move to the target session") {
            coordinator.activeSessionId == second
        }
        XCTAssertNotNil(coordinator.terminalViewModels[second],
                        "the target's view model is wired before the RPC settles")

        _ = await switching.value
    }

    /// A second click on a session already being switched to must be a no-op.
    /// This is the amplification half of the bug: while `activeSessionId` lagged
    /// the RPCs, the `id != activeSessionId` guard couldn't see the in-flight
    /// switch, so every impatient re-click queued ANOTHER detach+resume pair onto
    /// the already-stalled chain and made the wait strictly longer.
    func testRepeatedClickDuringSwitchDoesNotQueueAnotherResume() async throws {
        let conn = StallableConnection()
        let coordinator = try await makeCoordinator(conn: conn)
        let first = UUID(), second = UUID()
        coordinator.reconcile(tokenScoped: [session(first), session(second)])
        coordinator.activeSessionId = first

        conn.autoRespond = { message in
            message.typeString == "session_detach" ? .sessionDetached : nil
        }

        let switching = Task { await coordinator.switchToSession(id: second) }
        await waitUntil("the first switch to publish its selection") {
            coordinator.activeSessionId == second
        }

        await coordinator.switchToSession(id: second)

        XCTAssertEqual(conn.sentTypes.filter { $0 == "session_resume" }.count, 1,
                       "an impatient re-click must not enqueue a second resume")
        _ = await switching.value
    }

    /// Publishing the selection early means a FAILED resume must put it back —
    /// otherwise the pane shows a session the server auto-detached and never
    /// re-attached, i.e. a dead terminal that accepts input going nowhere.
    func testFailedResumeRestoresThePreviousSelection() async throws {
        let conn = StallableConnection()
        let coordinator = try await makeCoordinator(conn: conn)
        let first = UUID(), second = UUID()
        coordinator.reconcile(tokenScoped: [session(first), session(second)])
        coordinator.activeSessionId = first

        conn.autoRespond = { message in
            switch message {
            case .sessionDetach: return .sessionDetached
            case .sessionResume(let id, _):
                // The target's resume fails; the rollback's re-resume succeeds.
                return id == second ? .error(code: 404, message: "gone") : .sessionResumed(sessionId: id)
            default: return nil
            }
        }

        await coordinator.switchToSession(id: second)

        XCTAssertEqual(coordinator.activeSessionId, first,
                       "a failed resume rolls the optimistic selection back")
        XCTAssertTrue(coordinator.showError)
    }

    /// The F3 launch-restore path switches with nothing previously selected. A
    /// failure there has no selection to roll back TO, so it must clear rather
    /// than leave the pane pointing at an unattached session.
    func testFailedResumeWithNoPreviousSessionClearsSelection() async throws {
        let conn = StallableConnection()
        let coordinator = try await makeCoordinator(conn: conn)
        let restored = UUID()
        coordinator.reconcile(tokenScoped: [session(restored)])

        conn.autoRespond = { message in
            message.typeString == "session_resume" ? .error(code: 404, message: "gone") : nil
        }

        await coordinator.switchToSession(id: restored)

        XCTAssertNil(coordinator.activeSessionId,
                     "no previous selection to restore — clear it instead of showing a dead terminal")
    }

    // MARK: - Scrollback replay

    /// Switching back to a session whose native terminal view is still cached
    /// must skip the ring-buffer replay: that view already holds the full
    /// scrollback, and re-streaming it costs `scrollbackSize` bytes in 64 KB
    /// frames per switch (2 MB on a configured host), parsed on the main actor.
    /// `skipReplay` exists for exactly this and had no caller.
    func testSwitchToCachedTerminalSkipsReplay() async throws {
        let conn = StallableConnection()
        let coordinator = try await makeCoordinator(conn: conn)
        let first = UUID(), second = UUID()
        coordinator.reconcile(tokenScoped: [session(first), session(second)])
        coordinator.activeSessionId = first

        // The platform host registered a live terminal for `second` on a previous
        // visit, so its scrollback is on screen already.
        coordinator.registerLiveTerminal(for: second, view: NSObject())

        conn.autoRespond = { message in
            switch message {
            case .sessionDetach: return .sessionDetached
            case .sessionResume(let id, _): return .sessionResumed(sessionId: id)
            default: return nil
            }
        }

        await coordinator.switchToSession(id: second)

        XCTAssertEqual(conn.lastResumeSkipReplay, true,
                       "a cached terminal already has the scrollback — don't re-stream it")
    }

    /// The complement: a session with no cached view has nothing on screen, so
    /// the replay is the only way to populate it and must still be requested.
    func testSwitchToUncachedTerminalStillReplays() async throws {
        let conn = StallableConnection()
        let coordinator = try await makeCoordinator(conn: conn)
        let first = UUID(), second = UUID()
        coordinator.reconcile(tokenScoped: [session(first), session(second)])
        coordinator.activeSessionId = first

        conn.autoRespond = { message in
            switch message {
            case .sessionDetach: return .sessionDetached
            case .sessionResume(let id, _): return .sessionResumed(sessionId: id)
            default: return nil
            }
        }

        await coordinator.switchToSession(id: second)

        XCTAssertEqual(conn.lastResumeSkipReplay, false,
                       "no cached view means the server's replay is the only content source")
    }
}
