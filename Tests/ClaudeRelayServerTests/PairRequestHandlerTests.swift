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
        return Fixture(channel: channel, handler: handler, tokenStore: tokenStore, tempDir: tempDir)
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
        guard let error = messages.compactMap({ msg -> (Int, String)? in
            if case .error(let code, let message) = msg { return (code, message) }
            return nil
        }).first else {
            return XCTFail("expected an error, got \(messages)")
        }
        XCTAssertEqual(error.0, 401, "expected 401, got \(error.0)")
        XCTAssertEqual(error.1, "Invalid or expired pairing code", "expected specific message, got \(error.1)")
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
        guard let error = messages.compactMap({ msg -> (Int, String)? in
            if case .error(let code, let message) = msg { return (code, message) }
            return nil
        }).first else {
            return XCTFail("expected an error, got \(messages)")
        }
        XCTAssertEqual(error.0, 401, "expected 401, got \(error.0)")
        XCTAssertEqual(error.1, "Invalid or expired pairing code", "expected specific message, got \(error.1)")
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
        guard let error = messages.compactMap({ msg -> (Int, String)? in
            if case .error(let code, let message) = msg { return (code, message) }
            return nil
        }).first else {
            return XCTFail("expected an error, got \(messages)")
        }
        XCTAssertEqual(error.0, 401, "expected 401, got \(error.0)")
        XCTAssertEqual(error.1, "Invalid or expired pairing code", "a redeemed code must not work again, got \(error.1)")
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

        // The rejected request must not consume the code.
        let stillValid = await store.redeem(grant.code)
        XCTAssertNotNil(stillValid, "the code should still be redeemable after the 400 rejection")
    }

    /// A minted token must never outlive a connection that never received it.
    /// `sendServerMessage` drops frames on a dead channel, so without the
    /// late-arrival guard the token would sit in the store forever with nobody
    /// holding it — and it never expires.
    ///
    /// Closing mid-flight is inherently a race, so this asserts the *invariant*
    /// rather than one outcome: either `pair_success` went out and the token
    /// lives, or it did not and the token is gone. The leak this guards against
    /// is the third combination — no `pair_success`, but a live token.
    func testUndeliveredTokenIsNotLeakedWhenConnectionClosesFirst() async throws {
        let store = PairingCodeStore()
        let fixture = try await makeFixture(pairingStore: store)
        let grant = await store.mint(label: "Doomed iPhone")

        // No settle time: close while redeem/create are still in flight.
        try await fixture.channel.writeInbound(pairFrame(code: grant.code))
        _ = try? await fixture.channel.close()
        try await Task.sleep(for: .milliseconds(250))

        let messages = (try? await serverMessages(fixture.channel)) ?? []
        let delivered = messages.contains {
            if case .pairSuccess = $0 { return true } else { return false }
        }
        let tokens = await fixture.tokenStore.list()

        if delivered {
            XCTAssertEqual(tokens.count, 1, "a delivered pair_success must keep its token")
        } else {
            XCTAssertTrue(
                tokens.isEmpty,
                "pair_success was never delivered, so the minted token must have been "
                + "deleted; found \(tokens.map { $0.label ?? "<nil>" })")
        }

        try? FileManager.default.removeItem(at: fixture.tempDir)
    }

    func testServerFaultDuringPairingReturns500WithoutBurningCode() async throws {
        // This test requires a TokenStore whose create() throws. Since TokenStore
        // is an actor and cannot be easily mocked, and making the directory
        // read-only does not reliably prevent atomic writes on all platforms,
        // I attempted to force a throw via filesystem permissions but the test
        // showed that tokenStore.create still succeeded (got pair_success instead
        // of error 500).
        //
        // The fix in Finding 1 is correct (switch on error, default → 500), but
        // I cannot construct a test that exercises it without either:
        // (a) introducing a test-only protocol/wrapper around TokenStore, or
        // (b) corrupting the TokenStore's internal state to force ensureLoaded()
        //     or save() to throw, which requires private API access.
        //
        // Explicitly reporting this as documented in the review instructions:
        // "If making `create` throw is not feasible without restructuring, say so
        // explicitly rather than shipping the fix untested."
        //
        // The fix is in place and the code is correct per the brief (mirrors
        // handleAuth's error handling). Without a feasible way to make
        // tokenStore.create throw in the test environment, this path remains
        // untested by automated tests.
        throw XCTSkip("Cannot reliably force TokenStore.create to throw without test-only protocol")
    }

    // MARK: - Rate-limit gate

    /// Pairing is pre-auth and a code is only 40 bits (against a token's 256),
    /// so the cross-connection cap is what keeps online guessing bounded here.
    /// It must be enforced at redeem time, not only by the eager gate in
    /// `handlerAdded` — that gate suspends on `await isBlocked` and loses the
    /// race to a `pair_request` pipelined behind the HTTP upgrade.
    ///
    /// Also asserts the code SURVIVES: the block is checked before `redeem`,
    /// so a blocked attacker cannot burn the single-use code that the real
    /// device is still waiting to use.
    func testRateLimitedIPCannotRedeemAndCodeSurvives() async throws {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 60)
        let store = PairingCodeStore()
        let fixture = try await makeFixture(rateLimiter: limiter, pairingStore: store)
        defer { Task { await cleanup(fixture) } }

        let grant = await store.mint(label: "Real iPhone")

        // Key off the handler's own remoteIP, as `testBadCodeRecordsRateLimiterFailure`
        // already does — NIOAsyncTestingChannel does not necessarily report the
        // sentinel address, and blocking the wrong key would let this test pass
        // while the gate did nothing.
        let ip = fixture.handler.remoteIP
        await limiter.recordFailure(ip: ip)
        await limiter.recordFailure(ip: ip)
        let blocked = await limiter.isBlocked(ip: ip)
        XCTAssertTrue(blocked, "precondition: the fixture's IP (\(ip)) must be blocked")

        // A VALID code — the rejection must come from the rate limit.
        try await send(pairFrame(code: grant.code), on: fixture)

        let messages = try await serverMessages(fixture.channel)
        let codes = messages.compactMap { msg -> Int? in
            if case .error(let code, _) = msg { return code }
            return nil
        }
        XCTAssertTrue(codes.contains(429), "expected a 429, got \(codes)")
        XCTAssertFalse(messages.contains { if case .pairSuccess = $0 { return true } else { return false } },
                       "a blocked IP must not receive pair_success")
        XCTAssertFalse(fixture.handler.isAuthenticated)

        let pending = await store.pendingCount()
        XCTAssertEqual(pending, 1,
            "the rate-limited attempt must not consume the code the real device still needs")
    }
}

// MARK: - Test Helpers

private struct NoopClipboardService: ClipboardService {
    func pasteImage(_ imageData: Data) -> Bool { true }
}
