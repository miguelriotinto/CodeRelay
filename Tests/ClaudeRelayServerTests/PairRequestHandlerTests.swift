import XCTest
import Foundation
import NIO
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import ClaudeRelayKit
@testable import ClaudeRelayServer

/// Covers the pre-auth `pair_request` branch: a valid code mints a token, a
/// bad code is rate-limited, and pairing does not by itself authenticate.
final class PairRequestHandlerTests: XCTestCase {

    private struct Fixture {
        let channel: NIOAsyncTestingChannel
        let handler: RelayMessageHandler
        let tokenStore: TokenStore
        let pairingStore: PairingCodeStore
        let tempDir: URL
    }

    private func makeFixture(
        rateLimiter: RateLimiter? = nil,
        pairingStore: PairingCodeStore = PairingCodeStore()
    ) async throws -> Fixture {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairRequestTests-\(UUID().uuidString)")
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
        let handler = RelayMessageHandler(
            sessionManager: manager,
            tokenStore: tokenStore,
            rateLimiter: rateLimiter ?? RateLimiter(maxAttempts: 100, windowSeconds: 60),
            clipboardService: NoopClipboardService(),
            pushStore: PushRegistrationStore(directory: tempDir),
            pairingStore: pairingStore
        )
        let channel = await NIOAsyncTestingChannel(handler: handler)
        let sentinel = try SocketAddress(ipAddress: "127.0.0.1", port: 9999)
        try await channel.connect(to: sentinel).get()
        try await Task.sleep(for: .milliseconds(30))
        return Fixture(channel: channel, handler: handler, tokenStore: tokenStore,
                       pairingStore: pairingStore, tempDir: tempDir)
    }

    private func cleanup(_ fixture: Fixture) async {
        _ = try? await fixture.channel.finish()
        try? FileManager.default.removeItem(at: fixture.tempDir)
    }

    private func textFrame(_ json: String) -> WebSocketFrame {
        let utf8 = Array(json.utf8)
        var buf = ByteBufferAllocator().buffer(capacity: utf8.count)
        buf.writeBytes(utf8)
        return WebSocketFrame(fin: true, opcode: .text, data: buf)
    }

    private func send(_ frame: WebSocketFrame, on fixture: Fixture) async throws {
        try await fixture.channel.writeInbound(frame)
        try await Task.sleep(for: .milliseconds(40))
    }

