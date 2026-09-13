import XCTest
import NIOCore
import NIOHTTP1
@testable import CodeRelayServer
@testable import CodeRelayKit

final class AdminRoutesEndpointTests: SessionManagerTestCase {

    private func route(
        _ method: HTTPMethod,
        _ uri: String,
        body: [String: Any]? = nil,
        manager: SessionManager? = nil,
        config: RelayConfig = .default,
        optimizer: (any PromptOptimizing)? = nil
    ) async -> (status: Int, json: [String: Any]?) {
        var buf: ByteBuffer?
        if let body {
            if let data = try? JSONSerialization.data(withJSONObject: body) {
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                buf = buffer
            }
        }

        let response = await AdminRoutes.handle(
            method: method,
            uri: uri,
            body: buf,
            sessionManager: manager ?? makeManager(),
            tokenStore: tokenStore,
            pairingStore: PairingCodeStore(),
            config: config,
            optimizer: optimizer
        )

        let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        return (response.statusCode, json)
    }

    // MARK: - Health

    func testHealthEndpoint() async throws {
        let (status, json) = await route(.GET, "/health")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json?["status"] as? String, "ok")
    }

    // MARK: - Status

    func testStatusEndpoint() async throws {
        let (status, json) = await route(.GET, "/status")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json?["status"] as? String, "running")
        XCTAssertNotNil(json?["version"])
        XCTAssertNotNil(json?["pid"])
        XCTAssertNotNil(json?["session_count"])
        // Uptime is derived from the kernel-reported process start time, not a
        // lazily-initialized `Date()`. It must be a valid non-negative integer.
        let uptime = try XCTUnwrap(json?["uptime_seconds"] as? Int)
        XCTAssertGreaterThanOrEqual(uptime, 0)
    }

    // MARK: - Sessions

    func testGetSessionsEmpty() async throws {
        let (status, _) = await route(.GET, "/sessions")
        XCTAssertEqual(status, 200)
    }

    func testGetSessionsAfterCreation() async throws {
        let manager = makeManager()
        let (_, token) = try await createTestToken()
        _ = try await manager.createSession(tokenId: token.id, cols: 80, rows: 24)

        let response = await AdminRoutes.handle(
            method: .GET,
            uri: "/sessions",
            body: nil,
            sessionManager: manager,
            tokenStore: tokenStore,
            pairingStore: PairingCodeStore(),
            config: .default
        )
        XCTAssertEqual(response.statusCode, 200)
        let arr = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
        XCTAssertEqual(arr?.count, 1)
    }

    func testDeleteNonExistentSessionReturns404() async throws {
        let (status, json) = await route(.DELETE, "/sessions/\(UUID().uuidString)")
        XCTAssertEqual(status, 404)
        XCTAssertNotNil(json?["error"])
    }

    // MARK: - Tokens

    func testPostTokensCreatesToken() async throws {
        let (status, json) = await route(.POST, "/tokens", body: ["label": "new-token"])
        XCTAssertEqual(status, 201)
        XCTAssertNotNil(json?["token"], "Response should contain plaintext token")
        XCTAssertEqual(json?["label"] as? String, "new-token")
    }

    func testGetTokensReturnsAll() async throws {
        _ = try await tokenStore.create(label: "alpha")
        _ = try await tokenStore.create(label: "beta")

        let response = await AdminRoutes.handle(
            method: .GET,
            uri: "/tokens",
            body: nil,
            sessionManager: makeManager(),
            tokenStore: tokenStore,
            pairingStore: PairingCodeStore(),
            config: .default
        )
        XCTAssertEqual(response.statusCode, 200)
        let arr = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
        XCTAssertEqual(arr?.count, 2)
    }

    func testDeleteTokenEndpoint() async throws {
        let (_, info) = try await tokenStore.create(label: "deletable")

        let (status, _) = await route(.DELETE, "/tokens/\(info.id)")
        XCTAssertEqual(status, 200)

        let all = await tokenStore.list()
        XCTAssertTrue(all.isEmpty)
    }

    func testDeleteNonExistentTokenReturns404() async throws {
        let (status, json) = await route(.DELETE, "/tokens/nonexistent")
        XCTAssertEqual(status, 404)
        XCTAssertNotNil(json?["error"])
    }

    func testPatchTokenRename() async throws {
        let (_, info) = try await tokenStore.create(label: "old-name")

        let (status, json) = await route(.PATCH, "/tokens/\(info.id)", body: ["label": "new-name"])
        XCTAssertEqual(status, 200)

        let listed = await tokenStore.list()
        XCTAssertEqual(listed.first?.label, "new-name")
    }

    // MARK: - Config

    func testGetConfigEndpoint() async throws {
        let (status, json) = await route(.GET, "/config")
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(json?["wsPort"])
        XCTAssertNotNil(json?["adminPort"])
    }

    // MARK: - Logs

    func testGetLogsEndpoint() async throws {
        let (status, json) = await route(.GET, "/logs")
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(json?["entries"])
    }

    // MARK: - Unknown route

    func testUnknownRouteReturns404() async throws {
        let (status, json) = await route(.GET, "/nonexistent")
        XCTAssertEqual(status, 404)
        XCTAssertNotNil(json?["error"])
    }

    // MARK: - F6 hook state endpoint

    func testHookStateForActiveSessionReturns200() async throws {
        let manager = makeManager()
        let (_, token) = try await createTestToken()
        let info = try await manager.createSession(tokenId: token.id, cols: 80, rows: 24)
        let (status, json) = await route(
            .POST, "/hook/state",
            body: ["sessionId": info.id.uuidString, "state": "blocked"],
            manager: manager)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json?["ok"] as? Bool, true)
    }

    func testHookStateUnknownSessionReturns404() async throws {
        let (status, json) = await route(
            .POST, "/hook/state",
            body: ["sessionId": UUID().uuidString, "state": "working"])
        XCTAssertEqual(status, 404)
        XCTAssertNotNil(json?["error"])
    }

    func testHookStateInvalidStateReturns400() async throws {
        let manager = makeManager()
        let (_, token) = try await createTestToken()
        let info = try await manager.createSession(tokenId: token.id, cols: 80, rows: 24)
        // "unknown" is a real enum case but not a valid hook-reportable state.
        let (status, _) = await route(
            .POST, "/hook/state",
            body: ["sessionId": info.id.uuidString, "state": "unknown"],
            manager: manager)
        XCTAssertEqual(status, 400)
    }

    func testHookStateMalformedBodyReturns400() async throws {
        let (status, _) = await route(.POST, "/hook/state", body: ["state": "working"])
        XCTAssertEqual(status, 400)
    }

    // MARK: - POST /optimizer/try

    func testOptimizerTryWithoutOptimizerIs503() async {
        let r = await route(.POST, "/optimizer/try", body: ["draft": "fix the tests"])
        XCTAssertEqual(r.status, 503)
        XCTAssertEqual(r.json?["error"] as? String, "Optimizer not configured on the relay")
    }

    func testOptimizerTryRequiresADraft() async {
        let optimizer = FakeOptimizer()
        let r1 = await route(.POST, "/optimizer/try", body: [:], optimizer: optimizer)
        XCTAssertEqual(r1.status, 400)
        let r2 = await route(.POST, "/optimizer/try", body: ["draft": ""], optimizer: optimizer)
        XCTAssertEqual(r2.status, 400)
        let r3 = await route(.POST, "/optimizer/try", body: ["draft": 42], optimizer: optimizer)
        XCTAssertEqual(r3.status, 400)
        let r4 = await route(.POST, "/optimizer/try", optimizer: optimizer)
        XCTAssertEqual(r4.status, 400)
        let received = await optimizer.received
        XCTAssertTrue(received.isEmpty)
    }

    func testOptimizerTryUnknownSubpathIs404() async {
        let r = await route(.POST, "/optimizer/nope", body: ["draft": "x"], optimizer: FakeOptimizer())
        XCTAssertEqual(r.status, 404)
    }

    func testOptimizerTryDraftOnlyReturnsThePrompt() async throws {
        let optimizer = FakeOptimizer(result: .success(.optimized("Run `swift test` and fix what fails.")))
        let r = await route(.POST, "/optimizer/try", body: ["draft": "run tests fix failures"], optimizer: optimizer)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["status"] as? String, "ok")
        XCTAssertEqual(r.json?["prompt"] as? String, "Run `swift test` and fix what fails.")
        let seen = await optimizer.received
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.draft, "run tests fix failures")
        XCTAssertNil(seen.first?.agentId)
        XCTAssertEqual(seen.first?.screenLines, [])
    }

    func testOptimizerTryPassthroughAndFailure() async {
        let pass = await route(.POST, "/optimizer/try", body: ["draft": "what is a monad"],
                               optimizer: FakeOptimizer(result: .success(.passthrough)))
        XCTAssertEqual(pass.status, 200)
        XCTAssertEqual(pass.json?["status"] as? String, "passthrough")

        let fail = await route(.POST, "/optimizer/try", body: ["draft": "x"],
                               optimizer: FakeOptimizer(result: .failure(OptimizerError.keyRejected)))
        XCTAssertEqual(fail.status, 200)
        XCTAssertEqual(fail.json?["status"] as? String, "failed")
        XCTAssertEqual(fail.json?["message"] as? String, OptimizerError.keyRejected.clientMessage)
    }

    func testOptimizerTryUsesTheSessionContextButTheBodyDraftAndNeverWrites() async throws {
        let manager = makeManager()
        let optimizer = FakeOptimizer()
        let (_, token) = try await createTestToken()
        let info = try await manager.createSession(tokenId: token.id, cols: 80, rows: 24)
        guard let mock = await manager.ptySession(for: info.id) as? MockPTYSession else {
            return XCTFail("expected MockPTYSession")
        }
        await mock.setMockPromptContext(PromptContext(
            draft: "the live draft the user is typing", agentId: "codex", agentDisplayName: "Codex",
            workingDirectory: "/tmp/repo", screenLines: ["$ swift test", "error: boom"],
            bracketedPaste: true, keyboardFlagsRawValue: 0))

        let r = await route(.POST, "/optimizer/try",
                            body: ["draft": "probe draft", "sessionId": info.id.uuidString, "shareScreen": true],
                            manager: manager, optimizer: optimizer)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["status"] as? String, "ok")
        let seen = await optimizer.received.first
        XCTAssertEqual(seen?.draft, "probe draft")
        XCTAssertEqual(seen?.agentId, "codex")
        XCTAssertEqual(seen?.workingDirectory, "/tmp/repo")
        XCTAssertEqual(seen?.screenLines, ["$ swift test", "error: boom"])
        let writes = await mock.recordedWrites()
        XCTAssertTrue(writes.isEmpty, "try must never type into the PTY")

        let noScreen = await route(.POST, "/optimizer/try",
                                   body: ["draft": "probe draft", "sessionId": info.id.uuidString, "shareScreen": false],
                                   manager: manager, optimizer: optimizer)
        XCTAssertEqual(noScreen.status, 200)
        let receivedLast = await optimizer.received.last
        XCTAssertEqual(receivedLast?.screenLines, [])
    }

    func testOptimizerTryUnknownSessionIs404() async {
        let r = await route(.POST, "/optimizer/try",
                            body: ["draft": "x", "sessionId": UUID().uuidString], optimizer: FakeOptimizer())
        XCTAssertEqual(r.status, 404)
    }

    func testOptimizerTryOversizedDraftReturns400() async {
        let oversized = String(repeating: "x", count: 4097)
        let r = await route(.POST, "/optimizer/try", body: ["draft": oversized], optimizer: FakeOptimizer())
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(r.json?["error"] as? String, "Prompt too long to optimize")
    }

    func testOptimizerTryTimesOutAt12Seconds() async {
        let suspending = FakeOptimizer(result: .success(.optimized("will never arrive")), delay: .seconds(20))
        let r = await route(.POST, "/optimizer/try", body: ["draft": "wait forever"], optimizer: suspending)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["status"] as? String, "failed")
        XCTAssertEqual(r.json?["message"] as? String, "Optimizer unavailable, try again")
    }
}
