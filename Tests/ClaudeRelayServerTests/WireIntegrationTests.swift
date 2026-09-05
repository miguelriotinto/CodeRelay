import XCTest
import Foundation
import ClaudeRelayKit
@testable import ClaudeRelayServer

/// The scenarios of `WebSocketIntegrationTests`, driven over the wire by
/// `TestWebSocketClient` instead of `ClaudeRelayClient`, so they run on Linux
/// where the Swift client library does not build (`docs/linux-server-spec.md`
/// AD-8). On macOS both files run; the originals additionally pin the client's
/// interpretation, these pin the server's frames.
final class WireIntegrationTests: XCTestCase {

    /// End-to-end smoke test: start a real `WebSocketServer`, connect, authenticate
    /// with a freshly minted token, and get `auth_success` back.
    func testClientAuthenticatesAgainstRealServer() async throws {
        let fixture = try WireTestServer()
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let (token, _) = try await fixture.mintToken(label: "integration")

        let client = try await fixture.connect()
        try await client.send(.authRequest(token: token, protocolVersion: nil))
        let reply = try await client.waitFor(["auth_success", "auth_failure"])
        guard case .authSuccess(_, let tokenId) = reply else {
            return XCTFail("expected auth_success, got \(reply.typeString)")
        }
        XCTAssertNotNil(tokenId, "auth_success carries the token id the client will be scoped to")
        await client.close()
    }

    /// A redundant `auth_request` on a socket the server already considers
    /// authenticated must be idempotent: the server replies
    /// `.error(400, "Already authenticated")` and the socket stays usable —
    /// creating a session afterwards must still succeed.
    func testRedundantAuthOnAuthenticatedSocketIsIdempotent() async throws {
        let fixture = try WireTestServer()
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let (token, _) = try await fixture.mintToken(label: "reauth")

        let client = try await fixture.authenticatedClient(token: token)

        try await client.send(.authRequest(token: token, protocolVersion: nil))
        do {
            try await client.waitFor(["auth_success"])
            XCTFail("a second auth on an authenticated socket must be answered with error 400")
        } catch let error as TestWebSocketClient.ReplyError {
            XCTAssertEqual(error.code, 400)
            XCTAssertEqual(error.message, "Already authenticated")
        }

        // And the socket must still be usable — the desync must not wedge it.
        let sessionId = try await client.createSession(name: "after-reauth")
        XCTAssertNotNil(sessionId)
        await client.close()
    }

    /// A fresh transport to the still-running server starts unauthenticated on
    /// the server side and must accept a new `auth_request` — the wire half of
    /// `forceReconnect`.
    func testReconnectPreservesAuthFlowAgainstRealServer() async throws {
        let fixture = try WireTestServer()
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let (token, _) = try await fixture.mintToken(label: "reconnect")

        let first = try await fixture.authenticatedClient(token: token)
        await first.close()

        let second = try await fixture.connect()
        // Unauthenticated socket: a session request must be refused, proving the
        // server did not carry auth state across sockets.
        try await second.send(.sessionCreate(name: "premature", cols: 80, rows: 24))
        do {
            try await second.waitFor(["session_created"])
            XCTFail("an unauthenticated socket must not create sessions")
        } catch let error as TestWebSocketClient.ReplyError {
            XCTAssertEqual(error.code, 401)
        }
        try await second.authenticate(token: token)
        _ = try await second.createSession(name: "after-reconnect")
        await second.close()
    }

    /// A brute-force scanner repeatedly reconnecting and sending the wrong token
    /// must hit the shared RateLimiter and be rejected with a 429 on connect —
    /// the per-connection `maxAuthAttempts` cap alone is not enough because an
    /// attacker can just reconnect.
    func testBruteForceAuthIsRateLimited() async throws {
        // Tight limiter so we hit the cap quickly in the test.
        let fixture = try WireTestServer(rateLimiter: RateLimiter(maxAttempts: 3, windowSeconds: 60))
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        _ = try await fixture.mintToken(label: "valid")

        // Drive three auth failures, each on a fresh connection.
        for _ in 0..<3 {
            let client = try await fixture.connect()
            do {
                try await client.authenticate(token: "wrong")
                XCTFail("Expected auth failure")
            } catch {
                // expected
            }
            await client.close()
        }

        // Wait for the async recordFailure Task to settle on the limiter.
        var blocked = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            blocked = await fixture.rateLimiter.isBlocked(ip: "127.0.0.1")
            if blocked { break }
        }
        XCTAssertTrue(blocked, "Limiter must block 127.0.0.1 after three failures")

