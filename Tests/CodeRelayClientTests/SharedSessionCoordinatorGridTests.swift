import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

/// Every attach/resume the coordinator issues must carry the pane's last
/// reported grid (`lastKnownTerminalSize`), so the server can resize the PTY
/// BEFORE it replays and repaints. All sessions on one device share the pane,
/// so that one value is right for every session here.
///
/// Fixture: a FakeConnection-backed, already-authenticated `SessionController`
/// is injected through `coordinator.sessionController` (the pattern
/// `SessionSwitchLatencyTests` uses); `RelayConnection()` is never opened.
/// Subclasses `SessionControllerTestCase` only for its `waitUntil`.
@MainActor
final class SharedSessionCoordinatorGridTests: SessionControllerTestCase {

    private var conn: FakeConnection!
    private var coordinator: SharedSessionCoordinator!
    private let first = UUID()
    private let second = UUID()

    override func setUp() async throws {
        try await super.setUp()
        conn = FakeConnection()
        coordinator = SharedSessionCoordinator(connection: RelayConnection(), token: "t1")
        let controller = SessionController(connection: conn, responseTimeout: .milliseconds(200))
        conn.autoRespond = Self.answerEverything(protocolVersion: CodeRelayKit.protocolVersion)
        try await controller.authenticate(token: "t1")
        conn.sentMessages.removeAll()
        coordinator.sessionController = controller
        coordinator.reconcile(tokenScoped: [session(first), session(second)])
    }

    override func tearDown() async throws {
        coordinator.tearDown()
        coordinator = nil
        conn = nil
        try await super.tearDown()
    }

    /// Answers every RPC the switch/attach/reload/recovery paths issue, so the
    /// coordinator's chain runs to completion and the assertions read the
    /// request that actually went out.
    private static func answerEverything(
        protocolVersion: Int,
        failResumeOf failing: UUID? = nil
    ) -> (ClientMessage) -> ServerMessage? {
        { message in
            switch message {
            case .authRequest: return .authSuccess(protocolVersion: protocolVersion)
            case .sessionDetach: return .sessionDetached
            case .sessionResume(let id, _, _, _):
                return id == failing ? .error(code: 404, message: "gone") : .sessionResumed(sessionId: id)
            case .sessionAttach(let id, _, _): return .sessionAttached(sessionId: id, state: "active-attached")
            case .sessionList: return .sessionList(sessions: [])
            default: return nil
            }
        }
    }

    private func session(_ id: UUID) -> SessionInfo {
        SessionInfo(id: id, name: "s", state: .activeDetached, tokenId: "t1",
                    createdAt: Date(timeIntervalSince1970: 0), cols: 80, rows: 24)
    }

    /// Makes `first` the active session with a wired view model, then has that
    /// view report its size once — the same route the platform host uses
    /// (`TerminalViewModel.sendResize` → `onResize` → `lastKnownTerminalSize`).
    private func activateFirstAndReportPane(cols: UInt16, rows: UInt16) {
        coordinator.terminalViewModels[first] = TerminalViewModel(sessionId: first, connection: coordinator.connection)
        coordinator.wireTerminalOutput(to: first)
        coordinator.activeSessionId = first
        coordinator.terminalViewModels[first]?.sendResize(cols: cols, rows: rows)
        XCTAssertEqual(coordinator.lastKnownTerminalSize?.cols, cols)
        XCTAssertEqual(coordinator.lastKnownTerminalSize?.rows, rows)
    }

    private func resumes(of id: UUID) -> [(cols: UInt16?, rows: UInt16?)] {
        conn.sentMessages.compactMap { message in
            if case .sessionResume(let sid, _, let cols, let rows) = message, sid == id { return (cols, rows) }
            return nil
        }
    }

    private func attaches(of id: UUID) -> [(cols: UInt16?, rows: UInt16?)] {
        conn.sentMessages.compactMap { message in
            if case .sessionAttach(let sid, let cols, let rows) = message, sid == id { return (cols, rows) }
            return nil
        }
    }

    // MARK: - Switch

