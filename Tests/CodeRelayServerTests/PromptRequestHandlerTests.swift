import XCTest
import Foundation
import NIO
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import CodeRelayKit
@testable import CodeRelayServer

/// Clipboard implementation that does nothing — pasteImage isn't on the
/// path being tested here.
private struct NoopClipboardService: ClipboardService {
    func pasteImage(_ imageData: Data) -> Bool { true }
}

/// A `PromptOptimizing` double: fixed outcome, optional delay, records what it saw.
actor FakeOptimizer: PromptOptimizing {
    nonisolated let sharesScreen: Bool
    private let result: Result<OptimizerOutcome, Error>
    private let delay: Duration
    private(set) var received: [PromptContext] = []

    init(sharesScreen: Bool = true,
         result: Result<OptimizerOutcome, Error> = .success(.optimized("Run `git status`.")),
         delay: Duration = .zero) {
        self.sharesScreen = sharesScreen
        self.result = result
        self.delay = delay
    }

    func optimize(_ context: PromptContext) async throws -> OptimizerOutcome {
        received.append(context)
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}

final class PromptRequestHandlerTests: XCTestCase {

    private struct Fixture {
        let channel: NIOAsyncTestingChannel
        let handler: RelayMessageHandler
        let mock: MockPTYSession
        let sessionId: UUID
        let tempDir: URL
    }

    private func makeFixture(optimizer: (any PromptOptimizing)?, attached: Bool = true) async throws -> Fixture {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptRequestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tokenStore = TokenStore(directory: tempDir)
        let config = RelayConfig(detachTimeout: 5, scrollbackSize: 4096)
        let manager = SessionManager(
            config: config, tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            })
        let handler = RelayMessageHandler(
            sessionManager: manager, tokenStore: tokenStore,
            rateLimiter: RateLimiter(maxAttempts: 100, windowSeconds: 60),
            clipboardService: NoopClipboardService(),
            pushStore: PushRegistrationStore(directory: tempDir),
            pairingStore: PairingCodeStore(),
            optimizer: optimizer)
        let channel = await NIOAsyncTestingChannel(handler: handler)
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9999)).get()
        try await Task.sleep(for: .milliseconds(30))
        // Drain the auth-timer / connect chatter so tests only see their own replies.
        _ = try await drainOutboundFrames(channel)

        let sessionId = UUID()
        let mock = MockPTYSession(sessionId: sessionId, cols: 80, rows: 24, scrollbackSize: 4096)
        handler.isAuthenticated = true
        if attached {
            handler.attachedSessionId = sessionId
            handler.attachedPTY = mock
        }
        return Fixture(channel: channel, handler: handler, mock: mock, sessionId: sessionId, tempDir: tempDir)
    }

    private func cleanup(_ fixture: Fixture) async {
        _ = try? await fixture.channel.close()
        try? FileManager.default.removeItem(at: fixture.tempDir)
    }

    private func context(draft: String, bracketedPaste: Bool = false, screen: [String] = []) -> PromptContext {
        PromptContext(draft: draft, agentId: "claude", agentDisplayName: "Claude Code",
                      workingDirectory: "/tmp/repo", screenLines: screen,
                      bracketedPaste: bracketedPaste, keyboardFlagsRawValue: 0)
    }

    private func send(_ message: ClientMessage, on fixture: Fixture) async throws {
        let data = try JSONEncoder().encode(MessageEnvelope.client(message))
        var buf = ByteBufferAllocator().buffer(capacity: data.count)
        buf.writeBytes(data)
        try await fixture.channel.writeInbound(WebSocketFrame(fin: true, opcode: .text, data: buf))
    }

    private func drainOutboundFrames(_ channel: NIOAsyncTestingChannel) async throws -> [WebSocketFrame] {
        var frames: [WebSocketFrame] = []
        while let frame: WebSocketFrame = try await channel.readOutbound() { frames.append(frame) }
        return frames
    }

    /// Polls until one server text frame arrives (the handler replies after
    /// Task → actor → eventLoop hops) or `timeout` elapses.
    private func nextServerMessage(_ fixture: Fixture, timeout: Duration = .seconds(3)) async throws -> ServerMessage? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            for frame in try await drainOutboundFrames(fixture.channel) where frame.opcode == .text {
                let bytes = frame.data.getBytes(at: frame.data.readerIndex, length: frame.data.readableBytes) ?? []
                if case .server(let msg) = try JSONDecoder().decode(MessageEnvelope.self, from: Data(bytes)) {
                    return msg
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    // MARK: optimize_prompt

    func testOptimizeUnattachedRepliesFailedOnItsOwnResultType() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer(), attached: false)
        defer { Task { await self.cleanup(fixture) } }
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed", message: "Session not attached"))
    }

    func testOptimizeForAnotherSessionIsNotAttached() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer())
        defer { Task { await self.cleanup(fixture) } }
        try await send(.optimizePrompt(sessionId: UUID(), shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed", message: "Session not attached"))
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testOptimizeWithoutOptimizerIsUnconfigured() async throws {
        let fixture = try await makeFixture(optimizer: nil)
        defer { Task { await self.cleanup(fixture) } }
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "unconfigured", message: "Optimizer not configured on the relay"))
    }

    func testOptimizeEmptyDraftIsNoDraftAndDoesNotCallTheModel() async throws {
        let optimizer = FakeOptimizer()
        let fixture = try await makeFixture(optimizer: optimizer)
        defer { Task { await self.cleanup(fixture) } }
        await fixture.mock.setMockPromptContext(context(draft: ""))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "no_draft"))
        let received = await optimizer.received
        XCTAssertTrue(received.isEmpty)
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testOptimizeOkWritesReplacementAndEchoesOriginalAndPrompt() async throws {
        let optimizer = FakeOptimizer(result: .success(.optimized("Run `git status`, then fix the failing test.")))
        let fixture = try await makeFixture(optimizer: optimizer)
        defer { Task { await self.cleanup(fixture) } }
        let ctx = context(draft: "get status and fix the failing test", bracketedPaste: true)
        await fixture.mock.setMockPromptContext(ctx)

        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)

        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "ok",
                                                     original: "get status and fix the failing test",
                                                     prompt: "Run `git status`, then fix the failing test."))
        let expected = DraftReplacer.bytes(replacing: ctx.draft, with: "Run `git status`, then fix the failing test.",
                                           bracketedPaste: true, keyboardFlags: ctx.keyboardFlags)
        let writes = await fixture.mock.recordedWrites()
        XCTAssertEqual(writes, [expected])
        XCTAssertFalse(fixture.handler.optimizeInFlight)
    }

    func testOptimizePassthroughWritesNothing() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer(result: .success(.passthrough)))
        defer { Task { await self.cleanup(fixture) } }
        await fixture.mock.setMockPromptContext(context(draft: "what does this error mean?"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "passthrough"))
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testOptimizerErrorMapsToItsClientMessage() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer(result: .failure(OptimizerError.refused)))
        defer { Task { await self.cleanup(fixture) } }
        await fixture.mock.setMockPromptContext(context(draft: "do the thing"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed", message: OptimizerError.refused.clientMessage))
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testUnknownErrorIsReportedAsUnavailable() async throws {
        struct Boom: Error {}
        let fixture = try await makeFixture(optimizer: FakeOptimizer(result: .failure(Boom())))
        defer { Task { await self.cleanup(fixture) } }
        await fixture.mock.setMockPromptContext(context(draft: "do the thing"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed", message: "Optimizer unavailable, try again"))
    }

    func testDeadlineExpiryIsUnavailableAndClearsInFlight() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer(delay: .seconds(5)))
        defer { Task { await self.cleanup(fixture) } }
        fixture.handler.optimizeDeadline = .milliseconds(150)
        await fixture.mock.setMockPromptContext(context(draft: "slow one"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        // Advance time to trigger the deadline task.
        (fixture.channel.eventLoop as! EmbeddedEventLoop).advanceTime(by: TimeAmount.milliseconds(151))
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed", message: "Optimizer unavailable, try again"))
        XCTAssertFalse(fixture.handler.optimizeInFlight)
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty, "a late reply must never type into the PTY")
    }

    func testSecondOptimizeWhileInFlightIsRejected() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer(delay: .milliseconds(400)))
        defer { Task { await self.cleanup(fixture) } }
        await fixture.mock.setMockPromptContext(context(draft: "first"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        try await Task.sleep(for: .milliseconds(50))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)

        let first = try await nextServerMessage(fixture)
        XCTAssertEqual(first, .optimizePromptResult(status: "failed", message: "Already optimizing"))
        let second = try await nextServerMessage(fixture)
        XCTAssertEqual(second, .optimizePromptResult(status: "ok", original: "first", prompt: "Run `git status`."))
    }

    func testScreenIsSharedOnlyWhenBothSidesAgree() async throws {
        for (server, client, expectIncluded) in [(true, true, true), (true, false, false), (false, true, false)] {
            let optimizer = FakeOptimizer(sharesScreen: server)
            let fixture = try await makeFixture(optimizer: optimizer)
            // MockPTYSession returns `screenLines` only when asked with includeScreen == true.
            await fixture.mock.setMockPromptContext(context(draft: "fix it", screen: ["$ make", "error: boom"]))
            try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: client), on: fixture)
            _ = try await nextServerMessage(fixture)
            let seen = await optimizer.received.first
            XCTAssertEqual(seen?.screenLines.isEmpty, !expectIncluded, "server=\(server) client=\(client)")
            await cleanup(fixture)
        }
    }

    func testUnauthenticatedOptimizeIsDroppedNotAnswered() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer())
        defer { Task { await self.cleanup(fixture) } }
        fixture.handler.isAuthenticated = false
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        // A pre-auth `.error(401)` would resolve the client's authenticate waiter (spec §5.7 step 1).
        let reply = try await nextServerMessage(fixture, timeout: .milliseconds(300))
        XCTAssertNil(reply)
    }

    // MARK: replace_prompt

    func testReplaceUnattachedFails() async throws {
        let fixture = try await makeFixture(optimizer: nil, attached: false)
        defer { Task { await self.cleanup(fixture) } }
        try await send(.replacePrompt(sessionId: fixture.sessionId, text: "x"), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .replacePromptResult(status: "failed", message: "Session not attached"))
    }

    func testReplaceWorksWithoutAnOptimizer() async throws {
        let fixture = try await makeFixture(optimizer: nil)
        defer { Task { await self.cleanup(fixture) } }
        let ctx = context(draft: "Run `git status`.")
        await fixture.mock.setMockPromptContext(ctx)
        try await send(.replacePrompt(sessionId: fixture.sessionId, text: "get status"), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .replacePromptResult(status: "ok"))
        let expected = DraftReplacer.bytes(replacing: ctx.draft, with: "get status",
                                           bracketedPaste: false, keyboardFlags: ctx.keyboardFlags)
        let writes = await fixture.mock.recordedWrites()
        XCTAssertEqual(writes, [expected])
    }

    func testReplaceTooLongIsRejectedBeforeTouchingThePTY() async throws {
        let fixture = try await makeFixture(optimizer: nil)
        defer { Task { await self.cleanup(fixture) } }
        let text = String(repeating: "x", count: RelayMessageHandler.maxReplaceTextBytes + 1)
        try await send(.replacePrompt(sessionId: fixture.sessionId, text: text), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .replacePromptResult(status: "failed", message: "Replacement too long"))
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testDetachWhileOptimizeInFlightPreventsWrite() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer(delay: .milliseconds(200)))
        defer { Task { await self.cleanup(fixture) } }
        await fixture.mock.setMockPromptContext(context(draft: "detach test"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        // Detach while the optimizer is suspended.
        try await Task.sleep(for: .milliseconds(50))
        fixture.handler.attachedSessionId = nil
        fixture.handler.attachedPTY = nil
        // Wait for the optimizer to complete.
        try await Task.sleep(for: .milliseconds(300))
        // No reply sent (connection moved on), no PTY write.
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty, "detached session must not receive PTY writes")
    }

    func testNeverReturningOptimizerTimesOutAndReleasesFlag() async throws {
        actor HangingOptimizer: PromptOptimizing {
            nonisolated let sharesScreen = true
            func optimize(_ context: PromptContext) async throws -> OptimizerOutcome {
                // Ignores cancellation and never returns.
                while true {
                    try? await Task.sleep(for: .seconds(100))
                }
            }
        }
        let fixture = try await makeFixture(optimizer: HangingOptimizer())
        defer { Task { await self.cleanup(fixture) } }
        fixture.handler.optimizeDeadline = .milliseconds(150)
        await fixture.mock.setMockPromptContext(context(draft: "hang"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        // Advance time to trigger the first deadline task.
        (fixture.channel.eventLoop as! EmbeddedEventLoop).advanceTime(by: TimeAmount.milliseconds(151))
        let firstReply = try await nextServerMessage(fixture)
        XCTAssertEqual(firstReply, .optimizePromptResult(status: "failed", message: "Optimizer unavailable, try again"))
        // Second request is accepted (not "Already optimizing").
        await fixture.mock.setMockPromptContext(context(draft: "second"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        // Advance time to trigger the second deadline task.
        (fixture.channel.eventLoop as! EmbeddedEventLoop).advanceTime(by: TimeAmount.milliseconds(151))
        let secondReply = try await nextServerMessage(fixture)
        XCTAssertEqual(secondReply, .optimizePromptResult(status: "failed", message: "Optimizer unavailable, try again"))
        // No PTY writes from either timed-out request.
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testWhitespaceOnlyDraftIsNoDraft() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer())
        defer { Task { await self.cleanup(fixture) } }
        await fixture.mock.setMockPromptContext(context(draft: "   \n\t  "))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "no_draft"))
    }
}
