import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOFoundationCompat
import ClaudeRelayKit

/// A minimal WebSocket client for driving a real `WebSocketServer` in tests
/// without `ClaudeRelayClient`, which is SwiftUI/UIKit-coupled and does not
/// build on Linux (`docs/linux-server-spec.md` AD-8).
///
/// It speaks exactly what the apps speak — `MessageEnvelope` JSON in text
/// frames, raw terminal bytes in binary frames — and nothing more: no
/// reconnect, no ping loop, no state. Every server frame becomes an `Event` in
/// arrival order, so a test can assert on the wire sequence itself
/// (`replay_complete` after the last binary chunk, silence after an unattached
/// `resize`) rather than on a client's interpretation of it.
///
/// Request/response is correlated the way `SessionController` does it: a
/// waiter accepts its expected type *or* `error`, because replies carry no ids.
final class TestWebSocketClient: @unchecked Sendable {

    enum Event: Sendable {
        case message(ServerMessage)
        case binary(Data)
        case closed
    }

    struct ReplyError: Error, CustomStringConvertible {
        let code: Int
        let message: String
        var description: String { "server error \(code): \(message)" }
    }

    struct Timeout: Error, CustomStringConvertible {
        let waitingFor: String
        var description: String { "timed out waiting for \(waitingFor)" }
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private let channel: Channel
    private let queue: EventQueue
    /// Events pulled while waiting for a specific type, kept so a later
    /// `next()` still sees them in order.
    private var lookahead: [Event] = []

    private init(channel: Channel, queue: EventQueue) {
        self.channel = channel
        self.queue = queue
    }

    // MARK: - Connection

    /// Opens a socket and completes the HTTP → WebSocket upgrade against
    /// `host:port`. Throws if the server refuses the upgrade or closes first.
    static func connect(
        host: String = "127.0.0.1",
        port: UInt16,
        group: EventLoopGroup
    ) async throws -> TestWebSocketClient {
        let queue = EventQueue()
        let upgraded = group.next().makePromise(of: Void.self)

        let upgrader = NIOWebSocketClientUpgrader(
            maxFrameSize: 1 << 24,
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(FrameHandler(queue: queue)).map {
                    upgraded.succeed(())
                }
            }
        )
        let requestSender = UpgradeRequestSender(host: host, port: port, upgraded: upgraded)

        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers(
                    withClientUpgrade: (
                        upgraders: [upgrader],
                        completionHandler: { context in
                            _ = context.pipeline.removeHandler(requestSender)
                        }
                    )
                ).flatMap {
                    channel.pipeline.addHandler(requestSender)
                }
            }
            .connect(host: host, port: Int(port))
            .get()

        channel.closeFuture.whenComplete { _ in
            upgraded.fail(ChannelError.ioOnClosedChannel)
            Task { await queue.push(.closed) }
        }