    private func serverMessages(_ channel: NIOAsyncTestingChannel) async throws -> [ServerMessage] {
        var out: [ServerMessage] = []
        while let frame: WebSocketFrame = try await channel.readOutbound() {
            guard frame.opcode == .text else { continue }
            let buffer = frame.data
            let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
            let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: Data(bytes))
            if case .server(let msg) = envelope { out.append(msg) }
        }
        return out
    }

    private func pairFrame(code: String) -> WebSocketFrame {
        textFrame("""
        {"type":"pair_request","payload":{"code":"\(code)","deviceName":"Test iPhone","platform":"ios"}}
        """)
    }

    // MARK: - Happy path

    func testValidCodeMintsTokenAndReturnsPairSuccess() async throws {
        let store = PairingCodeStore()
        let fixture = try await makeFixture(pairingStore: store)
        defer { Task { await cleanup(fixture) } }

        let grant = await store.mint(label: "Test iPhone")
        try await send(pairFrame(code: grant.code), on: fixture)

        let messages = try await serverMessages(fixture.channel)
        guard let success = messages.compactMap({ msg -> (String, String, String)? in
            if case .pairSuccess(let token, let tokenId, let label) = msg { return (token, tokenId, label) }
            return nil
        }).first else {
            return XCTFail("expected pair_success, got \(messages)")
        }

        XCTAssertFalse(success.0.isEmpty, "token must be returned")
        XCTAssertFalse(success.1.isEmpty, "tokenId must be returned")
        XCTAssertTrue(success.2.contains("Test iPhone"), "label should name the device, got \(success.2)")

        // The returned token must actually validate.
        let info = await fixture.tokenStore.validate(token: success.0)
        XCTAssertNotNil(info, "minted token must be valid")
        XCTAssertEqual(info?.id, success.1)
    }

    func testPairingAloneDoesNotAuthenticate() async throws {
        let store = PairingCodeStore()
        let fixture = try await makeFixture(pairingStore: store)
        defer { Task { await cleanup(fixture) } }

        let grant = await store.mint(label: nil)
        try await send(pairFrame(code: grant.code), on: fixture)
        XCTAssertFalse(fixture.handler.isAuthenticated,
                       "pair_success must not authenticate; the client still sends auth_request")
    }

    func testPairThenAuthOnSameConnectionSucceeds() async throws {
        let store = PairingCodeStore()
        let fixture = try await makeFixture(pairingStore: store)
        defer { Task { await cleanup(fixture) } }

        let grant = await store.mint(label: "iPhone")
        try await send(pairFrame(code: grant.code), on: fixture)
        let paired = try await serverMessages(fixture.channel)
        guard case .pairSuccess(let token, _, _)? = paired.first(where: {
            if case .pairSuccess = $0 { return true } else { return false }
        }) else { return XCTFail("expected pair_success") }

        try await send(textFrame("""
        {"type":"auth_request","payload":{"token":"\(token)","protocolVersion":1}}
        """), on: fixture)

        XCTAssertTrue(fixture.handler.isAuthenticated, "the minted token must authenticate")
    }

    // MARK: - Failure paths

    func testUnknownCodeIsRejectedWith401() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }

        try await send(pairFrame(code: "00000000"), on: fixture)
        let messages = try await serverMessages(fixture.channel)
        let codes = messages.compactMap { msg -> Int? in
            if case .error(let code, _) = msg { return code }
            return nil
        }
        XCTAssertTrue(codes.contains(401), "expected a 401, got \(messages)")
        XCTAssertFalse(fixture.handler.isAuthenticated)
    }

    func testExpiredCodeIsRejected() async throws {
        // ttl 0 => expired the instant it is minted.
        let store = PairingCodeStore(ttl: 0)
        let fixture = try await makeFixture(pairingStore: store)
        defer { Task { await cleanup(fixture) } }

        let grant = await store.mint(label: nil)
        try await send(pairFrame(code: grant.code), on: fixture)
        let messages = try await serverMessages(fixture.channel)
        XCTAssertTrue(messages.contains { if case .error(401, _) = $0 { return true } else { return false } },
                      "expected 401 for an expired code, got \(messages)")
    }

    func testCodeCannotBeRedeemedTwiceAcrossConnections() async throws {
        let store = PairingCodeStore()
        let first = try await makeFixture(pairingStore: store)
        let grant = await store.mint(label: nil)
        try await send(pairFrame(code: grant.code), on: first)
        _ = try await serverMessages(first.channel)
        await cleanup(first)

        let second = try await makeFixture(pairingStore: store)
        defer { Task { await cleanup(second) } }
        try await send(pairFrame(code: grant.code), on: second)
        let messages = try await serverMessages(second.channel)
        XCTAssertTrue(messages.contains { if case .error(401, _) = $0 { return true } else { return false } },
                      "a redeemed code must not work again")
    }

    func testBadCodeRecordsRateLimiterFailure() async throws {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 60)
        let fixture = try await makeFixture(rateLimiter: limiter)
        defer { Task { await cleanup(fixture) } }

        try await send(pairFrame(code: "00000000"), on: fixture)
        try await send(pairFrame(code: "00000001"), on: fixture)
        try await Task.sleep(for: .milliseconds(50))

        // The handler's remoteIP is the sentinel address it connected to.
        let ip = fixture.handler.remoteIP
        let blocked = await limiter.isBlocked(ip: ip)
        XCTAssertTrue(blocked, "repeated bad codes must feed the shared rate limiter")
    }

    func testThreeBadCodesClosesTheConnection() async throws {
        let fixture = try await makeFixture()
        try await send(pairFrame(code: "00000000"), on: fixture)
        try await send(pairFrame(code: "00000001"), on: fixture)
        try await send(pairFrame(code: "00000002"), on: fixture)
        try await Task.sleep(for: .milliseconds(60))
        let active = fixture.channel.isActive
        try? FileManager.default.removeItem(at: fixture.tempDir)
        XCTAssertFalse(active, "the per-connection attempt cap should close the socket")
    }

    func testPairRequestAfterAuthIsRejected() async throws {
        let store = PairingCodeStore()
        let fixture = try await makeFixture(pairingStore: store)
        defer { Task { await cleanup(fixture) } }

        let (token, _) = try await fixture.tokenStore.create(label: "existing")
        try await send(textFrame("""
        {"type":"auth_request","payload":{"token":"\(token)","protocolVersion":1}}
        """), on: fixture)
        XCTAssertTrue(fixture.handler.isAuthenticated)
        _ = try await serverMessages(fixture.channel)

        let grant = await store.mint(label: nil)
        try await send(pairFrame(code: grant.code), on: fixture)
        let messages = try await serverMessages(fixture.channel)
        XCTAssertTrue(messages.contains { if case .error(400, _) = $0 { return true } else { return false } },
                      "pairing on an already-authenticated connection is a 400, got \(messages)")
    }
}

// MARK: - Test Helpers

private struct NoopClipboardService: ClipboardService {
    func pasteImage(_ imageData: Data) -> Bool { true }
}
