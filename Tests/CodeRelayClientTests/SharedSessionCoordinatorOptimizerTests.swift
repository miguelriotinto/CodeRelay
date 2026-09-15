import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

/// Wand state transitions, toasts, and Undo on the shared coordinator (spec
/// §7.1 / §11). A FakeConnection-backed, already-authenticated
/// `SessionController` is injected through `coordinator.sessionController`;
/// `RelayConnection()` is never opened.
@MainActor
final class SharedSessionCoordinatorOptimizerTests: XCTestCase {

    private var conn: FakeConnection!
    private var coordinator: SharedSessionCoordinator!
    private let sessionId = UUID()

    override func setUp() async throws {
        try await super.setUp()
        conn = FakeConnection()
        coordinator = SharedSessionCoordinator(connection: RelayConnection(), token: "t")
        coordinator.optimizerUndoWindow = .milliseconds(150)
        coordinator.optimizerNoticeDuration = .milliseconds(150)
        coordinator.activeSessionId = sessionId
    }

    override func tearDown() async throws {
        coordinator.tearDown()
        coordinator = nil
        conn = nil
        try await super.tearDown()
    }

    /// Authenticates a controller against `conn` and hands it to the coordinator.
    private func inject(protocolVersion: Int = 2, capabilities: [String]? = [CodeRelayKit.promptOptimizerCapability]) async throws {
        let controller = SessionController(connection: conn)
        conn.autoRespond = { m in
            if case .authRequest = m {
                return .authSuccess(protocolVersion: protocolVersion, tokenId: "tok", capabilities: capabilities)
            }
            return nil
        }
        try await controller.authenticate(token: "t")
        conn.autoRespond = nil
        coordinator.sessionController = controller
        coordinator.refreshOptimizerAvailability()
    }

    private func respondToOptimize(_ result: ServerMessage) {
        conn.autoRespond = { m in
            if case .optimizePrompt = m { return result }
            return nil
        }
    }

    // MARK: - Availability

    func testAvailabilityUnknownBeforeAuth() {
        XCTAssertEqual(coordinator.optimizerAvailability, .unknown)
        XCTAssertFalse(coordinator.isOptimizerAvailable)
        XCTAssertNil(coordinator.wandHint)
    }

    func testAvailableWhenCapabilityPresentAndProtocolV2() async throws {
        try await inject()
        XCTAssertEqual(coordinator.optimizerAvailability, .available)
        XCTAssertTrue(coordinator.isOptimizerAvailable)
        XCTAssertNil(coordinator.wandHint)
    }

    func testUnconfiguredWhenCapabilityMissing() async throws {
        try await inject(capabilities: [])
        XCTAssertEqual(coordinator.optimizerAvailability, .unconfigured)
        XCTAssertEqual(coordinator.wandHint, OptimizerStrings.configHint)
    }

    func testServerTooOldWhenProtocolBelowTwo() async throws {
        try await inject(protocolVersion: 1, capabilities: [CodeRelayKit.promptOptimizerCapability])
        XCTAssertEqual(coordinator.optimizerAvailability, .serverTooOld)
        XCTAssertEqual(coordinator.wandHint, OptimizerStrings.updateRelayHint)
    }

    // MARK: - Enablement

    func testWandEnabledOnlyWhenIdleNotRecoveringWithActiveSession() async throws {
        try await inject()
        XCTAssertTrue(coordinator.isWandEnabled)
        coordinator.isRecovering = true
        XCTAssertFalse(coordinator.isWandEnabled)
        coordinator.isRecovering = false
        coordinator.isTornDown = true
        XCTAssertFalse(coordinator.isWandEnabled, "a torn-down coordinator must not re-authenticate")
        coordinator.isTornDown = false
        coordinator.activeSessionId = nil
        XCTAssertFalse(coordinator.isWandEnabled)
    }

    func testTapWhileUnconfiguredShowsConfigHintAndSendsNothing() async throws {
        try await inject(capabilities: [])
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertEqual(coordinator.optimizerNotice, OptimizerStrings.configHint)
        XCTAssertFalse(conn.sentTypes.contains("optimize_prompt"))
        XCTAssertEqual(coordinator.optimizerState, .idle)
    }

    func testTapWhileServerTooOldShowsUpdateHintAndSendsNothing() async throws {
        try await inject(protocolVersion: 1)
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertEqual(coordinator.optimizerNotice, OptimizerStrings.updateRelayHint)
        XCTAssertFalse(conn.sentTypes.contains("optimize_prompt"))
        XCTAssertEqual(coordinator.optimizerState, .idle)
    }

    func testTapWhileUnavailableNeverEntersOptimizing() async throws {
        try await inject(capabilities: [])
        XCTAssertEqual(coordinator.optimizerAvailability, .unconfigured)
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertEqual(coordinator.optimizerState, .idle, "Must stay idle when unavailable")
        XCTAssertEqual(coordinator.optimizerNotice, OptimizerStrings.configHint)
    }

    // MARK: - optimize → ok → Undo

