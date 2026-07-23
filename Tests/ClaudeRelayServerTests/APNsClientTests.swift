import XCTest
import Foundation
import Crypto
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

/// Throwaway P-256 key generated for tests only (never a real APNs key).
private let testKeyPEM = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgdcCGeUTDk/yN47u5
qLTeaa0nYEvKwInRa2xAA37lAtihRANCAASS9TGEop3eF3hqn3rLLv5F8ylGmed0
mG62IZB3NEshqGWdlFphhZYHzWzKlga/GXBMKhOsuxU3sVK2XBUhhMAW
-----END PRIVATE KEY-----
"""

/// In-memory HTTP capture for APNs integration tests.
private actor MockHTTP: PushHTTPExecuting {
    var status: UInt = 200
    var responseBody = Data()
    private(set) var lastURL: String?
    private(set) var lastHeaders: [(String, String)] = []
    private(set) var lastBody = Data()

    func configure(status: UInt, body: Data = Data()) { self.status = status; self.responseBody = body }
    func post(url: String, headers: [(String, String)], body: Data) async throws -> PushHTTPResponse {
        lastURL = url; lastHeaders = headers; lastBody = body
        return PushHTTPResponse(status: status, headers: [], body: responseBody)
    }
    func url() -> String? { lastURL }
    func headers() -> [(String, String)] { lastHeaders }
    func bodyJSON() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: lastBody)) as? [String: Any]
    }
}

final class APNsClientTests: XCTestCase {
    private func config(sandbox: Bool = true) -> APNsConfig {
        APNsConfig(keyPEM: testKeyPEM, keyId: "KID123", teamId: "TEAM1",
                   bundleId: "com.claude.relay", useSandbox: sandbox)
    }

    func testJWTHasES256HeaderAndVerifiableSignature() async throws {
        let http = MockHTTP()
        let client = try APNsClient(config: config(), http: http,
                                    now: { Date(timeIntervalSince1970: 1000) })
        let jwt = try await client.makeJWT(at: Date(timeIntervalSince1970: 1000))
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)

        // Header
        let headerData = Data(base64URLEncoded: parts[0])!
        let header = try JSONSerialization.jsonObject(with: headerData) as! [String: String]
        XCTAssertEqual(header["alg"], "ES256")
        XCTAssertEqual(header["kid"], "KID123")

        // Signature must verify against the public key over "header.claims",
        // and be exactly 64 bytes (raw r||s).
        let sig = Data(base64URLEncoded: parts[2])!
        XCTAssertEqual(sig.count, 64, "JWS ES256 signature must be raw 64-byte r||s")
        let key = try P256.Signing.PrivateKey(pemRepresentation: testKeyPEM)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: sig)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: signingInput))
    }

    func testSendPostsAlertAndDeepLinkPayloadToDeviceEndpoint() async throws {
        let http = MockHTTP()
        await http.configure(status: 200)
        let client = try APNsClient(config: config(sandbox: true), http: http)
        let result = await client.send(deviceToken: "abc123", platform: .apns, topic: nil,
                                       title: "demo", body: "1 agent blocked",
                                       deepLink: "clauderelay://session/xyz", collapseKey: "ws_hash")
        XCTAssertEqual(result, .delivered)

        let url = await http.url()
        XCTAssertEqual(url, "https://api.sandbox.push.apple.com/3/device/abc123")
        let headers = await http.headers()
        XCTAssertTrue(headers.contains { $0.0 == "apns-topic" && $0.1 == "com.claude.relay" },
                      "nil topic falls back to the configured bundle id")
        XCTAssertTrue(headers.contains { $0.0 == "apns-push-type" && $0.1 == "alert" })
        XCTAssertTrue(headers.contains { $0.0 == "apns-collapse-id" && $0.1 == "ws_hash" })
        XCTAssertTrue(headers.contains { $0.0 == "authorization" && $0.1.hasPrefix("bearer ") })

        // Prove the tap-through payload is actually delivered.
        let json = await http.bodyJSON()
        let aps = json?["aps"] as? [String: Any]
        let alert = aps?["alert"] as? [String: Any]
        XCTAssertEqual(alert?["title"] as? String, "demo")
        XCTAssertEqual(alert?["body"] as? String, "1 agent blocked")
        XCTAssertEqual(json?["deepLink"] as? String, "clauderelay://session/xyz")
    }

    func testStatus410MapsToUnregistered() {
        XCTAssertEqual(APNsClient.interpret(status: 410, body: Data()), .unregistered)
    }

    func testBadDeviceTokenReasonMapsToUnregistered() {
        let body = try! JSONSerialization.data(withJSONObject: ["reason": "BadDeviceToken"])
        XCTAssertEqual(APNsClient.interpret(status: 400, body: body), .unregistered)
    }

    func testSuccessMapsToDelivered() {
        XCTAssertEqual(APNsClient.interpret(status: 200, body: Data()), .delivered)
    }

    func testUnregisteredResultFromSend() async throws {
        let http = MockHTTP()
        await http.configure(status: 410)
        let client = try APNsClient(config: config(), http: http)
        let result = await client.send(deviceToken: "dead", platform: .apns, topic: nil, title: "t", body: "b",
                                       deepLink: "d", collapseKey: "k")
        XCTAssertEqual(result, .unregistered)
    }

    func testExplicitTopicOverridesConfiguredBundleId() async throws {
        let http = MockHTTP()
        await http.configure(status: 200)
        let client = try APNsClient(config: config(sandbox: true), http: http)
        _ = await client.send(deviceToken: "abc123", platform: .apns, topic: "com.claude.relay.mac",
                              title: "t", body: "b", deepLink: "d", collapseKey: "k")
        let headers = await http.headers()
        XCTAssertTrue(headers.contains { $0.0 == "apns-topic" && $0.1 == "com.claude.relay.mac" },
                      "a per-device topic must override the configured bundle id")
    }
}

// Base64URL decode helper for tests.
extension Data {
    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s) else { return nil }
        self = d
    }
}
