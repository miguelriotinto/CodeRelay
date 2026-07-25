import XCTest
import Foundation
import NIO
import NIOPosix
import ClaudeRelayKit
@testable import ClaudeRelayServer
@testable import ClaudeRelayClient

/// Integration tests that spin up a real `WebSocketServer` and exercise the
/// full client → server → client round trip via `RelayConnection` and
/// `SessionController`.
///
/// `MockPTYSession` is defined in `SessionManagerTestCase.swift` and shared
/// across the session-management test suites.
final class WebSocketIntegrationTests: XCTestCase {

    /// End-to-end smoke test: start a real `WebSocketServer`, connect a
    /// `RelayConnection` + `SessionController`, authenticate with a freshly
    /// minted token, and verify the controller transitions to authenticated.
    @MainActor
    func testClientAuthenticatesAgainstRealServer() async throws {
        // Scratch directory for TokenStore persistence.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        // Random high ports to avoid collisions with a locally-running dev server.
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, _) = try await tokenStore.create(label: "integration")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let server = WebSocketServer(
            group: group,
            config: config,
            sessionManager: sessionManager,
            tokenStore: tokenStore
        )
        try await server.start()

        // Small delay so the listening socket is ready to accept.
        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(
            name: "IntegrationTest",
            host: "127.0.0.1",
            port: config.wsPort
        )

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)

        XCTAssertTrue(controller.isAuthenticated,
                      "Controller should report authenticated after successful auth_request")
        XCTAssertTrue(controller.isAuthValid,
                      "Auth should be valid on the current connection generation")

        connection.disconnect()

        // Shut down the server while the event loop is still live — this avoids
        // NIO's "Cannot schedule tasks on an EventLoop that has already shut down"
        // warning that occurs when close work is scheduled from a defer after
        // `group.syncShutdownGracefully()` has already run.
        try? await server.stop()
    }

    /// A redundant `auth_request` on a socket the server already considers
    /// authenticated must be idempotent: the server replies
    /// `.error(400, "Already authenticated")`, and the client must treat that
    /// as success (the socket IS usable) rather than throwing
    /// `unexpectedResponse("error")`. Regression for the iOS "Unexpected server
    /// response: error" that blocked session creation — a client/server
    /// auth-state desync (e.g. re-auth after a reconnect where the server still
    /// held the socket authenticated) fell through to `authenticate()`'s
    /// `default` branch, whose detail is `ServerMessage.error`'s type string,
    /// literally "error".
    @MainActor
    func testRedundantAuthOnAuthenticatedSocketIsIdempotent() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegrationReauth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, _) = try await tokenStore.create(label: "reauth")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let server = WebSocketServer(
            group: group,
            config: config,
            sessionManager: sessionManager,
            tokenStore: tokenStore
        )
        try await server.start()
        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(name: "ReauthTest", host: "127.0.0.1", port: config.wsPort)

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)
        XCTAssertTrue(controller.isAuthenticated)

        // Second auth on the SAME still-authenticated socket. The server replies
        // .error(400, "Already authenticated"); the client must not throw.
        try await controller.authenticate(token: plaintext)
        XCTAssertTrue(controller.isAuthenticated,
                      "A redundant auth must leave the controller authenticated, not throw")

        // And the socket must still be usable — creating a session must succeed,
        // proving the desync didn't wedge the connection.
        let sessionId = try await controller.createSession(name: "after-reauth")
        XCTAssertNotNil(sessionId)

        connection.disconnect()
        try? await server.stop()
    }

    /// After `forceReconnect`, the client should obtain a fresh connection
    /// generation and be able to re-authenticate successfully against the
    /// still-running server. This is a lighter-weight proxy for the full
    /// server-restart recovery flow (which is owned by SharedSessionCoordinator
    /// and requires significantly more test scaffolding to exercise end-to-end).
    @MainActor
    func testForceReconnectPreservesAuthFlowAgainstRealServer() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegrationReconnect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, _) = try await tokenStore.create(label: "reconnect")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let server = WebSocketServer(
            group: group,
            config: config,
            sessionManager: sessionManager,
            tokenStore: tokenStore
        )
        try await server.start()

        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(
            name: "ReconnectTest",
            host: "127.0.0.1",
            port: config.wsPort
        )

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)
        let genBefore = connection.generation
        XCTAssertTrue(controller.isAuthenticated)

        // Force a fresh transport. The stored config/token should let the
        // client reconnect without the caller re-supplying them.
        try await connection.forceReconnect()

        // After reconnect, auth must be re-asserted (a new unauthenticated
        // handler on the server side). The controller's own auth bit is sticky
        // across forceReconnect but `isAuthValid` reads through generation and
        // should correctly report stale.
        XCTAssertGreaterThan(connection.generation, genBefore,
                             "forceReconnect must bump the generation")
        controller.resetAuth()
        try await controller.authenticate(token: plaintext)
        XCTAssertTrue(controller.isAuthenticated)
        XCTAssertTrue(controller.isAuthValid)

        connection.disconnect()
        try? await server.stop()
    }

    /// A brute-force scanner repeatedly reconnecting and sending the wrong
    /// token must eventually hit the shared RateLimiter and be rejected with
    /// a 429 on connect — the per-connection `maxAuthAttempts` cap alone is
    /// not enough because an attacker can just reconnect.
    @MainActor
    func testBruteForceAuthIsRateLimited() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegrationRL-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        _ = try await tokenStore.create(label: "valid")

        // Tight limiter so we hit the cap quickly in the test.
        let limiter = RateLimiter(maxAttempts: 3, windowSeconds: 60)

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let server = WebSocketServer(
            group: group, config: config,
            sessionManager: sessionManager, tokenStore: tokenStore,
            rateLimiter: limiter
        )
        try await server.start()
        defer { Task { try? await server.stop() } }
        try? await Task.sleep(for: .milliseconds(100))

        let clientConfig = ConnectionConfig(
            name: "RLTest", host: "127.0.0.1", port: config.wsPort
        )

        // Drive three auth failures. Each uses a fresh connection — this is
        // the brute-force pattern that the per-connection authAttempts cap
        // alone could not stop.
        for _ in 0..<3 {
            let conn = RelayConnection()
            let ctrl = SessionController(connection: conn)
            try await conn.connect(config: clientConfig, token: "wrong")
            do {
                try await ctrl.authenticate(token: "wrong")
                XCTFail("Expected auth failure")
            } catch {
                // expected
            }
            conn.disconnect()
        }

        // Wait for the async recordFailure Task to settle on the limiter.
        var blocked = false
        var trackedCount = 0
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            blocked = await limiter.isBlocked(ip: "127.0.0.1")
            trackedCount = await limiter._testOnly_trackedIPCount
            if blocked { break }
        }
        if !blocked {
            let recent = RelayLogger.store.recent(count: 30).joined(separator: "\n")
            XCTFail("Limiter not blocking 127.0.0.1. trackedIPs=\(trackedCount). Recent server log:\n\(recent)")
            return
        }

        // A fresh connection attempt from the same IP should now be bounced
        // with a 429 before the server even accepts an auth_request.
        let blockedConn = RelayConnection()
        let blockedCtrl = SessionController(connection: blockedConn)
        try await blockedConn.connect(config: clientConfig, token: "wrong")
        do {
            try await blockedCtrl.authenticate(token: "wrong")
            XCTFail("Expected rejection by rate limiter")
        } catch {
            // The server will either:
            // (a) emit the 429 error frame and close, or
            // (b) close before the auth round-trip completes.
            // Both cases surface as an error here.
        }
        blockedConn.disconnect()

        XCTAssertFalse(blockedCtrl.isAuthenticated,
            "Rate-limited connection must not have authenticated")
    }

    /// C-13 regression: rapid session-attach churn on a single handler must
    /// not leave `attachedSessionId`/`attachedPTY` in a torn state. Before
    /// this fix, `autoDetachIfNeeded` wrote those fields from a Task context
    /// rather than the event loop, so two back-to-back attaches could race.
    @MainActor
    func testRapidSessionSwitchKeepsHandlerStateConsistent() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegrationSwitch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, tokenInfo) = try await tokenStore.create(label: "switch")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        // Pre-create three sessions so the attach churn has real targets.
        let sessionA = try await sessionManager.createSession(tokenId: tokenInfo.id, name: "A")
        let sessionB = try await sessionManager.createSession(tokenId: tokenInfo.id, name: "B")
        let sessionC = try await sessionManager.createSession(tokenId: tokenInfo.id, name: "C")

        let server = WebSocketServer(
            group: group, config: config,
            sessionManager: sessionManager, tokenStore: tokenStore
        )
        try await server.start()
        defer { Task { try? await server.stop() } }
        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(name: "switch", host: "127.0.0.1", port: config.wsPort)

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)

        // Alternate attaches faster than the server can finish auto-detach.
        // We ignore per-call errors because the server may reject a race loser.
        for _ in 0..<5 {
            try? await controller.attachSession(id: sessionA.id)
            try? await controller.attachSession(id: sessionB.id)
            try? await controller.attachSession(id: sessionC.id)
        }

        // Final deterministic attach — after this call the server's view of
        // ownership must be self-consistent (sessionC attached to our token).
        try await controller.attachSession(id: sessionC.id)

        let final = try await sessionManager.inspectSession(id: sessionC.id)
        XCTAssertEqual(final.state, .activeAttached)
        XCTAssertEqual(final.tokenId, tokenInfo.id)

        connection.disconnect()
    }

    /// Regression: creating a session must NOT send the creating connection a
    /// `session_stolen` push for the session it just created. `handleSessionCreate`
    /// creates then immediately attaches; if the attach doesn't exclude the
    /// creator's own steal observer, the creator is told it "stole" its own new
    /// session. On iOS this drives `handleSessionStolen` to tear the session down
    /// and surface "Unexpected server response" / a spurious "Session Moved" alert.
    @MainActor
    func testCreateSessionDoesNotSelfSteal() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegrationSelfSteal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, _) = try await tokenStore.create(label: "self-steal")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let server = WebSocketServer(
            group: group, config: config,
            sessionManager: sessionManager, tokenStore: tokenStore
        )
        try await server.start()
        defer { Task { try? await server.stop() } }
        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(name: "self-steal", host: "127.0.0.1", port: config.wsPort)

        var stolenSessionIds: [UUID] = []
        connection.onSessionStolen = { id in
            stolenSessionIds.append(id)
        }

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)

        let createdId = try await controller.createSession(name: "fresh")

        // Give any (erroneous) steal push time to arrive on this connection.
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(stolenSessionIds.contains(createdId),
            "Creating connection must not receive a session_stolen for the session it just created")

        connection.disconnect()
    }

    /// Verifies that `replayComplete` is emitted after scrollback binary data
    /// and before `sessionActivity` when attaching to a session with history.
    @MainActor
    func testAttachEmitsReplayCompleteAfterScrollback() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegrationReplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, tokenInfo) = try await tokenStore.create(label: "replay")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let sessionInfo = try await sessionManager.createSession(tokenId: tokenInfo.id, name: "replay-test")

        // Write scrollback data into the session's mock PTY buffer so attach
        // has something to replay.
        let (_, pty) = try await sessionManager.attachSession(id: sessionInfo.id, tokenId: tokenInfo.id)
        let mockPTY = try XCTUnwrap(pty as? MockPTYSession)
        let scrollbackData = Data(repeating: 0x41, count: 1024)
        await mockPTY.writeToBuffer(scrollbackData)
        try await sessionManager.detachSession(id: sessionInfo.id)

        let server = WebSocketServer(
            group: group, config: config,
            sessionManager: sessionManager, tokenStore: tokenStore
        )
        try await server.start()
        defer { Task { try? await server.stop() } }
        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(name: "replay", host: "127.0.0.1", port: config.wsPort)

        // Collect all server messages in order.
        var receivedMessages: [String] = []
        var receivedBinaryChunks = 0
        connection.onTerminalOutput = { _ in
            receivedMessages.append("binary")
            receivedBinaryChunks += 1
        }
        connection.onReplayComplete = { _ in
            receivedMessages.append("replay_complete")
        }
        connection.onSessionActivity = { _, _, _, _, _, _ in
            receivedMessages.append("session_activity")
        }

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)
        try await controller.attachSession(id: sessionInfo.id)

        // Allow server to finish sending all post-attach messages.
        try? await Task.sleep(for: .milliseconds(200))

        // Verify ordering: replay_complete must come after all binary chunks.
        XCTAssertGreaterThan(receivedBinaryChunks, 0, "Should have received scrollback data")
        guard let replayIdx = receivedMessages.firstIndex(of: "replay_complete") else {
            XCTFail("replay_complete not received"); return
        }
        let lastBinaryIdx = receivedMessages.lastIndex(of: "binary")!
        XCTAssertGreaterThan(replayIdx, lastBinaryIdx, "replay_complete must come after all binary chunks")

        connection.disconnect()
    }

    /// Verifies that `replayComplete` is still emitted even when there is no
    /// scrollback data to replay (fresh session, empty buffer).
    @MainActor
    func testAttachEmitsReplayCompleteEvenWithEmptyBuffer() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegrationReplayEmpty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, tokenInfo) = try await tokenStore.create(label: "replay-empty")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        _ = try await sessionManager.createSession(tokenId: tokenInfo.id, name: "empty-test")
        let sessions = await sessionManager.listSessionsForToken(tokenId: tokenInfo.id)
        let sessionId = sessions[0].id

        let server = WebSocketServer(
            group: group, config: config,
            sessionManager: sessionManager, tokenStore: tokenStore
        )
        try await server.start()
        defer { Task { try? await server.stop() } }
        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(name: "replay-empty", host: "127.0.0.1", port: config.wsPort)

        var gotReplayComplete = false
        connection.onReplayComplete = { _ in
            gotReplayComplete = true
        }

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)
        try await controller.attachSession(id: sessionId)

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(gotReplayComplete, "replay_complete must be sent even with empty buffer")

        connection.disconnect()
    }
}
