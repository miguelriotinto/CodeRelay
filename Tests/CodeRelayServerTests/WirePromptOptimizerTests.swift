import XCTest
import Foundation
import CodeRelayKit
@testable import CodeRelayServer

/// The optimizer RPCs end to end over a real WebSocket: capability advertising
/// in `auth_success`, the unconfigured path, and the ok path writing the mock PTY.
final class WirePromptOptimizerTests: XCTestCase {

    private func authSuccess(_ client: TestWebSocketClient, token: String) async throws -> [String]? {
        try await client.send(.authRequest(token: token, protocolVersion: CodeRelayKit.protocolVersion))
        let reply = try await client.waitFor(["auth_success"])
        guard case .authSuccess(_, _, let capabilities) = reply else {
            XCTFail("expected auth_success, got \(reply)"); return nil
        }
        return capabilities
    }

    func testRelayWithoutOptimizerAdvertisesNoCapabilityAndAnswersUnconfigured() async throws {
        let fixture = try WireTestServer()
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let (token, _) = try await fixture.mintToken(label: "plain")
        let client = try await fixture.connect()

        let capabilities = try await authSuccess(client, token: token)
        XCTAssertNil(capabilities)

        let id = try await client.createSession(name: "s")
        try await client.attach(id)
        try await client.send(.optimizePrompt(sessionId: id, shareScreen: true))
        let reply = try await client.waitFor(["optimize_prompt_result"])
        XCTAssertEqual(reply, .optimizePromptResult(status: "unconfigured", message: "Optimizer not configured on the relay"))
        await client.close()
    }

    func testRelayWithOptimizerAdvertisesCapabilityAndReplacesTheDraft() async throws {
        let optimizer = FakeOptimizer(result: .success(.optimized("Run the test suite and report failures.")))
        let fixture = try WireTestServer(optimizer: optimizer)
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let (token, _) = try await fixture.mintToken(label: "opt")
        let client = try await fixture.connect()

        let capabilities = try await authSuccess(client, token: token)
        XCTAssertEqual(capabilities, [CodeRelayKit.promptOptimizerCapability])

        let id = try await client.createSession(name: "s")
        try await client.attach(id)
        guard let mock = await fixture.sessionManager.ptySession(for: id) as? MockPTYSession else {
            return XCTFail("expected the mock PTY behind the session")
        }
        let ctx = PromptContext(draft: "run tests tell me what fails", agentId: "claude", agentDisplayName: "Claude Code",
                                workingDirectory: "/tmp/repo", screenLines: [], bracketedPaste: false, keyboardFlagsRawValue: 0)
        await mock.setMockPromptContext(ctx)

        try await client.send(.optimizePrompt(sessionId: id, shareScreen: false))
        let reply = try await client.waitFor(["optimize_prompt_result"])
        XCTAssertEqual(reply, .optimizePromptResult(status: "ok", original: ctx.draft,
                                                    prompt: "Run the test suite and report failures."))
        let expected = DraftReplacer.bytes(replacing: ctx.draft, with: "Run the test suite and report failures.",
                                           bracketedPaste: false, keyboardFlags: ctx.keyboardFlags)
        let writes = await mock.recordedWrites()
        XCTAssertEqual(writes, [expected])

        // Undo over the wire.
        try await client.send(.replacePrompt(sessionId: id, text: ctx.draft))
        let undoReply = try await client.waitFor(["replace_prompt_result"])
        XCTAssertEqual(undoReply, .replacePromptResult(status: "ok"))
        let finalWrites = await mock.recordedWrites()
        XCTAssertEqual(finalWrites.count, 2)
        await client.close()
    }

    func testUnattachedOptimizeIsAnsweredOnItsOwnTypeNotError() async throws {
        let fixture = try WireTestServer(optimizer: FakeOptimizer())
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let (token, _) = try await fixture.mintToken(label: "unattached")
        let client = try await fixture.authenticatedClient(token: token)

        try await client.send(.optimizePrompt(sessionId: UUID(), shareScreen: true))
        // waitFor throws ReplyError on a bare `.error`, which is exactly what must NOT happen.
        let reply = try await client.waitFor(["optimize_prompt_result"])
        XCTAssertEqual(reply, .optimizePromptResult(status: "failed", message: "Session not attached"))
        await client.close()
    }
}