    func testOkArmsUndoAndUndoSendsReplaceWithOriginal() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: "fix the thing", prompt: "Fix the thing.", message: nil))

        await coordinator.optimizePrompt(shareScreen: false)

        XCTAssertEqual(coordinator.optimizerState, .idle)
        XCTAssertEqual(coordinator.optimizerUndo, OptimizerUndo(sessionId: sessionId, original: "fix the thing"))
        XCTAssertNil(coordinator.optimizerNotice)
        if case .optimizePrompt(let id, let share) = conn.sentMessages.last {
            XCTAssertEqual(id, sessionId)
            XCTAssertFalse(share)
        } else {
            XCTFail("expected optimize_prompt, got \(conn.sentTypes)")
        }

        conn.autoRespond = { m in
            if case .replacePrompt = m { return .replacePromptResult(status: "ok", message: nil) }
            return nil
        }
        await coordinator.undoOptimize()

        if case .replacePrompt(let id, let text) = conn.sentMessages.last {
            XCTAssertEqual(id, sessionId)
            XCTAssertEqual(text, "fix the thing")
        } else {
            XCTFail("expected replace_prompt, got \(conn.sentTypes)")
        }
        XCTAssertNil(coordinator.optimizerUndo, "Undo is one-shot")
        XCTAssertEqual(coordinator.optimizerState, .idle)
    }

    func testStateIsOptimizingWhileRPCInFlightAndTapIsIgnoredMeanwhile() async throws {
        try await inject()
        conn.autoRespond = nil
        let first = Task { await coordinator.optimizePrompt(shareScreen: true) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(coordinator.optimizerState, .optimizing)
        XCTAssertFalse(coordinator.isWandEnabled)

        await coordinator.optimizePrompt(shareScreen: true) // second tap: ignored
        XCTAssertEqual(conn.sentTypes.filter { $0 == "optimize_prompt" }.count, 1)

        conn.deliver(.optimizePromptResult(status: "ok", original: "a", prompt: "b", message: nil))
        await first.value
        XCTAssertEqual(coordinator.optimizerState, .idle)
    }

    func testUndoExpiresAfterWindow() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: "a", prompt: "b", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertNotNil(coordinator.optimizerUndo)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(coordinator.optimizerUndo)
    }

    func testSwitchingSessionClearsUndo() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: "a", prompt: "b", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertNotNil(coordinator.optimizerUndo)
        coordinator.activeSessionId = UUID()
        XCTAssertNil(coordinator.optimizerUndo)
    }

    /// No `original` means there is nothing to put back, so no chip — but the
    /// rewrite still landed and the user gets told (spec §7.1).
    func testOkWithoutOriginalConfirmsWithoutArmingUndo() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: nil, prompt: "b", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertNil(coordinator.optimizerUndo)
        XCTAssertEqual(coordinator.optimizerNotice, OptimizerStrings.optimized)
    }

    func testFailedRetryKeepsExistingUndo() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: "the original", prompt: "rewrite #1", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        let firstUndo = coordinator.optimizerUndo
        XCTAssertEqual(firstUndo, OptimizerUndo(sessionId: sessionId, original: "the original"))

        respondToOptimize(.optimizePromptResult(status: "failed", original: nil, prompt: nil, message: "Something broke"))
        await coordinator.optimizePrompt(shareScreen: true)

        XCTAssertEqual(coordinator.optimizerUndo, firstUndo, "Failed retry must keep the original undo")
        XCTAssertEqual(coordinator.optimizerNotice, "Something broke")

        conn.autoRespond = { m in
            if case .replacePrompt(let id, let text) = m {
                XCTAssertEqual(id, self.sessionId)
                XCTAssertEqual(text, "the original", "Undo must still send the true original")
                return .replacePromptResult(status: "ok", message: nil)
            }
            return nil
        }
        await coordinator.undoOptimize()
        XCTAssertNil(coordinator.optimizerUndo, "Undo is one-shot")
    }

    // MARK: - Toasts

    func testNoDraftPassthroughUnconfiguredFailedToasts() async throws {
        let cases: [(ServerMessage, String)] = [
            (.optimizePromptResult(status: "no_draft", original: nil, prompt: nil, message: nil), OptimizerStrings.noDraft),
            (.optimizePromptResult(status: "passthrough", original: nil, prompt: nil, message: nil), OptimizerStrings.passthrough),
            (.optimizePromptResult(status: "unconfigured", original: nil, prompt: nil, message: nil), OptimizerStrings.configHint),
            (.optimizePromptResult(status: "failed", original: nil, prompt: nil, message: "Optimizer key rejected on the relay"), "Optimizer key rejected on the relay"),
            (.optimizePromptResult(status: "failed", original: nil, prompt: nil, message: nil), OptimizerStrings.couldNotRewrite),
        ]
        for (reply, expected) in cases {
            try await inject()
            respondToOptimize(reply)
            await coordinator.optimizePrompt(shareScreen: true)
            XCTAssertEqual(coordinator.optimizerNotice, expected)
            XCTAssertNil(coordinator.optimizerUndo)
            coordinator.dismissOptimizerNotice()
        }
    }

    func testUnconfiguredReplyDowngradesAvailability() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "unconfigured", original: nil, prompt: nil, message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertEqual(coordinator.optimizerAvailability, .unconfigured)
    }

    func testErrorReplyBecomesToastWithServerMessage() async throws {
        try await inject()
        respondToOptimize(.error(code: 400, message: "Session not attached"))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertEqual(coordinator.optimizerNotice, "Session not attached")
        XCTAssertEqual(coordinator.optimizerState, .idle)
    }

    func testNoticeAutoDismisses() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "passthrough", original: nil, prompt: nil, message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertNotNil(coordinator.optimizerNotice)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(coordinator.optimizerNotice)
    }

    func testUndoFailureShowsServerMessage() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: "a", prompt: "b", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        conn.autoRespond = { m in
            if case .replacePrompt = m { return .replacePromptResult(status: "failed", message: "Session not attached") }
            return nil
        }
        await coordinator.undoOptimize()
        XCTAssertEqual(coordinator.optimizerNotice, "Session not attached")
        XCTAssertEqual(
            coordinator.optimizerUndo, OptimizerUndo(sessionId: sessionId, original: "a"),
            "A failed undo must keep the chip: it holds the only copy of the user's draft"
        )
    }

    /// After a successful optimize the terminal holds the rewrite and
    /// `optimizerUndo` is the only copy of what the user typed, so a failed
    /// replace must not consume it — and must not extend its window either.
    func testUndoFailureKeepsTheChipSoTheUserCanRetry() async throws {
        coordinator.optimizerUndoWindow = .milliseconds(500)
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: "the original", prompt: "rewrite", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertNotNil(coordinator.optimizerUndo)

        // Spend most of the 500 ms window before failing, so a re-armed task
        // would be provably visible at the last assertion below.
        try await Task.sleep(for: .milliseconds(350))
        conn.autoRespond = { m in
            if case .replacePrompt = m { return .replacePromptResult(status: "failed", message: "Draft mirror lost") }
            return nil
        }
        await coordinator.undoOptimize()

        XCTAssertEqual(coordinator.optimizerUndo, OptimizerUndo(sessionId: sessionId, original: "the original"))
        XCTAssertEqual(coordinator.optimizerNotice, "Draft mirror lost")
        XCTAssertEqual(coordinator.optimizerState, .idle, "a retry must be possible immediately")

        // A second attempt still sends the true original.
        conn.autoRespond = { m in
            if case .replacePrompt(let id, let text) = m {
                XCTAssertEqual(id, self.sessionId)
                XCTAssertEqual(text, "the original")
                return .replacePromptResult(status: "ok", message: nil)
            }
            return nil
        }
        await coordinator.undoOptimize()
        XCTAssertNil(coordinator.optimizerUndo, "a successful undo is one-shot")
    }

    /// The 10 s window is not restarted by a failed undo: the chip disappears on
    /// the schedule the optimize set, not on the failure's.
    func testFailedUndoDoesNotExtendTheUndoWindow() async throws {
        coordinator.optimizerUndoWindow = .milliseconds(500)
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: "the original", prompt: "rewrite", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)

        try await Task.sleep(for: .milliseconds(350))
        conn.autoRespond = { m in
            if case .replacePrompt = m { return .replacePromptResult(status: "failed", message: "Draft mirror lost") }
            return nil
        }
        await coordinator.undoOptimize()
        XCTAssertNotNil(coordinator.optimizerUndo, "still inside the original window")

        // t ≈ 650 ms: past the original 500 ms deadline, but well short of the
        // ~850 ms a window re-armed at the failure would have run to.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(coordinator.optimizerUndo, "the window must not have been extended")
    }

    /// `undoOptimize` gates on the same `isWandEnabled` the wand does, so a
    /// programmatic tap during recovery cannot fire an RPC.
    func testUndoIsIgnoredWhileRecovering() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: "a", prompt: "b", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertNotNil(coordinator.optimizerUndo)

        coordinator.isRecovering = true
        await coordinator.undoOptimize()
        XCTAssertFalse(conn.sentTypes.contains("replace_prompt"))
        XCTAssertNotNil(coordinator.optimizerUndo)
        coordinator.isRecovering = false
    }

    /// A toast from the previous tap must not survive into the next attempt's
    /// result — `Optimizer unavailable` beside `Optimized · Undo` reads as a
    /// contradiction.
    func testNewOptimizeDismissesTheStaleNotice() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "failed", original: nil, prompt: nil, message: "Something broke"))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertEqual(coordinator.optimizerNotice, "Something broke")

        respondToOptimize(.optimizePromptResult(status: "ok", original: "a", prompt: "b", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertNil(coordinator.optimizerNotice, "the previous failure's toast must be gone")
        XCTAssertNotNil(coordinator.optimizerUndo)
    }

    func testTearDownClearsOptimizerState() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: "a", prompt: "b", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertNotNil(coordinator.optimizerUndo)
        coordinator.tearDown()
        XCTAssertNil(coordinator.optimizerUndo)
        XCTAssertNil(coordinator.optimizerNotice)
    }
}
