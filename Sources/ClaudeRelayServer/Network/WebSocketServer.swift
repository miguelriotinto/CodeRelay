import NIO
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import ClaudeRelayKit
import Foundation

public final class WebSocketServer {
    /// Read-idle window after which a silent connection is closed. Healthy
    /// clients ping every 10 s (`RelayConnection.pingInterval`), so 60 s is
    /// 6 missed pings — well above jitter, and it reaps half-open sockets
    /// from clients that vanished without a TCP FIN (mobile app-kill,
    /// NAT/CGNAT eviction) before they leak fds to `EMFILE`. See
    /// `IdleConnectionReaper`.
    static let readIdleTimeout: TimeAmount = .seconds(60)

    private let group: EventLoopGroup
    private let sessionManager: SessionManager
    private let tokenStore: TokenStore
    private let rateLimiter: RateLimiter
    private let clipboardService: ClipboardService
    private let config: RelayConfig
    private let pushStore: PushRegistrationStore
    private let pairingStore: PairingCodeStore
    private var channel: Channel?

    public init(group: EventLoopGroup, config: RelayConfig,
                sessionManager: SessionManager, tokenStore: TokenStore,
                rateLimiter: RateLimiter = RateLimiter(maxAttempts: 10, windowSeconds: 60),
                clipboardService: ClipboardService = MacClipboardService(),
                pushStore: PushRegistrationStore = PushRegistrationStore(directory: RelayConfig.configDirectory),
                pairingStore: PairingCodeStore) {
        self.group = group
        self.config = config
        self.sessionManager = sessionManager
        self.tokenStore = tokenStore
        self.rateLimiter = rateLimiter
        self.clipboardService = clipboardService
        self.pushStore = pushStore
        self.pairingStore = pairingStore
    }

    /// Create SSL context from configured cert and key files.
    private func createSSLContext() throws -> NIOSSLContext {
        guard let certPath = config.tlsCert, let keyPath = config.tlsKey else {
            throw WebSocketServerError.tlsConfigMissing
        }

        let certURL = URL(fileURLWithPath: NSString(string: certPath).expandingTildeInPath)
        let keyURL = URL(fileURLWithPath: NSString(string: keyPath).expandingTildeInPath)

        guard FileManager.default.fileExists(atPath: certURL.path) else {
            throw WebSocketServerError.tlsCertNotFound(certURL.path)
        }
        guard FileManager.default.fileExists(atPath: keyURL.path) else {
            throw WebSocketServerError.tlsKeyNotFound(keyURL.path)
        }

        let certificates = try NIOSSLCertificate.fromPEMFile(certURL.path)
        let privateKey = try NIOSSLPrivateKey(file: keyURL.path, format: .pem)

        let certificateChain = certificates.map { NIOSSLCertificateSource.certificate($0) }

        var tlsConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificateChain,
            privateKey: .privateKey(privateKey)
        )
        tlsConfig.minimumTLSVersion = .tlsv12

        return try NIOSSLContext(configuration: tlsConfig)
    }

    public func start() async throws {
        let sessionManager = self.sessionManager
        let tokenStore = self.tokenStore
        let pushStore = self.pushStore
        let pairingStore = self.pairingStore
        let rateLimiter = self.rateLimiter
        let clipboardService = self.clipboardService
        let sslContext: NIOSSLContext? = try createSSLContextIfConfigured()

        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 10 * 1024 * 1024,
            shouldUpgrade: { channel, _ in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                let handler = RelayMessageHandler(
                    sessionManager: sessionManager,
                    tokenStore: tokenStore,
                    rateLimiter: rateLimiter,
                    clipboardService: clipboardService,
                    pushStore: pushStore,
                    pairingStore: pairingStore
                )
                return channel.pipeline.addHandler(handler)
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Add TLS handler if configured
                let sslFuture: EventLoopFuture<Void>
                if let sslContext = sslContext {
                    let sslHandler = NIOSSLServerHandler(context: sslContext)
                    sslFuture = channel.pipeline.addHandler(sslHandler)
                } else {
                    sslFuture = channel.eventLoop.makeSucceededVoidFuture()
                }

                return sslFuture.flatMap {
                    // Reap connections that go silent. Installed before the
                    // HTTP/WebSocket handlers so it observes raw inbound
                    // activity across the whole connection lifetime (HTTP
                    // handshake + upgraded WebSocket). Without this, clients
                    // that vanish without a FIN leak fds until EMFILE.
                    channel.pipeline.addHandlers([
                        IdleStateHandler(readTimeout: Self.readIdleTimeout),
                        IdleConnectionReaper()
                    ])
                }.flatMap {
                    let config: NIOHTTPServerUpgradeConfiguration = (
                        upgraders: [upgrader],
                        completionHandler: { _ in
                            // Remove HTTP handlers after upgrade
                        }
                    )
                    return channel.pipeline.configureHTTPServerPipeline(
                        withServerUpgrade: config
                    ).flatMap {
                        // No additional handler needed; upgrade handler installs RelayMessageHandler
                        channel.eventLoop.makeSucceededVoidFuture()
                    }
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        // Default: bind 0.0.0.0 so the server accepts connections from any
        // network interface. Set `bindAll=false` to restrict to loopback.
        // Without TLS, tokens travel in plaintext on whatever network we
        // bind — log an explicit warning in the default-but-untls case so
        // operators can decide whether to configure TLS or tighten bindAll.
        let host = config.bindAll ? "0.0.0.0" : "127.0.0.1"
        let ch = try await bootstrap.bind(host: host, port: Int(config.wsPort)).get()
        self.channel = ch

        if sslContext != nil {
            RelayLogger.log(category: "websocket",
                "TLS enabled on \(host):\(config.wsPort)")
        } else if config.bindAll {
            RelayLogger.log(.error, category: "websocket",
                "Server is listening on 0.0.0.0:\(config.wsPort) without TLS. "
                + "Tokens will be transmitted in plaintext on this network. "
                + "Set bindAll=false to restrict to localhost, or configure tlsCert/tlsKey.")
        } else {
            RelayLogger.log(category: "websocket",
                "Server listening on 127.0.0.1:\(config.wsPort) (localhost only, bindAll=false).")
        }
    }

    /// Create SSL context if TLS is configured (both cert and key present).
    private func createSSLContextIfConfigured() throws -> NIOSSLContext? {
        guard config.tlsEnabled else { return nil }
        return try createSSLContext()
    }

    public func stop() async throws {
        try await channel?.close()
    }

    // MARK: - Test Hooks

    /// Exposed only for tests. The local SocketAddress the WebSocket server is
    /// bound to. Do not call from production code.
    public var _testOnly_boundAddress: SocketAddress? {
        channel?.localAddress
    }
}

// MARK: - Errors

enum WebSocketServerError: Error, CustomStringConvertible {
    case tlsConfigMissing
    case tlsCertNotFound(String)
    case tlsKeyNotFound(String)

    var description: String {
        switch self {
        case .tlsConfigMissing:
            return "TLS configuration incomplete: both tlsCert and tlsKey are required"
        case .tlsCertNotFound(let path):
            return "TLS certificate not found at path: \(path)"
        case .tlsKeyNotFound(let path):
            return "TLS private key not found at path: \(path)"
        }
    }
}
