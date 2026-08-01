import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

@MainActor
final class PairingControllerTests: XCTestCase {

    /// Minimal stand-in for the pieces of RelayConnection the controller uses.
    final class MockConnection: PairingConnection {
        var connected: (config: ConnectionConfig, token: String)?
        var sent: [ClientMessage] = []
        var subscriber: ((ServerMessage) -> Void)?
        var disconnected = false
        /// The reply to deliver on the next send, or nil to stay silent (timeout).
        var scriptedReply: ServerMessage?

        func connect(config: ConnectionConfig, token: String) async throws {
            connected = (config, token)
        }
        func addServerMessageSubscriber(_ handler: @escaping (ServerMessage) -> Void) -> UUID {
            subscriber = handler
            return UUID()
        }
        func removeSubscriber(_ id: UUID) { subscriber = nil }
        func send(_ message: ClientMessage) async throws {
            sent.append(message)
            if let reply = scriptedReply { subscriber?(reply) }
        }
        func disconnect() { disconnected = true }
    }

    private func makeStore() -> SavedConnectionStore {
        SavedConnectionStore(key: "test.pairing.\(UUID().uuidString)")
    }

    func testPairMintsTokenPersistsConfigAndToken() async throws {
        let conn = MockConnection()
        conn.scriptedReply = .pairSuccess(token: "tok-abc", tokenId: "id-1", label: "Miguel's iPhone (paired)")
        let store = makeStore()
        let controller = PairingController(
            store: store,
            deviceName: "Miguel's iPhone",
            platform: "ios",
            connectionFactory: { conn })

        let url = PairingURL(host: "silverwing.local", port: 9200, useTLS: false, code: "K7QP2M4X")
        let config = try await controller.pair(url)

        // Sent exactly one pair_request with the right fields.
        XCTAssertEqual(conn.sent.count, 1)
        guard case .pairRequest(let code, let device, let platform) = conn.sent[0] else {
            return XCTFail("expected pair_request, got \(conn.sent)")
        }
        XCTAssertEqual(code, "K7QP2M4X")
        XCTAssertEqual(device, "Miguel's iPhone")
        XCTAssertEqual(platform, "ios")

        // Persisted a config from the URL, named from the label.
        XCTAssertEqual(config.host, "silverwing.local")
        XCTAssertEqual(config.port, 9200)
        XCTAssertFalse(config.useTLS)
        XCTAssertEqual(config.name, "Miguel's iPhone (paired)")
        XCTAssertTrue(store.loadAll().contains { $0.id == config.id })

        // Persisted the token under the config id.
        XCTAssertEqual(try AuthManager.shared.loadToken(for: config.id), "tok-abc")
        try? AuthManager.shared.deleteToken(for: config.id)
    }

    func testInvalidCodeMapsToInvalidCodeError() async throws {
        let conn = MockConnection()
        conn.scriptedReply = .error(code: 401, message: "Invalid or expired pairing code")
        let controller = PairingController(
            store: makeStore(), deviceName: "d", platform: "ios",
            connectionFactory: { conn })
        let url = PairingURL(host: "h.local", port: 9200, useTLS: false, code: "K7QP2M4X")
        do {
            _ = try await controller.pair(url)
            XCTFail("expected throw")
        } catch let e as PairingError {
            XCTAssertEqual(e, .invalidCode)
        }
        XCTAssertTrue(conn.disconnected, "socket must be torn down on failure")
    }

    func testRateLimitedMapsTo429Error() async throws {
        let conn = MockConnection()
        conn.scriptedReply = .error(code: 429, message: "Too many attempts")
        let controller = PairingController(
            store: makeStore(), deviceName: "d", platform: "ios",
            connectionFactory: { conn })
        let url = PairingURL(host: "h.local", port: 9200, useTLS: false, code: "K7QP2M4X")
        do { _ = try await controller.pair(url); XCTFail("expected throw") }
        catch let e as PairingError { XCTAssertEqual(e, .rateLimited) }
    }

    func testNoReplyTimesOut() async throws {
        let conn = MockConnection()          // scriptedReply nil → server stays silent
        let controller = PairingController(
            store: makeStore(), deviceName: "d", platform: "ios",
            connectionFactory: { conn }, timeout: .milliseconds(100))
        let url = PairingURL(host: "h.local", port: 9200, useTLS: false, code: "K7QP2M4X")
        do { _ = try await controller.pair(url); XCTFail("expected throw") }
        catch let e as PairingError { XCTAssertEqual(e, .timedOut) }
        XCTAssertTrue(conn.disconnected)
    }
}
