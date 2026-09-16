import XCTest
import Foundation
import NIOPosix
import AsyncHTTPClient
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
        // The undo erases the draft the PTY reports *now*. Against a real PTY that
        // would be the optimized prompt just typed; the mock's context is fixed, so
        // the erase is sized from `ctx.draft` — assert the bytes the mock's own
        // state implies rather than only the write count.
        let expectedUndo = DraftReplacer.bytes(replacing: ctx.draft, with: ctx.draft,
                                               bracketedPaste: false, keyboardFlags: ctx.keyboardFlags)
        let finalWrites = await mock.recordedWrites()
        XCTAssertEqual(finalWrites, [expected, expectedUndo])
        await client.close()
    }

    /// T2 gap 3: `promptOptimizerEnabled = true` with a key the relay cannot read
    /// is a *different config* from disabled, and it has to look identical on the
    /// wire — the capability means "enabled AND the key was readable at startup"
    /// (spec §8), so a client whose wand is dimmed can trust that the relay cannot
    /// optimize, not merely that it was configured to try. The factory makes that
    /// decision once at startup, so the test drives the real factory into the real
    /// socket rather than passing `nil` by hand.
    func testEnabledWithAnUnreadableKeyAdvertisesNoCapability() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-key-\(UUID().uuidString)").path
        var httpClient: HTTPClient?
        let optimizer = PromptOptimizerFactory.make(config: config, group: group, out: &httpClient)
        if let httpClient { try await httpClient.shutdown() }
        try await group.shutdownGracefully()
        XCTAssertNil(optimizer, "an unreadable key must not produce an optimizer")

        let fixture = try WireTestServer(optimizer: optimizer)
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let (token, _) = try await fixture.mintToken(label: "badkey")
        let client = try await fixture.connect()

        let capabilities = try await authSuccess(client, token: token)
        XCTAssertNil(capabilities, "enabled-with-a-bad-key must look exactly like disabled")

        let id = try await client.createSession(name: "s")
        try await client.attach(id)
        try await client.send(.optimizePrompt(sessionId: id, shareScreen: true))
        let reply = try await client.waitFor(["optimize_prompt_result"])
        XCTAssertEqual(reply, .optimizePromptResult(status: "unconfigured",
                                                    message: "Optimizer not configured on the relay"))
        await client.close()
    }

    /// T2 gap 4: `minProtocolVersion` is 0, so a client that predates the
    /// optimizer must keep working against a v2 relay. It sends
    /// `protocolVersion: 1`, ignores the two fields it does not know about, and
    /// runs sessions exactly as before; the server states its own version rather
    /// than echoing the client's.
    func testProtocolV1ClientRunsSessionsOnTheV2Server() async throws {
        let fixture = try WireTestServer(optimizer: FakeOptimizer())
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let (token, _) = try await fixture.mintToken(label: "v1")
        let client = try await fixture.connect()

        try await client.send(.authRequest(token: token, protocolVersion: 1))
        let reply = try await client.waitFor(["auth_success"])
        guard case .authSuccess(let version, let tokenId, let capabilities) = reply else {
            return XCTFail("expected auth_success, got \(reply)")
        }
        XCTAssertEqual(version, CodeRelayKit.protocolVersion,
                       "the server states its own version, it does not echo the client's")
        XCTAssertNotNil(tokenId)
        XCTAssertEqual(capabilities, [CodeRelayKit.promptOptimizerCapability],
                       "the capability is advertised regardless; a v1 decoder ignores the field")

        // The rest of the protocol is unchanged for this client.
        let id = try await client.createSession(name: "legacy")
        try await client.attach(id)
        try await client.send(.sessionList)
        let list = try await client.waitFor(["session_list_result"])
        guard case .sessionList(let sessions) = list else {
            return XCTFail("expected session_list_result, got \(list)")
        }
        XCTAssertTrue(sessions.contains { $0.id == id })
        try await client.detach()
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
