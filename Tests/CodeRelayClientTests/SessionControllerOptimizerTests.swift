import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

/// `optimize_prompt` / `replace_prompt` RPCs and the capability bookkeeping
/// `authenticate()` now does. Uses the FakeConnection harness from
/// `SessionControllerTestCase.swift`.
@MainActor
final class SessionControllerOptimizerTests: SessionControllerTestCase {

    private func authenticated(
        conn: FakeConnection,
        protocolVersion: Int = 2,
        capabilities: [String]? = [CodeRelayKit.promptOptimizerCapability],
        responseTimeout: Duration = .seconds(10),
        optimizerTimeout: Duration = .seconds(20)
    ) async throws -> SessionController {
        let controller = SessionController(
            connection: conn,
            responseTimeout: responseTimeout,
            optimizerTimeout: optimizerTimeout
        )
        conn.autoRespond = { message in
            if case .authRequest = message {
                return .authSuccess(protocolVersion: protocolVersion, tokenId: "tok", capabilities: capabilities)
            }
            return nil
        }
        try await controller.authenticate(token: "t")
        conn.autoRespond = nil
        return controller
    }

    // MARK: - auth_success bookkeeping

    func testAuthRecordsProtocolVersionAndCapabilities() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(conn: conn, protocolVersion: 2, capabilities: ["prompt_optimizer", "future"])
        XCTAssertEqual(controller.serverProtocolVersion, 2)
        XCTAssertEqual(controller.serverCapabilities, ["prompt_optimizer", "future"])
    }

    func testAuthWithoutCapabilitiesLeavesSetEmptyAndVersionZeroWhenAbsent() async throws {
        let conn = FakeConnection()
        let controller = SessionController(connection: conn)
        conn.autoRespond = { message in
            if case .authRequest = message { return .authSuccess(protocolVersion: nil, tokenId: nil, capabilities: nil) }
            return nil
        }
        try await controller.authenticate(token: "t")
        XCTAssertEqual(controller.serverProtocolVersion, 0)
        XCTAssertTrue(controller.serverCapabilities.isEmpty)
    }

    func testReauthReplacesCapabilities() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(conn: conn, capabilities: ["prompt_optimizer"])
        controller.resetAuth()
        conn.autoRespond = { message in
            if case .authRequest = message { return .authSuccess(protocolVersion: 2, tokenId: "tok", capabilities: []) }
            return nil
        }
        try await controller.authenticate(token: "t")
        XCTAssertTrue(controller.serverCapabilities.isEmpty)
    }

    /// Between `resetAuth()` and the next `auth_success` nothing may still read
    /// the previous relay's capability set.
    func testResetAuthClearsCapabilitiesAndProtocolVersion() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(conn: conn, protocolVersion: 2, capabilities: ["prompt_optimizer"])
        XCTAssertEqual(controller.serverProtocolVersion, 2)

        controller.resetAuth()

        XCTAssertEqual(controller.serverProtocolVersion, 0)
        XCTAssertTrue(controller.serverCapabilities.isEmpty)
    }

    // MARK: - optimize_prompt

    func testOptimizeSendsSessionIdAndShareScreen() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(conn: conn)
        let sessionId = UUID()
        conn.autoRespond = { message in
            if case .optimizePrompt(let id, let share) = message {
                XCTAssertEqual(id, sessionId)
                XCTAssertFalse(share)
                return .optimizePromptResult(status: "ok", original: "fix it", prompt: "Fix the failing test", message: nil)
            }
            return nil
        }
        let outcome = try await controller.optimizePrompt(sessionId: sessionId, shareScreen: false)
        XCTAssertEqual(outcome, .ok(original: "fix it"))
        XCTAssertEqual(conn.sentTypes.last, "optimize_prompt")
    }

    func testOptimizeMapsEveryStatus() async throws {
        let cases: [(String, String?, OptimizeOutcome)] = [
            ("ok", nil, .ok(original: nil)),
            ("no_draft", nil, .noDraft),
            ("passthrough", nil, .passthrough),
            ("unconfigured", nil, .unconfigured),
            ("failed", "Prompt too long to optimize", .failed(message: "Prompt too long to optimize")),
            ("failed", nil, .failed(message: OptimizerStrings.couldNotRewrite)),
            ("something_new", nil, .failed(message: OptimizerStrings.couldNotRewrite)),
        ]
        for (status, message, expected) in cases {
            let conn = FakeConnection()
            let controller = try await authenticated(conn: conn)
            conn.autoRespond = { m in
                if case .optimizePrompt = m {
                    return .optimizePromptResult(status: status, original: nil, prompt: nil, message: message)
                }
                return nil
            }
            let outcome = try await controller.optimizePrompt(sessionId: UUID(), shareScreen: true)
            XCTAssertEqual(outcome, expected, "status \(status)")
        }
    }

    /// An empty `message` is as good as absent: passing it through would set
    /// `optimizerNotice = ""` and draw an empty toast capsule.
    func testOptimizeEmptyFailureMessageFallsBackToStandardCopy() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(conn: conn)
        conn.autoRespond = { m in
            if case .optimizePrompt = m {
                return .optimizePromptResult(status: "failed", original: nil, prompt: nil, message: "")
            }
            return nil
        }
        let outcome = try await controller.optimizePrompt(sessionId: UUID(), shareScreen: true)
        XCTAssertEqual(outcome, .failed(message: OptimizerStrings.couldNotRewrite))
    }

    func testOptimizeErrorReplyThrowsUnexpectedResponse() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(conn: conn)
        conn.autoRespond = { m in
            if case .optimizePrompt = m { return .error(code: 400, message: "Session not attached") }
            return nil
        }
        do {
            _ = try await controller.optimizePrompt(sessionId: UUID(), shareScreen: true)
            XCTFail("expected throw")
        } catch SessionController.SessionError.unexpectedResponse(let message) {
            XCTAssertEqual(message, "Session not attached")
        }
    }

    func testOptimizeUsesTwentySecondWaiterNotTheDefault() async throws {
        // Default waiter 50 ms, optimizer waiter 400 ms: a reply at 200 ms must
        // still be accepted, proving the longer timeout is the one in force.
        let conn = FakeConnection()
        let controller = try await authenticated(
            conn: conn,
            responseTimeout: .milliseconds(50),
            optimizerTimeout: .milliseconds(400)
        )
        conn.autoRespond = nil
        let task = Task { try await controller.optimizePrompt(sessionId: UUID(), shareScreen: true) }
        try await Task.sleep(for: .milliseconds(200))
        conn.deliver(.optimizePromptResult(status: "passthrough", original: nil, prompt: nil, message: nil))
        let outcome = try await task.value
        XCTAssertEqual(outcome, .passthrough)
    }

    func testOptimizeTimesOutAfterOptimizerTimeout() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(
            conn: conn,
            responseTimeout: .milliseconds(50),
            optimizerTimeout: .milliseconds(150)
        )
        do {
            _ = try await controller.optimizePrompt(sessionId: UUID(), shareScreen: true)
            XCTFail("expected timeout")
        } catch SessionController.SessionError.timeout {
            // expected
        }
    }

    // MARK: - replace_prompt

    func testReplaceSendsTextAndMapsOk() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(conn: conn)
        let sessionId = UUID()
        conn.autoRespond = { m in
            if case .replacePrompt(let id, let text) = m {
                XCTAssertEqual(id, sessionId)
                XCTAssertEqual(text, "original words")
                return .replacePromptResult(status: "ok", message: nil)
            }
            return nil
        }
        let outcome = try await controller.replacePrompt(sessionId: sessionId, text: "original words")
        XCTAssertEqual(outcome, .ok)
        XCTAssertEqual(conn.sentTypes.last, "replace_prompt")
    }

    func testReplaceMapsFailedAndUnknown() async throws {
        for (status, message, expected) in [
            ("failed", "Session not attached", ReplaceOutcome.failed(message: "Session not attached")),
            ("failed", nil, .failed(message: OptimizerStrings.couldNotRewrite)),
            ("weird", nil, .failed(message: OptimizerStrings.couldNotRewrite)),
        ] {
            let conn = FakeConnection()
            let controller = try await authenticated(conn: conn)
            conn.autoRespond = { m in
                if case .replacePrompt = m { return .replacePromptResult(status: status, message: message) }
                return nil
            }
            let outcome = try await controller.replacePrompt(sessionId: UUID(), text: "x")
            XCTAssertEqual(outcome, expected, "status \(status)")
        }
    }

    /// Same empty-message hardening as `optimize_prompt`.
    func testReplaceEmptyFailureMessageFallsBackToStandardCopy() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(conn: conn)
        conn.autoRespond = { m in
            if case .replacePrompt = m { return .replacePromptResult(status: "failed", message: "") }
            return nil
        }
        let outcome = try await controller.replacePrompt(sessionId: UUID(), text: "x")
        XCTAssertEqual(outcome, .failed(message: OptimizerStrings.couldNotRewrite))
    }

    func testOtherRPCsStillUseDefaultTimeout() async throws {
        // listSessions must time out at the 50 ms default even though the
        // optimizer waiter is long.
        let conn = FakeConnection()
        let controller = try await authenticated(
            conn: conn,
            responseTimeout: .milliseconds(50),
            optimizerTimeout: .seconds(20)
        )
        let started = ContinuousClock.now
        do {
            _ = try await controller.listSessions()
            XCTFail("expected timeout")
        } catch SessionController.SessionError.timeout {
            XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        }
    }
}
