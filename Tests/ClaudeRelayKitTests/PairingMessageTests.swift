import XCTest
@testable import ClaudeRelayKit

final class PairingMessageTests: XCTestCase {

    func testPairRequestRoundTripsThroughEnvelope() throws {
        let message = ClientMessage.pairRequest(code: "K7QP2M4X", deviceName: "Miguel's iPhone", platform: "ios")
        let data = try JSONEncoder().encode(MessageEnvelope.client(message))
        let decoded = try JSONDecoder().decode(MessageEnvelope.self, from: data)
        guard case .client(let out) = decoded else { return XCTFail("expected client envelope") }
        XCTAssertEqual(out, message)
    }

    func testPairSuccessRoundTripsThroughEnvelope() throws {
        let message = ServerMessage.pairSuccess(token: "tok-abc", tokenId: "1a2b3c4d", label: "Miguel's iPhone (paired)")
        let data = try JSONEncoder().encode(MessageEnvelope.server(message))
        let decoded = try JSONDecoder().decode(MessageEnvelope.self, from: data)
        guard case .server(let out) = decoded else { return XCTFail("expected server envelope") }
        XCTAssertEqual(out, message)
    }

    func testTypeStrings() {
        XCTAssertEqual(ClientMessage.pairRequest(code: "K7QP2M4X", deviceName: "d", platform: "ios").typeString,
                       "pair_request")
        XCTAssertEqual(ServerMessage.pairSuccess(token: "t", tokenId: "i", label: "l").typeString,
                       "pair_success")
    }

    func testTypeStringsAreRegisteredAndUniqueAcrossDirections() {
        XCTAssertTrue(ClientMessage.allTypeStrings.contains("pair_request"))
        XCTAssertTrue(ServerMessage.allTypeStrings.contains("pair_success"))
        XCTAssertTrue(ClientMessage.allTypeStrings.isDisjoint(with: ServerMessage.allTypeStrings),
                      "envelope decoding requires disjoint type-string sets")
    }

    func testPairRequestWireKeys() throws {
        let message = ClientMessage.pairRequest(code: "K7QP2M4X", deviceName: "iPhone", platform: "ios")
        let data = try JSONEncoder().encode(MessageEnvelope.client(message))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "pair_request")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["code"] as? String, "K7QP2M4X")
        XCTAssertEqual(payload["deviceName"] as? String, "iPhone")
        XCTAssertEqual(payload["platform"] as? String, "ios")
    }
}
