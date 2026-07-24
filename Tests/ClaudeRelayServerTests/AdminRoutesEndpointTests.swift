import XCTest
import NIOCore
import NIOHTTP1
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class AdminRoutesEndpointTests: SessionManagerTestCase {

    private func route(
        _ method: HTTPMethod,
        _ uri: String,
        body: [String: Any]? = nil,
        manager: SessionManager? = nil
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
            tokenStore: tokenStore
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
            tokenStore: tokenStore
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
            tokenStore: tokenStore
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
}