        // A fresh connection from the same IP is now bounced with a 429 before an
        // auth_request is even considered — as an error frame, a close, or both.
        do {
            let client = try await fixture.connect()
            try await client.authenticate(token: "wrong")
            XCTFail("Expected rejection by rate limiter")
            await client.close()
        } catch let error as TestWebSocketClient.ReplyError {
            XCTAssertEqual(error.code, 429, "got \(error)")
        } catch {
            // The server closed before the auth round-trip completed: also a rejection.
        }
    }

    /// C-13 regression: rapid session-attach churn on a single handler must not
    /// leave `attachedSessionId`/`attachedPTY` in a torn state.
    func testRapidSessionSwitchKeepsHandlerStateConsistent() async throws {
        let fixture = try WireTestServer()
        let (token, tokenInfo) = try await fixture.mintToken(label: "switch")

        // Pre-create three sessions so the attach churn has real targets.
        let sessionA = try await fixture.sessionManager.createSession(tokenId: tokenInfo.id, name: "A")
        let sessionB = try await fixture.sessionManager.createSession(tokenId: tokenInfo.id, name: "B")
        let sessionC = try await fixture.sessionManager.createSession(tokenId: tokenInfo.id, name: "C")

        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let client = try await fixture.authenticatedClient(token: token)

        // Alternate attaches faster than the server can finish auto-detach; a
        // race loser may be refused, which is fine.
        for _ in 0..<5 {
            try? await client.attach(sessionA.id)
            try? await client.attach(sessionB.id)
            try? await client.attach(sessionC.id)
        }

        // Final deterministic attach — afterwards the server's view of ownership
        // must be self-consistent (sessionC attached to our token).
        try await client.attach(sessionC.id)

        let final = try await fixture.sessionManager.inspectSession(id: sessionC.id)
        XCTAssertEqual(final.state, .activeAttached)
        XCTAssertEqual(final.tokenId, tokenInfo.id)
        await client.close()
    }

    /// Regression: creating a session must NOT send the creating connection a
    /// `session_stolen` push for the session it just created.
    func testCreateSessionDoesNotSelfSteal() async throws {
        let fixture = try WireTestServer()
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let (token, _) = try await fixture.mintToken(label: "self-steal")

        let client = try await fixture.authenticatedClient(token: token)
        let createdId = try await client.createSession(name: "fresh")

        // Give any (erroneous) steal push time to arrive on this connection.
        let seen = await client.drain(idle: .milliseconds(200))
        let stolen = seen.compactMap { event -> UUID? in
            if case .message(.sessionStolen(let id)) = event { return id }
            return nil
        }
        XCTAssertFalse(stolen.contains(createdId),
            "Creating connection must not receive a session_stolen for the session it just created")
        await client.close()
    }

    /// `replay_complete` is emitted after the scrollback binary frames and before
    /// `session_activity` when attaching to a session with history.
    func testAttachEmitsReplayCompleteAfterScrollback() async throws {
        let fixture = try WireTestServer()
        let (token, tokenInfo) = try await fixture.mintToken(label: "replay")

        let sessionInfo = try await fixture.sessionManager.createSession(tokenId: tokenInfo.id, name: "replay-test")
        // Write scrollback into the mock PTY so attach has something to replay.
        let (_, pty) = try await fixture.sessionManager.attachSession(id: sessionInfo.id, tokenId: tokenInfo.id)
        let mockPTY = try XCTUnwrap(pty as? MockPTYSession)
        await mockPTY.writeToBuffer(Data(repeating: 0x41, count: 1024))
        try await fixture.sessionManager.detachSession(id: sessionInfo.id)

        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let client = try await fixture.authenticatedClient(token: token)

        try await client.send(.sessionAttach(sessionId: sessionInfo.id))
        try await client.waitFor(["session_attached"])

        // Everything after session_attached, in wire order.
        let events = await client.drain(idle: .milliseconds(300))
        let sequence = events.map { event -> String in
            switch event {
            case .binary: return "binary"
            case .message(let message): return message.typeString
            case .closed: return "closed"
            }
        }
        let binaryChunks = sequence.filter { $0 == "binary" }.count
        XCTAssertGreaterThan(binaryChunks, 0, "Should have received scrollback data")
        guard let replayIdx = sequence.firstIndex(of: "replay_complete") else {
            return XCTFail("replay_complete not received; got \(sequence)")
        }
        let lastBinaryIdx = sequence.lastIndex(of: "binary")!
        XCTAssertGreaterThan(replayIdx, lastBinaryIdx, "replay_complete must come after all binary chunks: \(sequence)")
        // The post-replay activity snapshot follows replay_complete. (An earlier
        // session_activity may precede the replay — the attach itself pushes
        // the token's current states — which the contract does not forbid.)
        guard let activityIdx = sequence.lastIndex(of: "session_activity") else {
            return XCTFail("session_activity not received after replay; got \(sequence)")
        }
        XCTAssertGreaterThan(activityIdx, replayIdx, "session_activity follows replay_complete: \(sequence)")
        await client.close()
    }

    /// `replay_complete` is still emitted when there is no scrollback to replay
    /// (fresh session, empty buffer) — clients use it as "you can render now".
    func testAttachEmitsReplayCompleteEvenWithEmptyBuffer() async throws {
        let fixture = try WireTestServer()
        let (token, tokenInfo) = try await fixture.mintToken(label: "replay-empty")
        _ = try await fixture.sessionManager.createSession(tokenId: tokenInfo.id, name: "empty-test")
        let sessionId = await fixture.sessionManager.listSessionsForToken(tokenId: tokenInfo.id)[0].id

        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let client = try await fixture.authenticatedClient(token: token)

        try await client.attach(sessionId)
        try await client.waitFor(["replay_complete"])
        await client.close()
    }
}
