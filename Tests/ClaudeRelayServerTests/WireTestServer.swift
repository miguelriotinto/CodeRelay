import Foundation
import NIOCore
import NIOPosix
import ClaudeRelayKit
@testable import ClaudeRelayServer

/// A real `WebSocketServer` on random high ports, with mock PTYs and a scratch
/// `TokenStore`, for the wire-level integration tests. One instance per test;
/// `stop()` tears everything down while the event loop is still live (NIO
/// warns if close work is scheduled after the group has shut down).
final class WireTestServer {
    let config: RelayConfig
    let tokenStore: TokenStore
    let sessionManager: SessionManager
    let server: WebSocketServer
    let group: MultiThreadedEventLoopGroup
    let rateLimiter: RateLimiter
    private let tempDir: URL

    init(rateLimiter: RateLimiter = RateLimiter(maxAttempts: 10, windowSeconds: 60)) throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WireIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        var config = RelayConfig.default
        // Random high ports to avoid collisions with a locally-running dev server.
        config.wsPort = UInt16.random(in: 25_000..<30_000)
        config.adminPort = UInt16.random(in: 30_000..<31_000)
        self.config = config

        tokenStore = TokenStore(directory: tempDir)
        sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )
        self.rateLimiter = rateLimiter
        server = WebSocketServer(
            group: group, config: config,
            sessionManager: sessionManager, tokenStore: tokenStore,
            rateLimiter: rateLimiter,
            pairingStore: PairingCodeStore()
        )
    }

    func start() async throws {
        try await server.start()
        // Small delay so the listening socket is ready to accept.
        try? await Task.sleep(for: .milliseconds(100))
    }

    func stop() async {
        try? await server.stop()
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func mintToken(label: String) async throws -> (plaintext: String, info: TokenInfo) {
        try await tokenStore.create(label: label)
    }

    func connect() async throws -> TestWebSocketClient {
        try await TestWebSocketClient.connect(port: config.wsPort, group: group)
    }

    /// A connected, authenticated client.
    func authenticatedClient(token: String) async throws -> TestWebSocketClient {
        let client = try await connect()
        try await client.authenticate(token: token)
        return client
    }
}