    /// The switch path must put the pane's grid on the resume request. The
    /// coordinator publishes the new selection BEFORE the awaited detach+resume,
    /// so the incoming view's own `resize` lands in the unattached window; the
    /// grid on the request is what makes the server replay and repaint at the
    /// right width regardless.
    func testSwitchToSessionPutsTheLastKnownGridOnTheResume() async throws {
        activateFirstAndReportPane(cols: 104, rows: 33)

        await coordinator.switchToSession(id: second)

        let resume = resumes(of: second).last
        XCTAssertNotNil(resume, "expected a session_resume for the target, got \(conn.sentTypes)")
        XCTAssertEqual(resume?.cols, 104)
        XCTAssertEqual(resume?.rows, 33)
    }

    /// Before the first layout there is no grid to send; the request must go
    /// out with neither field rather than a made-up size.
    func testSwitchWithNoKnownGridSendsNone() async throws {
        coordinator.activeSessionId = first
        XCTAssertNil(coordinator.lastKnownTerminalSize)

        await coordinator.switchToSession(id: second)

        let resume = resumes(of: second).last
        XCTAssertNotNil(resume)
        XCTAssertNil(resume?.cols)
        XCTAssertNil(resume?.rows)
    }

    /// A failed switch re-resumes the previous session (rollback). That resume
    /// repaints the pane too, so it needs the grid as much as the forward one.
    func testSwitchRollbackResumePutsTheGridOnThePreviousSession() async throws {
        activateFirstAndReportPane(cols: 104, rows: 33)
        conn.autoRespond = Self.answerEverything(protocolVersion: CodeRelayKit.protocolVersion, failResumeOf: second)

        await coordinator.switchToSession(id: second)

        XCTAssertEqual(coordinator.activeSessionId, first, "the failed switch rolls back")
        let rollback = resumes(of: first).last
        XCTAssertNotNil(rollback, "expected the rollback session_resume, got \(conn.sentTypes)")
        XCTAssertEqual(rollback?.cols, 104)
        XCTAssertEqual(rollback?.rows, 33)
    }

    // MARK: - Reload

    func testReloadTerminalFromServerPutsTheGridOnTheResume() async throws {
        activateFirstAndReportPane(cols: 104, rows: 33)

        await coordinator.reloadTerminalFromServer(id: first)

        let resume = resumes(of: first).last
        XCTAssertNotNil(resume, "expected a session_resume, got \(conn.sentTypes)")
        XCTAssertEqual(resume?.cols, 104)
        XCTAssertEqual(resume?.rows, 33)
    }

    // MARK: - Attach

    func testAttachRemoteSessionPutsTheGridOnTheAttach() async throws {
        activateFirstAndReportPane(cols: 104, rows: 33)
        let remote = UUID()

        await coordinator.attachRemoteSession(id: remote, serverName: "remote")

        let attach = attaches(of: remote).last
        XCTAssertNotNil(attach, "expected a session_attach, got \(conn.sentTypes)")
        XCTAssertEqual(attach?.cols, 104)
        XCTAssertEqual(attach?.rows, 33)
    }

    // MARK: - Recovery

    /// The recovery restore is a resume too: after a socket swap the server
    /// replays into a pane whose size it has never seen on this connection.
    ///
    /// Asserted on the wire as soon as the resume goes out. What follows it,
    /// `performHandshake(reason: .wake)`, runs as its own task and retries
    /// with ~3.75 s of backoff against the unopened `RelayConnection`; only
    /// `tearDown()` (via `handshake.invalidate()`) cancels it, so the test
    /// tears the coordinator down once the assertion's evidence is in.
    func testRecoveryRestorePutsTheGridOnTheResume() async throws {
        activateFirstAndReportPane(cols: 104, rows: 33)

        let restore = Task {
            await coordinator.recoveryController.restoreSession(generation: 0, userInitiated: true)
        }
        await waitUntil("the restore to resume the active session") { !resumes(of: first).isEmpty }

        let resume = resumes(of: first).last
        XCTAssertEqual(resume?.cols, 104)
        XCTAssertEqual(resume?.rows, 33)

        coordinator.tearDown()
        await restore.value
    }
}
