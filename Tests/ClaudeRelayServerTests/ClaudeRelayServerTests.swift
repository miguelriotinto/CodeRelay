import XCTest
import NIO
import NIOPosix
@testable import ClaudeRelayKit
@testable import ClaudeRelayServer

final class ClaudeRelayServerTests: XCTestCase {

    func testTLSConfiguration_WithValidCertAndKey() async throws {
        // Verify that WebSocketServer can be initialized with TLS config
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
        }

        let tokenStore = TokenStore(directory: RelayConfig.configDirectory)
        var config = RelayConfig.default

        // Set up paths to test certificates (generated in ~/.claude-relay/certs)
        let certPath = "\(NSHomeDirectory())/.claude-relay/certs/cert.pem"
        let keyPath = "\(NSHomeDirectory())/.claude-relay/certs/key.pem"

        // Only run test if cert files exist
        guard FileManager.default.fileExists(atPath: certPath),
              FileManager.default.fileExists(atPath: keyPath) else {
            throw XCTSkip(
                "Test certificates not found. Run: mkdir -p ~/.claude-relay/certs && "
                + "openssl req -x509 -newkey rsa:4096 "
                + "-keyout ~/.claude-relay/certs/key.pem "
                + "-out ~/.claude-relay/certs/cert.pem "
                + "-days 365 -nodes -subj '/CN=localhost'"
            )
        }

        config.tlsCert = certPath
        config.tlsKey = keyPath
        config.wsPort = 19200  // Use different port for testing

        let sessionManager = SessionManager(config: config, tokenStore: tokenStore)
        let wsServer = WebSocketServer(
            group: group,
            config: config,
            sessionManager: sessionManager,
            tokenStore: tokenStore,
            pairingStore: PairingCodeStore()
        )

        // Start server (this will fail if TLS config is invalid)
        try await wsServer.start()

        // Clean up
        try await wsServer.stop()
    }

    func testTLSConfiguration_WithoutCertAndKey() async throws {
        // Verify that WebSocketServer works without TLS (default config)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
        }

        let tokenStore = TokenStore(directory: RelayConfig.configDirectory)
        var config = RelayConfig.default
        config.wsPort = 19201  // Use different port for testing
        config.tlsCert = nil
        config.tlsKey = nil

        let sessionManager = SessionManager(config: config, tokenStore: tokenStore)
        let wsServer = WebSocketServer(
            group: group,
            config: config,
            sessionManager: sessionManager,
            tokenStore: tokenStore,
            pairingStore: PairingCodeStore()
        )

        // Start server without TLS
        try await wsServer.start()

        // Clean up
        try await wsServer.stop()
    }

    // MARK: - bindAll

    /// Default config (bindAll=true) must bind 0.0.0.0 — accept connections
    /// from any interface.
    func testBindDefaultsToAllInterfaces() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let tokenStore = TokenStore(directory: RelayConfig.configDirectory)
        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_300..<19_400)

        let sessionManager = SessionManager(config: config, tokenStore: tokenStore)
        let wsServer = WebSocketServer(
            group: group, config: config,
            sessionManager: sessionManager, tokenStore: tokenStore, pairingStore: PairingCodeStore()
        )
        try await wsServer.start()
        defer { Task { try? await wsServer.stop() } }

        XCTAssertEqual(wsServer._testOnly_boundAddress?.ipAddress, "0.0.0.0",
            "Default config must bind 0.0.0.0 (bindAll=true)")
    }

    /// With bindAll=false, the server binds 127.0.0.1 only.
    func testBindAllFalseBindsLoopback() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let tokenStore = TokenStore(directory: RelayConfig.configDirectory)
        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_400..<19_500)
        config.bindAll = false

        let sessionManager = SessionManager(config: config, tokenStore: tokenStore)
        let wsServer = WebSocketServer(
            group: group, config: config,
            sessionManager: sessionManager, tokenStore: tokenStore, pairingStore: PairingCodeStore()
        )
        try await wsServer.start()
        defer { Task { try? await wsServer.stop() } }

        XCTAssertEqual(wsServer._testOnly_boundAddress?.ipAddress, "127.0.0.1",
            "bindAll=false must bind 127.0.0.1 only")
    }
}