        try await upgraded.futureResult.get()
        return TestWebSocketClient(channel: channel, queue: queue)
    }

    func close() async {
        try? await channel.close().get()
    }

    // MARK: - Sending

    func send(_ message: ClientMessage) async throws {
        let data = try Self.encoder.encode(MessageEnvelope.client(message))
        let frame = WebSocketFrame(
            fin: true, opcode: .text, maskKey: .random(),
            data: channel.allocator.buffer(bytes: data))
        try await channel.writeAndFlush(frame).get()
    }

    func sendBinary(_ data: Data) async throws {
        let frame = WebSocketFrame(
            fin: true, opcode: .binary, maskKey: .random(),
            data: channel.allocator.buffer(bytes: data))
        try await channel.writeAndFlush(frame).get()
    }

    // MARK: - Receiving

    /// The next event in arrival order, or `nil` if none arrives within
    /// `timeout`. A closed socket is reported as `.closed`, once.
    func next(timeout: Duration = .seconds(5)) async -> Event? {
        if !lookahead.isEmpty { return lookahead.removeFirst() }
        return await queue.next(timeout: timeout)
    }

    /// Drains events until `idle` elapses without one — for asserting that
    /// nothing (more) arrives. Returns everything seen.
    func drain(idle: Duration = .milliseconds(300)) async -> [Event] {
        var seen: [Event] = []
        while let event = await next(timeout: idle) {
            seen.append(event)
            if case .closed = event { break }
        }
        return seen
    }

    /// Consumes events until a `ServerMessage` whose `typeString` is in
    /// `types` arrives, returning it. An `error` reply resolves the wait too, as
    /// a `ReplyError`, exactly as `SessionController.awaitResponse` treats it.
    /// Binary frames and other messages seen on the way are re-queued so the
    /// caller can still inspect them.
    @discardableResult
    func waitFor(_ types: Set<String>, timeout: Duration = .seconds(5)) async throws -> ServerMessage {
        var skipped: [Event] = []
        defer { lookahead = skipped + lookahead }
        while true {
            guard let event = await next(timeout: timeout) else {
                throw Timeout(waitingFor: types.sorted().joined(separator: "|"))
            }
            switch event {
            case .message(let message) where types.contains(message.typeString):
                return message
            case .message(.error(let code, let text)):
                throw ReplyError(code: code, message: text)
            case .closed:
                skipped.append(event)
                throw ReplyError(code: -1, message: "socket closed while waiting for \(types.sorted())")
            default:
                skipped.append(event)
            }
        }
    }

    // MARK: - Protocol flows

    /// `auth_request` → `auth_success`. Throws `ReplyError` on `auth_failure`
    /// (mapped to code 401) or on a 429 rate-limit error.
    func authenticate(token: String) async throws {
        try await send(.authRequest(token: token, protocolVersion: nil))
        let reply = try await waitFor(["auth_success", "auth_failure"])
        if case .authFailure(let reason) = reply {
            throw ReplyError(code: 401, message: reason)
        }
    }

    /// `session_create` → the new session id.
    func createSession(name: String) async throws -> UUID {
        try await send(.sessionCreate(name: name, cols: 80, rows: 24))
        guard case .sessionCreated(let id, _, _) = try await waitFor(["session_created"]) else {
            fatalError("waitFor returned a non-matching message")
        }
        return id
    }

    func attach(_ id: UUID) async throws {
        try await send(.sessionAttach(sessionId: id))
        try await waitFor(["session_attached"])
    }

    func resume(_ id: UUID) async throws {
        try await send(.sessionResume(sessionId: id, skipReplay: false))
        try await waitFor(["session_resumed"])
    }

    func detach() async throws {
        try await send(.sessionDetach)
        try await waitFor(["session_detached"])
    }

    // MARK: - Internals

    /// Arrival-ordered events with a timed `next()`. Deliberately not an
    /// `AsyncStream`: cancelling an `AsyncStream` iterator's `next()` — which
    /// is what a task-group timeout does — *finishes* the stream, so one
    /// timed-out wait would silently swallow every later frame.
    private actor EventQueue {
        private var buffered: [Event] = []
        private var waiter: (id: Int, continuation: CheckedContinuation<Event?, Never>)?
        private var nextWaiterId = 0

        func push(_ event: Event) {
            if let waiter {
                self.waiter = nil
                waiter.continuation.resume(returning: event)
            } else {
                buffered.append(event)
            }
        }

        func next(timeout: Duration) async -> Event? {
            if !buffered.isEmpty { return buffered.removeFirst() }
            let id = nextWaiterId
            nextWaiterId += 1
            return await withCheckedContinuation { continuation in
                waiter = (id, continuation)
                Task {
                    try? await Task.sleep(for: timeout)
                    self.expire(id)
                }
            }
        }

        private func expire(_ id: Int) {
            guard let waiter, waiter.id == id else { return }
            self.waiter = nil
            waiter.continuation.resume(returning: nil)
        }
    }

    /// Sends the upgrade request as soon as the socket is up; removed by the
    /// upgrade completion handler. If the server answers with a non-101
    /// response (a 429 close, say) the upgrade promise fails with it.
    private final class UpgradeRequestSender: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = HTTPClientResponsePart
        typealias OutboundOut = HTTPClientRequestPart

        private let host: String
        private let port: UInt16
        private let upgraded: EventLoopPromise<Void>

        init(host: String, port: UInt16, upgraded: EventLoopPromise<Void>) {
            self.host = host
            self.port = port
            self.upgraded = upgraded
        }

        func channelActive(context: ChannelHandlerContext) {
            var headers = HTTPHeaders()
            headers.add(name: "Host", value: "\(host):\(port)")
            headers.add(name: "Content-Length", value: "0")
            let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.write(wrapOutboundOut(.end(nil)), promise: nil)
            context.flush()
            context.fireChannelActive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            if case .head(let head) = unwrapInboundIn(data), head.status != .switchingProtocols {
                upgraded.fail(ReplyError(code: Int(head.status.code), message: "upgrade refused"))
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            upgraded.fail(error)
            context.close(promise: nil)
        }
    }

    private final class FrameHandler: ChannelInboundHandler {
        typealias InboundIn = WebSocketFrame
        typealias OutboundOut = WebSocketFrame

        private let queue: EventQueue

        init(queue: EventQueue) {
            self.queue = queue
        }

        private func deliver(_ event: Event) {
            let queue = self.queue
            Task { await queue.push(event) }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = unwrapInboundIn(data)
            switch frame.opcode {
            case .text:
                let payload = frame.unmaskedData
                let bytes = Data(buffer: payload)
                if let envelope = try? TestWebSocketClient.decoder.decode(MessageEnvelope.self, from: bytes),
                   case .server(let message) = envelope {
                    deliver(.message(message))
                }
            case .binary:
                deliver(.binary(Data(buffer: frame.unmaskedData)))
            case .ping:
                let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData)
                context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
            case .connectionClose:
                context.close(promise: nil)
            default:
                break
            }
        }
    }
}
