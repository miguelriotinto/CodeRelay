import XCTest
import Foundation
import NIO
import NIOPosix
import ClaudeRelayKit
@testable import ClaudeRelayServer
@testable import ClaudeRelayClient

/// Integration coverage for the post-replay repaint (the "garbled replay"
/// fix). Split from `WebSocketIntegrationTests` to keep that file under the
/// SwiftLint length ceilings. `MockPTYSession` is shared from
/// `SessionManagerTestCase.swift`.
final class ReplayRepaintTests: XCTestCase {

    /// After a replay (attach or resume), the server must ask the PTY's
    /// foreground app to repaint: replayed ring-buffer bytes reflect the grid
    /// they were emitted for, so without a SIGWINCH-driven redraw the client's
    /// screen can stay mis-wrapped (the bug users fixed manually by toggling
    /// the keyboard to force a size change). The repaint must fire only after
    /// the live output handler is wired — otherwise the redraw bytes go to the
    /// ring buffer alone and never reach this client.
    @MainActor
    func testAttachAndResumeForceRepaintAfterOutputIsWired() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegrationRepaint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, tokenInfo) = try await tokenStore.create(label: "repaint")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let sessionInfo = try await sessionManager.createSession(tokenId: tokenInfo.id, name: "repaint-test")
        let (_, pty) = try await sessionManager.attachSession(id: sessionInfo.id, tokenId: tokenInfo.id)
        let mockPTY = try XCTUnwrap(pty as? MockPTYSession)
        try await sessionManager.detachSession(id: sessionInfo.id)

        let server = WebSocketServer(
            group: group, config: config,
            sessionManager: sessionManager, tokenStore: tokenStore,
            pairingStore: PairingCodeStore()
        )
        try await server.start()
        defer { Task { try? await server.stop() } }
        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(name: "repaint", host: "127.0.0.1", port: config.wsPort)

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)

        try await controller.attachSession(id: sessionInfo.id)
        try? await Task.sleep(for: .milliseconds(200))

        let afterAttach = await mockPTY.forceRepaintCallCount
        XCTAssertEqual(afterAttach, 1, "attach must request exactly one repaint")
        let wiredAtRepaint = await mockPTY.forceRepaintSawOutputHandler
        XCTAssertTrue(wiredAtRepaint,
                      "repaint must fire after the output handler is wired, or the redraw never reaches the client")

        // Detach and resume — the resume replay path must repaint too.
        try await controller.detach()
        try await controller.resumeSession(id: sessionInfo.id)
        try? await Task.sleep(for: .milliseconds(200))

        let afterResume = await mockPTY.forceRepaintCallCount
        XCTAssertEqual(afterResume, 2, "resume must request a repaint as well")

        connection.disconnect()
    }
}
