import XCTest
@testable import CodeRelayKit

/// Protocol v3 (multi-server spec §6.2): `auth_success` and `pair_success` may
/// carry the relay's persisted instance id and display name. Both keys are
/// optional and omitted when absent, so v2 clients and servers interoperate.
final class ServerIdentityMessageTests: ProtocolTestCase {

    private let identity = ServerIdentity(
        id: UUID(uuidString: "0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D")!,
        name: "studio-mac")

    func testProtocolVersionIsThree() {
        XCTAssertEqual(CodeRelayKit.protocolVersion, 3)
        XCTAssertEqual(CodeRelayKit.minProtocolVersion, 0, "v3 is additive; old clients stay accepted")
    }

    func testAuthSuccessEncodesServerIdentityAsFlatKeys() throws {
        let msg = ServerMessage.authSuccess(protocolVersion: 3, tokenId: "tok", capabilities: nil, server: identity)
        let data = try encoder.encode(MessageEnvelope.server(msg))
        let payload = try XCTUnwrap(try jsonObject(data)["payload"] as? [String: Any])
        XCTAssertEqual(payload["serverId"] as? String, "0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D")
        XCTAssertEqual(payload["serverName"] as? String, "studio-mac")
    }

    func testAuthSuccessOmitsServerKeysWhenNil() throws {
        let data = try encoder.encode(MessageEnvelope.server(.authSuccess(protocolVersion: 3, tokenId: "tok")))
        let payload = try XCTUnwrap(try jsonObject(data)["payload"] as? [String: Any])
        XCTAssertNil(payload["serverId"])
        XCTAssertNil(payload["serverName"])
    }

    func testAuthSuccessDecodesServerIdentity() throws {
        let json = """
        {"type":"auth_success","payload":{"protocolVersion":3,"tokenId":"tok",
         "serverId":"0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D","serverName":"studio-mac"}}
        """
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .server(.authSuccess(protocolVersion: 3, tokenId: "tok", capabilities: nil, server: identity)))
    }

    func testAuthSuccessFromV2ServerDecodesWithNilIdentity() throws {
        let json = #"{"type":"auth_success","payload":{"protocolVersion":2,"tokenId":"tok"}}"#
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.authSuccess(_, _, _, let server)) = decoded else { return XCTFail("wrong case: \(decoded)") }
        XCTAssertNil(server)
    }

    func testAuthSuccessWithUnparsableServerIdDecodesAsNoIdentity() throws {
        // A malformed id must not fail the whole auth reply: identity is a hint.
        let json = #"{"type":"auth_success","payload":{"protocolVersion":3,"serverId":"nope","serverName":"x"}}"#
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.authSuccess(_, _, _, let server)) = decoded else { return XCTFail("wrong case: \(decoded)") }
        XCTAssertNil(server)
    }

    func testAuthSuccessWithIdButNoNameDecodesEmptyName() throws {
        let json = #"{"type":"auth_success","payload":{"serverId":"0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D"}}"#
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.authSuccess(_, _, _, let server)) = decoded else { return XCTFail("wrong case: \(decoded)") }
        XCTAssertEqual(server, ServerIdentity(id: identity.id, name: ""))
    }

    func testPairSuccessRoundTripsServerIdentity() throws {
        let original = ServerMessage.pairSuccess(token: "t", tokenId: "i", label: "l", server: identity)
        let data = try encoder.encode(MessageEnvelope.server(original))
        let payload = try XCTUnwrap(try jsonObject(data)["payload"] as? [String: Any])
        XCTAssertEqual(payload["serverId"] as? String, identity.id.uuidString)
        XCTAssertEqual(payload["serverName"] as? String, "studio-mac")
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        XCTAssertEqual(decoded, .server(original))
    }

    func testPairSuccessWithoutIdentityStillDecodes() throws {
        let json = #"{"type":"pair_success","payload":{"token":"t","tokenId":"i","label":"l"}}"#
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .server(.pairSuccess(token: "t", tokenId: "i", label: "l")))
    }

    func testServerIdentityCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(identity)
        XCTAssertEqual(try JSONDecoder().decode(ServerIdentity.self, from: data), identity)
    }
}
