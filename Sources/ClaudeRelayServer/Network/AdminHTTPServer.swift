import NIO
import NIOCore
import NIOPosix
import NIOHTTP1
import Foundation
import ClaudeRelayKit

public final class AdminHTTPServer {
    private let group: EventLoopGroup
    private let sessionManager: SessionManager
    private let tokenStore: TokenStore
    private let pairingStore: PairingCodeStore
    private let rateLimiter: RateLimiter
    private let config: RelayConfig
    private let port: UInt16
    private var channel: Channel?

    public init(group: EventLoopGroup, port: UInt16,
                sessionManager: SessionManager, tokenStore: TokenStore,
                pairingStore: PairingCodeStore,
                config: RelayConfig,
                rateLimiter: RateLimiter = RateLimiter(maxAttempts: 30, windowSeconds: 60)) {
        self.group = group
        self.port = port
        self.sessionManager = sessionManager
        self.tokenStore = tokenStore
        self.pairingStore = pairingStore
        self.config = config
        self.rateLimiter = rateLimiter
    }

    public func start() async throws {
        let sessionManager = self.sessionManager
        let tokenStore = self.tokenStore
        let pairingStore = self.pairingStore
        let config = self.config
        let rateLimiter = self.rateLimiter

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    let handler = AdminHTTPHandler(
                        sessionManager: sessionManager,
                        tokenStore: tokenStore,
                        pairingStore: pairingStore,
                        config: config,
                        rateLimiter: rateLimiter
                    )
                    return channel.pipeline.addHandler(handler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let ch = try await bootstrap.bind(host: "127.0.0.1", port: Int(port)).get()
        self.channel = ch
    }

    public func stop() async throws {
        try await channel?.close()
    }
}

// MARK: - AdminHTTPHandler

final class AdminHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private static let maxRequestBodyBytes: Int = 64 * 1024

    private let sessionManager: SessionManager
    private let tokenStore: TokenStore
    private let pairingStore: PairingCodeStore
    private let config: RelayConfig
    private let rateLimiter: RateLimiter

    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?
    private var requestBodyOverflow: Bool = false

    init(sessionManager: SessionManager, tokenStore: TokenStore,
         pairingStore: PairingCodeStore, config: RelayConfig, rateLimiter: RateLimiter) {
        self.sessionManager = sessionManager
        self.tokenStore = tokenStore
        self.pairingStore = pairingStore
        self.config = config
        self.rateLimiter = rateLimiter
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            self.requestHead = head
            self.requestBodyOverflow = false
            let contentLength = head.headers.first(name: "content-length").flatMap(Int.init) ?? 256
            if contentLength > Self.maxRequestBodyBytes {
                self.requestBodyOverflow = true
                self.requestBody = nil
            } else {
                self.requestBody = context.channel.allocator.buffer(
                    capacity: min(contentLength, Self.maxRequestBodyBytes))
            }
        case .body(var body):
            if requestBodyOverflow { return }
            let current = requestBody?.readableBytes ?? 0
            if current + body.readableBytes > Self.maxRequestBodyBytes {
                requestBodyOverflow = true
                requestBody = nil
                return
            }
            self.requestBody?.writeBuffer(&body)
        case .end:
            if requestBodyOverflow {
                if let head = requestHead {
                    RelayLogger.log(
                        .error,
                        category: "admin",
                        "\(head.method) \(head.uri) — rejected: request body > \(Self.maxRequestBodyBytes) bytes"
                    )
                }
                let response = AdminResponse.error("Request body too large", status: 413)
                writeResponse(response, context: context)
                self.requestHead = nil
                self.requestBody = nil
                self.requestBodyOverflow = false
                return
            }
            guard let head = requestHead else { return }
            let body = requestBody
            let sessionManager = self.sessionManager
            let tokenStore = self.tokenStore
            let pairingStore = self.pairingStore
            let config = self.config
            let rateLimiter = self.rateLimiter

            // Extract client IP for rate limiting.
            //
            // MUST be `ipAddress`, not `description`: the latter includes the
            // ephemeral source port, and `writeResponse` sets
            // `Connection: close`, so every admin request arrives on a fresh
            // connection with a fresh port. Keying on `description` therefore
            // minted a new bucket per request — `recordFailure` below wrote a
            // key that `isBlocked` above could never read again, so the limit
            // could not accumulate and never blocked anything. It also churned
            // the shared limiter's LRU with single-use keys, evicting the
            // WebSocket path's real entries.
            //
            // Matches the keying (and the reasoning) in
            // `RelayMessageHandler.handlerAdded`.
            let remoteIP = context.remoteAddress?.ipAddress
                ?? context.remoteAddress?.description
                ?? "unknown"
            let ctx = UnsafeTransfer(context)

            Task { [weak self] in
                // Check rate limit before processing
                if await rateLimiter.isBlocked(ip: remoteIP) {
                    let response = AdminResponse.error("Too many requests", status: 429)
                    ctx.value.eventLoop.execute {
                        self?.writeResponse(response, context: ctx.value)
                    }
                    return
                }

                RelayLogger.log(category: "admin", "\(head.method) \(head.uri)")
                let response = await AdminRoutes.handle(
                    method: head.method,
                    uri: head.uri,
                    body: body,
                    sessionManager: sessionManager,
                    tokenStore: tokenStore,
                    pairingStore: pairingStore,
                    config: config
                )

                // Track failures (4xx/5xx) for rate limiting
                if response.statusCode >= 400 {
                    await rateLimiter.recordFailure(ip: remoteIP)
                }

                ctx.value.eventLoop.execute {
                    self?.writeResponse(response, context: ctx.value)
                }
            }

            self.requestHead = nil
            self.requestBody = nil
            self.requestBodyOverflow = false
        }
    }

    private func writeResponse(_ response: AdminResponse, context: ChannelHandlerContext) {
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        let data = response.body
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }
}

// MARK: - AdminResponse

struct AdminResponse {
    let statusCode: Int
    let body: Data

    static func json(_ value: Any, status: Int = 200) -> AdminResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return AdminResponse(statusCode: status, body: data)
    }

    private static let sharedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static func encodable<T: Encodable>(_ value: T, status: Int = 200) -> AdminResponse {
        let data = (try? sharedEncoder.encode(value)) ?? Data()
        return AdminResponse(statusCode: status, body: data)
    }

    static func error(_ message: String, status: Int = 400) -> AdminResponse {
        return json(["error": message], status: status)
    }
}
