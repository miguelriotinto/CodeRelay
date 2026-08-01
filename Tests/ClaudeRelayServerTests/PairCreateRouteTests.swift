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
        pairingStore: PairingCodeStore,
        config: RelayConfig = .default
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
            pairingStore: pairingStore,
            config: config
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

    func testPairCreateReportsTLSOnlyWhenBothCertAndKeyArePresent() async throws {
        let store = PairingCodeStore()
        // No TLS config.
        let noTLS = RelayConfig()
        let (_, jsonNoTLS) = await route(.POST, "/pair/create", pairingStore: store, config: noTLS)
        XCTAssertEqual(jsonNoTLS?["tls"] as? Bool, false, "no cert/key → false")

        // Cert set, key missing (the defect case).
        var certOnly = RelayConfig()
        certOnly.tlsCert = "/path/to/cert.pem"
        let (_, jsonCertOnly) = await route(.POST, "/pair/create", pairingStore: store, config: certOnly)
        XCTAssertEqual(jsonCertOnly?["tls"] as? Bool, false, "cert without key → false")

        // Both set.
        var both = RelayConfig()
        both.tlsCert = "/path/to/cert.pem"
        both.tlsKey = "/path/to/key.pem"
        let (_, jsonBoth) = await route(.POST, "/pair/create", pairingStore: store, config: both)
        XCTAssertEqual(jsonBoth?["tls"] as? Bool, true, "cert + key → true")
    }

    func testPairCreateReportsConfiguredWSPort() async throws {
        let store = PairingCodeStore()
        var cfg = RelayConfig()
        cfg.wsPort = 12345
        let (_, json) = await route(.POST, "/pair/create", pairingStore: store, config: cfg)
        XCTAssertEqual(json?["wsPort"] as? Int, 12345, "wsPort comes from the injected config")
    }
}
