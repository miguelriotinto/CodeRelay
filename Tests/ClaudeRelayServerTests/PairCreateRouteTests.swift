import XCTest
import NIOCore
import NIOHTTP1
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class PairCreateRouteTests: SessionManagerTestCase {

    private func route(
        _ method: HTTPMethod,
        _ uri: String,
        body: [String: Any]? = nil,
        pairingStore: PairingCodeStore
    ) async -> (status: Int, json: [String: Any]?) {
        var buf: ByteBuffer?
        if let body, let data = try? JSONSerialization.data(withJSONObject: body) {
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            buf = buffer
        }
        let response = await AdminRoutes.handle(
            method: method, uri: uri, body: buf,
            sessionManager: makeManager(), tokenStore: tokenStore,
            pairingStore: pairingStore
        )
        let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        return (response.statusCode, json)
    }

    func testPairCreateReturnsRedeemableCode() async throws {
        let store = PairingCodeStore()
        let (status, json) = await route(.POST, "/pair/create", body: ["label": "iPhone"], pairingStore: store)
        XCTAssertEqual(status, 200)
        let code = try XCTUnwrap(json?["code"] as? String)
        XCTAssertEqual(code.count, PairingCode.length)
        XCTAssertEqual(json?["formattedCode"] as? String, PairingCode.formatted(code))
        // The minted code must be redeemable from the SAME store instance.
        let grant = await store.redeem(code)
        XCTAssertEqual(grant?.label, "iPhone")
    }

    func testPairCreateWorksWithoutLabel() async throws {
        let store = PairingCodeStore()
        let (status, json) = await route(.POST, "/pair/create", pairingStore: store)
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(json?["code"] as? String)
    }

    func testPairCreateEmitsISO8601Expiry() async throws {
        let store = PairingCodeStore(ttl: 300)
        let (_, json) = await route(.POST, "/pair/create", pairingStore: store)
        let raw = try XCTUnwrap(json?["expiresAt"] as? String)
        let formatter = ISO8601DateFormatter()
        XCTAssertNotNil(formatter.date(from: raw), "admin API must emit ISO8601, not a Double")
    }

    func testPairCreateReportsWSPortAndTLS() async throws {
        let store = PairingCodeStore()
        let (_, json) = await route(.POST, "/pair/create", pairingStore: store)
        XCTAssertNotNil(json?["wsPort"] as? Int)
        XCTAssertNotNil(json?["tls"] as? Bool)
    }

    func testUnknownPairSubpathIs404() async {
        let store = PairingCodeStore()
        let (status, _) = await route(.POST, "/pair/nope", pairingStore: store)
        XCTAssertEqual(status, 404)
    }

    func testGetPairCreateIsNotAllowed() async {
        let store = PairingCodeStore()
        let (status, _) = await route(.GET, "/pair/create", pairingStore: store)
        XCTAssertEqual(status, 404)
    }
}
