import XCTest
import Foundation
import NIO
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import ClaudeRelayKit
@testable import ClaudeRelayServer

/// Direct unit tests for `RelayMessageHandler`. Uses NIO's
/// `NIOAsyncTestingChannel` so each test installs the handler in a real
/// (but in-memory) pipeline, pumps WebSocket frames through, and reads
/// the responses back. Async-aware unlike `EmbeddedChannel` — necessary
/// because the handler bridges Swift Concurrency (Tasks awaiting on
/// actors) into NIO's event loop.
///
/// `WebSocketIntegrationTests` covers the happy paths against a real
/// `WebSocketServer`; this file targets the per-branch error responses
/// (413/401/400) and the cleanup invariants which are reachable from a
/// single client and don't need a full server boot to exercise.
final class RelayMessageHandlerTests: XCTestCase {

    // MARK: - Fixtures

    private struct Fixture {
        let channel: NIOAsyncTestingChannel
        let handler: RelayMessageHandler
        let tokenStore: TokenStore
        let pushStore: PushRegistrationStore
        let tempDir: URL
    }

    private func makeFixture(
        rateLimiter: RateLimiter? = nil
    ) async throws -> Fixture {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayHandlerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let tokenStore = TokenStore(directory: tempDir)
        let config = RelayConfig(detachTimeout: 5, scrollbackSize: 4096)
        let manager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let pushStore = PushRegistrationStore(directory: tempDir)
        let handler = RelayMessageHandler(
            sessionManager: manager,
            tokenStore: tokenStore,
            rateLimiter: rateLimiter ?? RateLimiter(maxAttempts: 100, windowSeconds: 60),
            clipboardService: NoopClipboardService(),
            pushStore: pushStore
        )

        let channel = await NIOAsyncTestingChannel(handler: handler)
        // `register()` (called by the convenience init) only fires
        // channelRegistered. We need to fire channelActive too so the
        // handler's `sendServerMessage` doesn't drop frames against an
        // inactive channel. The simplest way: `connect` to a sentinel
        // address — sets `isActive = true` and fires the event.
        let sentinel = try SocketAddress(ipAddress: "127.0.0.1", port: 9999)
        try await channel.connect(to: sentinel).get()
        // The handler's `handlerAdded` spawns a Task that hops to the actor
        // (rate-limit check) then back to the event loop (timer arm). Yield
        // so that work settles before tests start sending frames.
        try await Task.sleep(for: .milliseconds(30))
        return Fixture(channel: channel, handler: handler, tokenStore: tokenStore,
                       pushStore: pushStore, tempDir: tempDir)
    }

    private func cleanup(_ fixture: Fixture) async {
        _ = try? await fixture.channel.finish()
        try? FileManager.default.removeItem(at: fixture.tempDir)
    }

    /// Build a text WebSocket frame from a JSON string.
    private func textFrame(_ json: String) -> WebSocketFrame {
        let utf8 = Array(json.utf8)
        var buf = ByteBufferAllocator().buffer(capacity: utf8.count)
        buf.writeBytes(utf8)
        return WebSocketFrame(fin: true, opcode: .text, data: buf)
    }

    /// Build a binary WebSocket frame from raw bytes.
    private func binaryFrame(_ bytes: [UInt8]) -> WebSocketFrame {
        var buf = ByteBufferAllocator().buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        return WebSocketFrame(fin: true, opcode: .binary, data: buf)
    }

    /// Read every outbound WebSocket frame currently pending on the channel.
    private func drainOutboundFrames(_ channel: NIOAsyncTestingChannel) async throws -> [WebSocketFrame] {
        var frames: [WebSocketFrame] = []
        while let frame: WebSocketFrame = try await channel.readOutbound() {
            frames.append(frame)
        }
        return frames
    }

