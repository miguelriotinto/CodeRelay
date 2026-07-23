import XCTest
@testable import ClaudeRelayKit

final class PushMessageTests: ProtocolTestCase {
    func testRegisterPushTokenRoundTrips() throws {
        let original = ClientMessage.registerPushToken(
            platform: .apns, token: "abc123", deviceId: "dev-1",
            enabled: true, notifyOnFinished: false, topic: "com.claude.relay.mac")
        let data = try encoder.encode(MessageEnvelope.client(original))
        guard case .client(.registerPushToken(let p, let t, let d, let en, let nf, let topic)) =
                try decoder.decode(MessageEnvelope.self, from: data) else {
            XCTFail("Expected registerPushToken"); return
        }
        XCTAssertEqual(p, .apns)
        XCTAssertEqual(t, "abc123")
        XCTAssertEqual(d, "dev-1")
        XCTAssertTrue(en)
        XCTAssertFalse(nf)
        XCTAssertEqual(topic, "com.claude.relay.mac")
    }

    func testRegisterPushTokenDecodesWithoutTopic() throws {
        // Older clients omit `topic`; it must decode to nil (server then falls
        // back to the configured bundle id), proving backward compatibility.
        let json = #"{"type":"register_push_token","payload":{"platform":"apns","token":"t","deviceId":"d"}}"#
        guard case .client(.registerPushToken(_, _, _, let en, let nf, let topic)) =
                try decoder.decode(MessageEnvelope.self, from: Data(json.utf8)) else {
            XCTFail("Expected registerPushToken"); return
        }
        XCTAssertTrue(en, "enabled defaults to true when omitted")
        XCTAssertFalse(nf, "notifyOnFinished defaults to false when omitted")
        XCTAssertNil(topic)
    }

    func testUnregisterPushTokenRoundTrips() throws {
        let data = try encoder.encode(MessageEnvelope.client(.unregisterPushToken(deviceId: "dev-1")))
        guard case .client(.unregisterPushToken(let d)) =
                try decoder.decode(MessageEnvelope.self, from: data) else {
            XCTFail("Expected unregisterPushToken"); return
        }
        XCTAssertEqual(d, "dev-1")
    }

    func testPushTokenAckRoundTrips() throws {
        let data = try encoder.encode(MessageEnvelope.server(.pushTokenAck(accepted: true)))
        guard case .server(.pushTokenAck(let ok)) =
                try decoder.decode(MessageEnvelope.self, from: data) else {
            XCTFail("Expected pushTokenAck"); return
        }
        XCTAssertTrue(ok)
    }

    func testRegistrationValidationRejectsOversizeToken() {
        let reg = PushRegistration(platform: .apns, token: String(repeating: "x", count: 513),
                                   deviceId: "d", enabled: true, notifyOnFinished: false,
                                   updatedAt: Date())
        XCTAssertFalse(reg.isValid)
    }

    func testRegistrationValidationAcceptsNormal() {
        let reg = PushRegistration(platform: .fcm, token: "t", deviceId: "d",
                                   enabled: true, notifyOnFinished: true, updatedAt: Date())
        XCTAssertTrue(reg.isValid)
    }

    func testNewTypeStringsAreUniqueAcrossSets() {
        // Envelope decoder checks client set first, then server — collisions break routing.
        XCTAssertTrue(ClientMessage.allTypeStrings.isDisjoint(with: ServerMessage.allTypeStrings))
    }
}
