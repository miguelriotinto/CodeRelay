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

final class PromptRequestHandlerTests: XCTestCase {

    /// Every decoded outbound server message, in arrival order. `nextServerMessage`
    /// pops the front instead of returning the first of a batch and dropping the
    /// rest, so "exactly one result" assertions actually see a second result if
    /// the handler produces one.
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [ServerMessage] = []

        func append(_ message: ServerMessage) {
            lock.lock(); defer { lock.unlock() }
            messages.append(message)
        }

        func popFirst() -> ServerMessage? {
            lock.lock(); defer { lock.unlock() }
            return messages.isEmpty ? nil : messages.removeFirst()
        }

        func snapshot() -> [ServerMessage] {
            lock.lock(); defer { lock.unlock() }
            return messages
        }
    }

    private struct Fixture {
        let channel: NIOAsyncTestingChannel
        let handler: RelayMessageHandler
        let mock: MockPTYSession
        let sessionId: UUID
        let tempDir: URL
        let testingLoop: NIOAsyncTestingEventLoop
        let inbox: Inbox
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
        let testingLoop = channel.eventLoop as! NIOAsyncTestingEventLoop
        return Fixture(channel: channel, handler: handler, mock: mock, sessionId: sessionId,
                       tempDir: tempDir, testingLoop: testingLoop, inbox: Inbox())
    }

    private func cleanup(_ fixture: Fixture) async {
        _ = try? await fixture.channel.close()
        try? FileManager.default.removeItem(at: fixture.tempDir)
    }

    private func context(draft: String, bracketedPaste: Bool = false, screen: [String] = [],
                         agentId: String? = "claude", draftKnown: Bool = true) -> PromptContext {
        PromptContext(draft: draft, agentId: agentId, agentDisplayName: "Claude Code",
                      workingDirectory: "/tmp/repo", screenLines: screen,
                      bracketedPaste: bracketedPaste, keyboardFlagsRawValue: 0,
                      draftKnown: draftKnown)
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

    /// Moves every outbound text frame currently buffered into the inbox.
    private func drainIntoInbox(_ fixture: Fixture) async throws {
        for frame in try await drainOutboundFrames(fixture.channel) where frame.opcode == .text {
            let bytes = frame.data.getBytes(at: frame.data.readerIndex, length: frame.data.readableBytes) ?? []
            if case .server(let msg) = try JSONDecoder().decode(MessageEnvelope.self, from: Data(bytes)) {
                fixture.inbox.append(msg)
            }
        }
    }

    /// Pops the oldest un-consumed server message, polling until one arrives (the
    /// handler replies after Task → actor → eventLoop hops) or `timeout` elapses.
    private func nextServerMessage(_ fixture: Fixture, timeout: Duration = .seconds(3)) async throws -> ServerMessage? {
        if let queued = fixture.inbox.popFirst() { return queued }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await drainIntoInbox(fixture)
            if let msg = fixture.inbox.popFirst() { return msg }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await drainIntoInbox(fixture)
        return fixture.inbox.popFirst()
    }

    /// Drains for `settle`, then asserts the inbox is empty — i.e. the handler
    /// produced no further result for a request that is already resolved.
    private func assertNoFurtherMessages(_ fixture: Fixture, settle: Duration = .milliseconds(200),
                                         _ message: String = "no further server message expected",
                                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + settle
        while ContinuousClock.now < deadline {
            try await drainIntoInbox(fixture)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await drainIntoInbox(fixture)
        let remaining = fixture.inbox.snapshot()
        XCTAssertTrue(remaining.isEmpty, "\(message); got \(remaining)", file: file, line: line)
    }

    /// Polls `condition` instead of sleeping a fixed amount.
    private func poll(timeout: Duration = .seconds(2), until condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // MARK: handler-state access (event loop only)

    private func setDeadline(_ deadline: Duration, on fixture: Fixture) async throws {
        let handler = fixture.handler
        try await fixture.testingLoop.submit { handler.optimizeDeadline = deadline }.get()
    }

    private func detach(_ fixture: Fixture) async throws {
        let handler = fixture.handler
        try await fixture.testingLoop.submit {
            handler.attachedSessionId = nil
            handler.attachedPTY = nil
        }.get()
    }

    private func optimizeState(_ fixture: Fixture) async throws
        -> (inFlight: Bool, hasWorkTask: Bool, hasDeadlineTask: Bool) {
        let handler = fixture.handler
        return try await fixture.testingLoop.submit {
            (handler.optimizeInFlight, handler.optimizeWorkTask != nil, handler.optimizeDeadlineTask != nil)
        }.get()
    }

    // MARK: optimize_prompt

    func testOptimizeUnattachedRepliesFailedOnItsOwnResultType() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer(), attached: false)
        addTeardownBlock { await self.cleanup(fixture) }
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed", message: "Session not attached"))
    }

    func testOptimizeForAnotherSessionIsNotAttached() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer())
        addTeardownBlock { await self.cleanup(fixture) }
        try await send(.optimizePrompt(sessionId: UUID(), shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed", message: "Session not attached"))
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testOptimizeWithoutOptimizerIsUnconfigured() async throws {
        let fixture = try await makeFixture(optimizer: nil)
        addTeardownBlock { await self.cleanup(fixture) }
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "unconfigured", message: "Optimizer not configured on the relay"))
    }

    func testOptimizeEmptyDraftIsNoDraftAndDoesNotCallTheModel() async throws {
        let optimizer = FakeOptimizer()
        let fixture = try await makeFixture(optimizer: optimizer)
        addTeardownBlock { await self.cleanup(fixture) }
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
        addTeardownBlock { await self.cleanup(fixture) }
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
        // E3: the bytes go out through `writeReplacement`, so the mirror adopts
        // the prompt the server just pasted instead of re-deriving it from the
        // erase keystrokes it also wrote.
        let adopted = await fixture.mock.recordedAdoptedDrafts()
        XCTAssertEqual(adopted, ["Run `git status`, then fix the failing test."])
        let state = try await optimizeState(fixture)
        XCTAssertFalse(state.inFlight)
    }

    func testOptimizePassthroughWritesNothing() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer(result: .success(.passthrough)))
        addTeardownBlock { await self.cleanup(fixture) }
        await fixture.mock.setMockPromptContext(context(draft: "what does this error mean?"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "passthrough"))
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testOptimizerErrorMapsToItsClientMessage() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer(result: .failure(OptimizerError.refused)))
        addTeardownBlock { await self.cleanup(fixture) }
        await fixture.mock.setMockPromptContext(context(draft: "do the thing"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed", message: OptimizerError.refused.clientMessage))
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    /// The `draftTooLong` / `keyRejected` rows of the spec's error matrix, as
    /// handler cases: the mapping is exercised where the client sees it, not only
    /// in `OptimizerError`'s own unit test.
    func testDraftTooLongFromTheModelIsPromptTooLong() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer(result: .failure(OptimizerError.draftTooLong)))
        addTeardownBlock { await self.cleanup(fixture) }
        await fixture.mock.setMockPromptContext(context(draft: "a very long draft"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed", message: "Prompt too long to optimize"))
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
        let state = try await optimizeState(fixture)
        XCTAssertFalse(state.inFlight)
        try await assertNoFurtherMessages(fixture)
    }

    func testKeyRejectedIsReportedAsKeyRejected() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer(result: .failure(OptimizerError.keyRejected)))
        addTeardownBlock { await self.cleanup(fixture) }
        await fixture.mock.setMockPromptContext(context(draft: "do the thing"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed", message: "Optimizer key rejected on the relay"))
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
        let state = try await optimizeState(fixture)
        XCTAssertFalse(state.inFlight)
        try await assertNoFurtherMessages(fixture)
    }

    func testUnknownErrorIsReportedAsUnavailable() async throws {
        struct Boom: Error {}
        let fixture = try await makeFixture(optimizer: FakeOptimizer(result: .failure(Boom())))
        addTeardownBlock { await self.cleanup(fixture) }
        await fixture.mock.setMockPromptContext(context(draft: "do the thing"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed", message: "Optimizer unavailable, try again"))
    }

    func testDeadlineExpiryIsUnavailableAndClearsInFlight() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer(delay: .seconds(5)))
        addTeardownBlock { await self.cleanup(fixture) }
        try await setDeadline(.milliseconds(150), on: fixture)
        await fixture.mock.setMockPromptContext(context(draft: "slow one"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        // Advance time to trigger the deadline task.
        await fixture.testingLoop.advanceTime(by: TimeAmount.milliseconds(151))
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed", message: "Optimizer unavailable, try again"))
        let state = try await optimizeState(fixture)
        XCTAssertFalse(state.inFlight)
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty, "a late reply must never type into the PTY")
    }

    func testSecondOptimizeWhileInFlightIsRejected() async throws {
        let optimizer = GatedOptimizer()
        let fixture = try await makeFixture(optimizer: optimizer)
        addTeardownBlock { await self.cleanup(fixture) }
        await fixture.mock.setMockPromptContext(context(draft: "first"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let started = await poll { await optimizer.callCount() == 1 }
        XCTAssertTrue(started, "the first request must reach the optimizer before the second is sent")
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)

        let first = try await nextServerMessage(fixture)
        XCTAssertEqual(first, .optimizePromptResult(status: "failed", message: "Already optimizing"))
        await optimizer.release(0)
        let second = try await nextServerMessage(fixture)
        XCTAssertEqual(second, .optimizePromptResult(status: "ok", original: "first", prompt: "Run `git status`."))
        // The rejected second request never reached the model.
        let calls = await optimizer.callCount()
        XCTAssertEqual(calls, 1)
        try await assertNoFurtherMessages(fixture)
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
        addTeardownBlock { await self.cleanup(fixture) }
        fixture.handler.isAuthenticated = false
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        // A pre-auth `.error(401)` would resolve the client's authenticate waiter (spec §5.7 step 1).
        try await assertNoFurtherMessages(fixture, settle: .milliseconds(300),
                                          "a pre-auth optimize_prompt must be dropped silently")
    }

    /// The foreground agent changed while the model ran: the tracker was reset
    /// with it, so the erase count would be zero and the rewrite would land as
    /// text at whatever prompt is there now. Answer `failed`, type nothing.
    func testAgentChangeMidFlightFailsWithoutWriting() async throws {
        let optimizer = GatedOptimizer()
        let fixture = try await makeFixture(optimizer: optimizer)
        addTeardownBlock { await self.cleanup(fixture) }
        await fixture.mock.setMockPromptContext(context(draft: "fix the build", agentId: "claude"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let started = await poll { await optimizer.callCount() == 1 }
        XCTAssertTrue(started)
        // The agent exits while the model call is suspended.
        await fixture.mock.setMockPromptContext(context(draft: "fix the build", agentId: nil))
        await optimizer.release(0)

        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed",
                                                     message: "Optimizer could not rewrite this prompt"))
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty, "a rewrite must never be typed at a prompt the tracker no longer models")
        let state = try await optimizeState(fixture)
        XCTAssertFalse(state.inFlight)
        try await assertNoFurtherMessages(fixture)
    }

    // MARK: replace_prompt

    func testReplaceUnattachedFails() async throws {
        let fixture = try await makeFixture(optimizer: nil, attached: false)
        addTeardownBlock { await self.cleanup(fixture) }
        try await send(.replacePrompt(sessionId: fixture.sessionId, text: "x"), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .replacePromptResult(status: "failed", message: "Session not attached"))
    }

    func testReplaceWorksWithoutAnOptimizer() async throws {
        let fixture = try await makeFixture(optimizer: nil)
        addTeardownBlock { await self.cleanup(fixture) }
        let ctx = context(draft: "Run `git status`.")
        await fixture.mock.setMockPromptContext(ctx)
        try await send(.replacePrompt(sessionId: fixture.sessionId, text: "get status"), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .replacePromptResult(status: "ok"))
        let expected = DraftReplacer.bytes(replacing: ctx.draft, with: "get status",
                                           bracketedPaste: false, keyboardFlags: ctx.keyboardFlags)
        let writes = await fixture.mock.recordedWrites()
        XCTAssertEqual(writes, [expected])
        let adopted = await fixture.mock.recordedAdoptedDrafts()
        XCTAssertEqual(adopted, ["get status"])
    }

    func testReplaceTooLongIsRejectedBeforeTouchingThePTY() async throws {
        let fixture = try await makeFixture(optimizer: nil)
        addTeardownBlock { await self.cleanup(fixture) }
        let text = String(repeating: "x", count: RelayMessageHandler.maxReplaceTextBytes + 1)
        try await send(.replacePrompt(sessionId: fixture.sessionId, text: text), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .replacePromptResult(status: "failed", message: "Replacement too long"))
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    /// The cap is inclusive: exactly `maxReplaceTextBytes` is accepted and typed.
    func testReplaceAtExactlyTheCapIsAccepted() async throws {
        let fixture = try await makeFixture(optimizer: nil)
        addTeardownBlock { await self.cleanup(fixture) }
        let text = String(repeating: "x", count: RelayMessageHandler.maxReplaceTextBytes)
        XCTAssertEqual(text.utf8.count, 16_384)
        await fixture.mock.setMockPromptContext(context(draft: "short draft"))
        try await send(.replacePrompt(sessionId: fixture.sessionId, text: text), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .replacePromptResult(status: "ok"))
        let writes = await fixture.mock.recordedWrites()
        XCTAssertEqual(writes.count, 1)
    }

    /// E2: Undo onto a line the server can no longer count would erase nothing
    /// and paste the original into the surviving text. The only safe answer is to
    /// refuse — one `failed` result, no PTY write.
    func testReplaceOnLostMirrorRefusesWithoutWriting() async throws {
        let fixture = try await makeFixture(optimizer: nil)
        addTeardownBlock { await self.cleanup(fixture) }
        await fixture.mock.setMockPromptContext(context(draft: "", draftKnown: false))
        try await send(.replacePrompt(sessionId: fixture.sessionId, text: "the original draft"), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .replacePromptResult(status: "failed",
                                                   message: "Optimizer could not rewrite this prompt"))
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty, "a refused replace must not touch the PTY")
        let adopted = await fixture.mock.recordedAdoptedDrafts()
        XCTAssertTrue(adopted.isEmpty)
        try await assertNoFurtherMessages(fixture)
    }

    /// The converse of the guard above, and the reason it is not
    /// `draft.isEmpty`: a genuinely empty *known* line is the normal state for an
    /// Undo right after the user cleared the box, and pasting the original back
    /// into it is exactly right — the erase prefix is simply empty.
    func testReplaceOnKnownEmptyDraftPastes() async throws {
        let fixture = try await makeFixture(optimizer: nil)
        addTeardownBlock { await self.cleanup(fixture) }
        let ctx = context(draft: "", draftKnown: true)
        await fixture.mock.setMockPromptContext(ctx)
        try await send(.replacePrompt(sessionId: fixture.sessionId, text: "the original draft"), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .replacePromptResult(status: "ok"))
        let expected = DraftReplacer.bytes(replacing: "", with: "the original draft",
                                           bracketedPaste: false, keyboardFlags: ctx.keyboardFlags)
        let writes = await fixture.mock.recordedWrites()
        XCTAssertEqual(writes, [expected])
        XCTAssertTrue(String(decoding: expected, as: UTF8.self).contains("the original draft"))
    }

    func testUnauthenticatedReplaceIsDroppedNotAnswered() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer())
        addTeardownBlock { await self.cleanup(fixture) }
        fixture.handler.isAuthenticated = false
        try await send(.replacePrompt(sessionId: fixture.sessionId, text: "typed by hand"), on: fixture)
        // Same rule as optimize: a pre-auth `.error(401)` would resolve the
        // client's authenticate waiter (spec §5.7 step 1).
        try await assertNoFurtherMessages(fixture, settle: .milliseconds(300),
                                          "a pre-auth replace_prompt must be dropped silently")
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    // MARK: constants

    func testWireConstantsArePinned() async throws {
        XCTAssertEqual(RelayMessageHandler.maxReplaceTextBytes, 16_384)
        XCTAssertEqual(PromptOptimizer.deadline, .seconds(12))
        let fixture = try await makeFixture(optimizer: nil)
        addTeardownBlock { await self.cleanup(fixture) }
        let handler = fixture.handler
        let deadline = try await fixture.testingLoop.submit { handler.optimizeDeadline }.get()
        XCTAssertEqual(deadline, PromptOptimizer.deadline)
    }

    // MARK: lifecycle

    func testDetachWhileOptimizeInFlightPreventsWrite() async throws {
        let optimizer = GatedOptimizer()
        let fixture = try await makeFixture(optimizer: optimizer)
        addTeardownBlock { await self.cleanup(fixture) }
        // Long deadline: this test is about detach, not about the timeout.
        try await setDeadline(.seconds(30), on: fixture)
        await fixture.mock.setMockPromptContext(context(draft: "detach test"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let started = await poll { await optimizer.callCount() == 1 }
        XCTAssertTrue(started, "the model call must be in flight before detaching")

        // Detach on the event loop, exactly like the real detach path.
        try await detach(fixture)
        await optimizer.release(0)

        // The completion hop clears `optimizeInFlight`; that is the observable
        // "the optimizer finished" signal, so no fixed sleep is needed.
        let handler = fixture.handler
        let loop = fixture.testingLoop
        let finished = await poll { (try? await loop.submit { handler.optimizeInFlight }.get()) == false }
        XCTAssertTrue(finished, "the work task must have completed")
        try await assertNoFurtherMessages(fixture, "detached session must not receive replies")
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty, "detached session must not receive PTY writes")
    }

    /// Channel teardown mid-optimize: both handles are dropped, the flag is
    /// released, and the (non-cooperative) work task's late completion is
    /// swallowed because `cleanupOptimizeState` bumped the generation.
    func testChannelCloseMidOptimizeCancelsEverything() async throws {
        let optimizer = FakeOptimizer(delay: .seconds(5))
        let fixture = try await makeFixture(optimizer: optimizer)
        addTeardownBlock { await self.cleanup(fixture) }
        try await setDeadline(.seconds(10), on: fixture)
        await fixture.mock.setMockPromptContext(context(draft: "closing mid-flight"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let started = await poll { await optimizer.received.count == 1 }
        XCTAssertTrue(started, "the model call must be in flight before closing")

        _ = try? await fixture.channel.close()

        let state = try await optimizeState(fixture)
        XCTAssertFalse(state.inFlight)
        XCTAssertFalse(state.hasWorkTask, "the work task handle must be dropped")
        XCTAssertFalse(state.hasDeadlineTask, "the deadline task handle must be dropped")
        // Past both the shortened deadline and the optimizer's own delay.
        await fixture.testingLoop.advanceTime(by: TimeAmount.seconds(11))
        try await assertNoFurtherMessages(fixture, settle: .milliseconds(300),
                                          "a closed channel must not be sent a result")
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty, "a closed channel's optimize must not type into the PTY")
    }

    func testSuccessfulOptimizeFollowedByDeadlineYieldsOnlyOneResult() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer(delay: .zero))
        addTeardownBlock { await self.cleanup(fixture) }
        try await setDeadline(.milliseconds(150), on: fixture)
        await fixture.mock.setMockPromptContext(context(draft: "fast one"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let firstReply = try await nextServerMessage(fixture)
        XCTAssertEqual(firstReply, .optimizePromptResult(status: "ok", original: "fast one", prompt: "Run `git status`."))
        // Advance past the deadline - should NOT send a second result.
        await fixture.testingLoop.advanceTime(by: TimeAmount.milliseconds(151))
        try await assertNoFurtherMessages(fixture, settle: .milliseconds(100),
                                          "deadline task must not fire after successful completion")
    }

    func testTimeoutFollowedByModelCompletionYieldsNoWriteAndNoSecondResult() async throws {
        let optimizer = SlowThenFastOptimizer()
        let fixture = try await makeFixture(optimizer: optimizer)
        addTeardownBlock { await self.cleanup(fixture) }
        try await setDeadline(.milliseconds(150), on: fixture)
        await fixture.mock.setMockPromptContext(context(draft: "timeout then complete"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        // Advance time to trigger timeout.
        await fixture.testingLoop.advanceTime(by: TimeAmount.milliseconds(151))
        let timeoutReply = try await nextServerMessage(fixture)
        XCTAssertEqual(timeoutReply, .optimizePromptResult(status: "failed", message: "Optimizer unavailable, try again"))
        // Now complete the model call - should send nothing, write nothing.
        await optimizer.complete()
        try await assertNoFurtherMessages(fixture, settle: .milliseconds(200),
                                          "late model completion must not send a second result")
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty, "late model completion must not write PTY")
    }

    /// Request A times out; request B is accepted and answered; A's late model
    /// answer must resolve nothing — its generation is stale — so B's waiter sees
    /// exactly one `ok` and the PTY is typed exactly once.
    func testLateOkAfterSecondOptimizeIsSuppressed() async throws {
        // Call 0 (request A) parks until released; call 1 (request B) returns at once.
        let optimizer = GatedOptimizer(gatedCalls: [0])
        let fixture = try await makeFixture(optimizer: optimizer)
        addTeardownBlock { await self.cleanup(fixture) }
        try await setDeadline(.milliseconds(150), on: fixture)
        await fixture.mock.setMockPromptContext(context(draft: "request A"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let startedA = await poll { await optimizer.callCount() == 1 }
        XCTAssertTrue(startedA)

        // A times out.
        await fixture.testingLoop.advanceTime(by: TimeAmount.milliseconds(151))
        let timeoutReply = try await nextServerMessage(fixture)
        XCTAssertEqual(timeoutReply, .optimizePromptResult(status: "failed", message: "Optimizer unavailable, try again"))

        // B is accepted (the flag was released) and completes immediately.
        await fixture.mock.setMockPromptContext(context(draft: "request B"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let okReply = try await nextServerMessage(fixture)
        XCTAssertEqual(okReply, .optimizePromptResult(status: "ok", original: "request B", prompt: "Run `git status`."))

        // A finally answers. It must not produce a second `ok` for B's waiter,
        // and must not type A's rewrite over B's.
        await optimizer.release(0)
        try await assertNoFurtherMessages(fixture, settle: .milliseconds(250),
                                          "a stale request must not answer a later one")
        let writes = await fixture.mock.recordedWrites()
        XCTAssertEqual(writes.count, 1, "only the accepted request may type")
    }

    func testNeverReturningOptimizerTimesOutAndReleasesFlag() async throws {
        let fixture = try await makeFixture(optimizer: HangingOptimizer())
        addTeardownBlock { await self.cleanup(fixture) }
        try await setDeadline(.milliseconds(150), on: fixture)
        await fixture.mock.setMockPromptContext(context(draft: "hang"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        // Advance time to trigger the first deadline task.
        await fixture.testingLoop.advanceTime(by: TimeAmount.milliseconds(151))
        let firstReply = try await nextServerMessage(fixture)
        XCTAssertEqual(firstReply, .optimizePromptResult(status: "failed", message: "Optimizer unavailable, try again"))
        // Second request is accepted (not "Already optimizing").
        await fixture.mock.setMockPromptContext(context(draft: "second"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        // Advance time to trigger the second deadline task.
        await fixture.testingLoop.advanceTime(by: TimeAmount.milliseconds(151))
        let secondReply = try await nextServerMessage(fixture)
        XCTAssertEqual(secondReply, .optimizePromptResult(status: "failed", message: "Optimizer unavailable, try again"))
        try await assertNoFurtherMessages(fixture, "two requests, two results")
        // No PTY writes from either timed-out request.
        let writes = await fixture.mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testWhitespaceOnlyDraftIsNoDraft() async throws {
        let fixture = try await makeFixture(optimizer: FakeOptimizer())
        addTeardownBlock { await self.cleanup(fixture) }
        await fixture.mock.setMockPromptContext(context(draft: "   \n\t  "))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "no_draft"))
    }

    /// `original` echoes the draft as it was *before* the model call, while the
    /// erase is sized from the draft re-read *after* it — an edit made while the
    /// model ran is erased correctly and the client's Undo still restores what
    /// the user originally typed.
    func testOriginalIsThePreCallDraftButTheEraseUsesTheReReadDraft() async throws {
        let optimizer = FakeOptimizer(delay: .milliseconds(200))
        let fixture = try await makeFixture(optimizer: optimizer)
        addTeardownBlock { await self.cleanup(fixture) }
        await fixture.mock.setMockPromptContext(context(draft: "hello"))
        try await send(.optimizePrompt(sessionId: fixture.sessionId, shareScreen: true), on: fixture)
        let captured = await poll { await optimizer.received.count == 1 }
        XCTAssertTrue(captured, "the pre-call context must be captured before the draft is edited")
        // The user keeps typing while the model runs.
        let edited = context(draft: "hello world")
        await fixture.mock.setMockPromptContext(edited)

        let reply = try await nextServerMessage(fixture)
        XCTAssertEqual(reply, .optimizePromptResult(status: "ok", original: "hello", prompt: "Run `git status`."))
        let expected = DraftReplacer.bytes(replacing: "hello world", with: "Run `git status`.",
                                           bracketedPaste: false, keyboardFlags: edited.keyboardFlags)
        let writes = await fixture.mock.recordedWrites()
        XCTAssertEqual(writes, [expected], "the erase must be sized from the re-read draft")
    }
}