    /// Decode a text frame's payload as a server-direction `MessageEnvelope`.
    /// XCTFails if the frame isn't a server message.
    private func decodeServer(_ frame: WebSocketFrame) throws -> ServerMessage {
        XCTAssertEqual(frame.opcode, .text, "Expected a text frame, got \(frame.opcode)")
        let buffer = frame.data
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        let data = Data(bytes)
        let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: data)
        guard case .server(let msg) = envelope else {
            XCTFail("Expected server-direction envelope, got \(envelope)")
            throw DecodeError.notServer
        }
        return msg
    }

    private enum DecodeError: Error { case notServer }

    /// Pull the first server message out of the pending outbound frames.
    /// Returns nil if there's no text frame yet.
    private func firstServerMessage(_ channel: NIOAsyncTestingChannel) async throws -> ServerMessage? {
        let frames = try await drainOutboundFrames(channel)
        guard let textFrame = frames.first(where: { $0.opcode == .text }) else { return nil }
        return try decodeServer(textFrame)
    }

    /// Drives one inbound frame and yields long enough for the handler's
    /// concurrency hops (Task → actor → eventLoop.execute) to land before
    /// the next test step inspects outbound or handler state.
    private func send(_ frame: WebSocketFrame, on fixture: Fixture) async throws {
        try await fixture.channel.writeInbound(frame)
        try await Task.sleep(for: .milliseconds(20))
    }

    // MARK: - Unauthenticated message handling

    /// Any non-auth, non-ping client message must be rejected with 401 when
    /// the connection has not yet authenticated. Regression for the auth gate
    /// in `handleUnauthenticatedMessage`.
    func testUnauthenticatedClientMessageReceives401() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }

        // session_create requires auth.
        try await send(textFrame(#"{"type":"session_create","payload":{}}"#), on: fixture)
        let response = try await firstServerMessage(fixture.channel)
        let unwrapped = try XCTUnwrap(response, "Expected an error response on the wire")

        guard case .error(let code, let message) = unwrapped else {
            XCTFail("Expected .error, got \(unwrapped)"); return
        }
        XCTAssertEqual(code, 401)
        XCTAssertTrue(message.lowercased().contains("not authenticated"))
        XCTAssertFalse(fixture.handler.isAuthenticated)
    }

    /// Ping is allowed pre-auth and receives pong — used by clients that
    /// want to RTT-probe before sending credentials.
    func testUnauthenticatedPingReceivesPong() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }

        try await send(textFrame(#"{"type":"ping","payload":{}}"#), on: fixture)
        let response = try await firstServerMessage(fixture.channel)
        XCTAssertEqual(response, .pong)
    }

    // MARK: - Push token registration

    func testRegisterPushTokenWhenAuthedAcksAndStores() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }
        fixture.handler.authenticatedTokenId = "R"
        fixture.handler.isAuthenticated = true

        let json = #"{"type":"register_push_token","payload":{"platform":"apns","token":"tok-abc","deviceId":"dev-1","enabled":true,"notifyOnFinished":false}}"#
        try await send(textFrame(json), on: fixture)
        let response = try await firstServerMessage(fixture.channel)
        XCTAssertEqual(response, .pushTokenAck(accepted: true))

        let stored = await fixture.pushStore.registrations(forTokenId: "R")
        XCTAssertEqual(stored.map(\.token), ["tok-abc"])
    }

    func testRegisterPushTokenWhenUnauthedIsRejected() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }
        // No authenticatedTokenId set — the pre-auth gate rejects with 401
        // before the push arm runs, and nothing is stored.
        let json = #"{"type":"register_push_token","payload":{"platform":"apns","token":"t","deviceId":"d","enabled":true,"notifyOnFinished":false}}"#
        try await send(textFrame(json), on: fixture)
        let response = try await firstServerMessage(fixture.channel)
        guard case .error(let code, _) = try XCTUnwrap(response) else {
            XCTFail("Expected .error, got \(String(describing: response))"); return
        }
        XCTAssertEqual(code, 401)
        let stored = await fixture.pushStore.registrations(forTokenId: "R")
        XCTAssertTrue(stored.isEmpty)
    }

    func testRegisterPushTokenRejectsOversizeToken() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }
        fixture.handler.authenticatedTokenId = "R"
        fixture.handler.isAuthenticated = true
        let big = String(repeating: "x", count: 513)
        let json = #"{"type":"register_push_token","payload":{"platform":"apns","token":"\#(big)","deviceId":"d","enabled":true,"notifyOnFinished":false}}"#
        try await send(textFrame(json), on: fixture)
        let response = try await firstServerMessage(fixture.channel)
        XCTAssertEqual(response, .pushTokenAck(accepted: false))
        let stored = await fixture.pushStore.registrations(forTokenId: "R")
        XCTAssertTrue(stored.isEmpty)
    }

    // MARK: - Frame size limits (413)

    /// Text frames over `maxTextFrameSize` (10 MB) must be rejected with 413
    /// and close the channel. The cap exists because images travel as base64
    /// inside JSON, so a >10 MB payload is almost certainly malformed.
    func testOversizedTextFrameRejectedWith413() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }

        // Build a payload just over the 10 MB threshold. The size check runs
        // before decode so the JSON doesn't have to be valid.
        let bigPayload = String(repeating: "a", count: 10_000_001)
        let json = #"{"type":"ping","payload":{"x":"\#(bigPayload)"}}"#
        try await send(textFrame(json), on: fixture)

        let response = try await firstServerMessage(fixture.channel)
        let unwrapped = try XCTUnwrap(response)
        guard case .error(let code, _) = unwrapped else {
            XCTFail("Expected .error for oversized frame, got \(unwrapped)"); return
        }
        XCTAssertEqual(code, 413)
        // Channel must be closing — `context.close` was called.
        XCTAssertFalse(fixture.channel.isActive, "Oversized frame should close the channel")
    }

    // MARK: - Malformed JSON (400)

    /// Bytes that aren't valid JSON should produce a 400 "Invalid message
    /// format" but must NOT close the channel — the client may recover.
    func testMalformedJSONReceives400() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }

        try await send(textFrame(#"{this is not json"#), on: fixture)
        let response = try await firstServerMessage(fixture.channel)
        let unwrapped = try XCTUnwrap(response)

        guard case .error(let code, let message) = unwrapped else {
            XCTFail("Expected .error, got \(unwrapped)"); return
        }
        XCTAssertEqual(code, 400)
        XCTAssertTrue(message.lowercased().contains("invalid"))
        XCTAssertTrue(fixture.channel.isActive,
            "Malformed JSON must not close the channel — the client may retry")
    }

    /// A correctly-framed envelope but with a server-direction type string
    /// (i.e., the client tried to send what only the server is allowed to
    /// send) must be rejected with 400. Defensive against a misbehaving client.
    func testServerDirectionEnvelopeReceives400() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }

        // `pong` is a server→client message; the envelope decoder will
        // succeed with `.server(.pong)` and the handler must reject it.
        try await send(textFrame(#"{"type":"pong","payload":{}}"#), on: fixture)
        let response = try await firstServerMessage(fixture.channel)
        let unwrapped = try XCTUnwrap(response)
        guard case .error(let code, _) = unwrapped else {
            XCTFail("Expected .error, got \(unwrapped)"); return
        }
        XCTAssertEqual(code, 400)
    }

    /// Empty text frame (zero readable bytes) is silently dropped — no
    /// response, no close. Otherwise idle keepalive empty frames would be
    /// noisy.
    func testEmptyTextFrameSilentlyDropped() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }

        try await send(textFrame(""), on: fixture)
        let frames = try await drainOutboundFrames(fixture.channel)
        XCTAssertTrue(frames.isEmpty, "Empty text frame must produce no outbound traffic")
        XCTAssertTrue(fixture.channel.isActive)
    }

    // MARK: - Binary frames pre-auth

    /// Binary frames are PTY input. They must be silently dropped when the
    /// connection isn't authenticated — no error response (no leak about
    /// session state), no PTY write.
    func testBinaryFramePreAuthIsSilentlyDropped() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }

        try await send(binaryFrame([0x41, 0x42, 0x43]), on: fixture)
        let frames = try await drainOutboundFrames(fixture.channel)
        XCTAssertTrue(frames.isEmpty,
            "Pre-auth binary frame must not produce a response")
    }

    /// Oversized binary frames (>10 MB): the current handler guards on
    /// `isAuthenticated && attachedPTY` *before* the size check, so a
    /// pre-auth 10 MB binary frame is silently dropped. Pin that contract
    /// so changes that re-order the checks have to make a deliberate
    /// decision.
    func testOversizedBinaryFramePreAuthIsSilentlyDropped() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }

        let bigBinary = [UInt8](repeating: 0xFF, count: 10_000_001)
        try await send(binaryFrame(bigBinary), on: fixture)
        let frames = try await drainOutboundFrames(fixture.channel)
        XCTAssertTrue(frames.isEmpty,
            "Pre-auth oversized binary frame must not produce a response (silent drop)")
    }

    // MARK: - Auth attempts cap

    /// Three consecutive bad-token authRequests on the same connection must
    /// close the channel with 401 — `maxAuthAttempts` cap. Belt-and-braces
    /// alongside the cross-connection RateLimiter (which is exercised by
    /// `testBruteForceAuthIsRateLimited` in the integration suite).
    func testThreeBadTokensOnSameConnectionClosesChannel() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }

        let bad = #"{"type":"auth_request","payload":{"token":"wrong"}}"#

        for _ in 0..<3 {
            try await send(textFrame(bad), on: fixture)
            // Give the auth bridge extra time — token validate hits the
            // TokenStore actor and the failure path posts back to the
            // event loop.
            try await Task.sleep(for: .milliseconds(40))
        }

        // Drain the responses — should be three authFailure frames followed
        // by a channel close.
        let frames = try await drainOutboundFrames(fixture.channel)
        let authFailures = frames.compactMap { try? decodeServer($0) }.filter {
            if case .authFailure = $0 { return true } else { return false }
        }
        XCTAssertGreaterThanOrEqual(authFailures.count, 1,
            "Expected at least one authFailure response")
        XCTAssertFalse(fixture.handler.isAuthenticated)
        XCTAssertFalse(fixture.channel.isActive,
            "After max bad-auth attempts the channel must be closed")
    }

    // MARK: - Cleanup idempotency

    /// `channelInactive` triggers `cleanupSession()`. Calling it more than
    /// once must not crash — the channel close flow can fire from multiple
    /// paths (errorCaught + connectionClose + remote-side close) and the
    /// handler must stay correct under repeat fire.
    func testChannelInactiveIsIdempotent() async throws {
        let fixture = try await makeFixture()

        // Closing the channel triggers `channelInactive` once.
        try await fixture.channel.close().get()

        // Now finish — which would internally re-close. The flag should stay
        // set, no crash, no hang.
        _ = try? await fixture.channel.finish()
        XCTAssertFalse(fixture.handler.isAuthenticated,
            "Handler must remain unauthenticated after cleanup")

        try? FileManager.default.removeItem(at: fixture.tempDir)
    }
}

// MARK: - Test doubles

/// Clipboard implementation that does nothing — pasteImage isn't on the
/// path being tested here. Production uses `MacClipboardService`.
private struct NoopClipboardService: ClipboardService {
    func pasteImage(_ imageData: Data) -> Bool { true }
}
