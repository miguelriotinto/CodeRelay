import XCTest
@testable import ClaudeRelayKit

/// Tests that live at the `MessageEnvelope` layer — type-string collision
/// guards and back-compat legacy decoding.
final class MessageEnvelopeTests: ProtocolTestCase {

    // MARK: - session_list_result Regression

    /// Regression: `session_list` used to collide with the client request of
    /// the same name. Server responses now use `session_list_result`, and the
    /// envelope must steer that to the server branch, not client.
    func testSessionListResultDecodesAsServer() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let json = """
        {"type":"session_list_result","payload":{"sessions":[{"id":"\(id.uuidString)","state":"active-attached","tokenId":"tok_1","createdAt":1735689600.0,"cols":80,"rows":24,"activity":"agent_active","agent":"claude"}]}}
        """
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionList(let sessions)) = envelope else {
            XCTFail("Expected .server(.sessionList), got \(envelope)")
            return
        }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, id)
        XCTAssertEqual(sessions[0].activity, .agentActive)
        XCTAssertEqual(sessions[0].agent, "claude")
    }

    // MARK: - Legacy activity values

    /// Backward compat: an old server that doesn't know about the `agent`
    /// field still sends `{"activity":"claude_active"}`. The new client must
    /// decode that to `.agentActive` with a nil agent ID. See
    /// `ActivityState.init(from:)` for the documented asymmetry.
    func testSessionActivityLegacyDecodes() throws {
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"session_activity","payload":{"sessionId":"\#(id)","activity":"claude_active"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionActivity(_, let activity, let agent, _, _, _)) = envelope else {
            XCTFail("Expected sessionActivity"); return
        }
        XCTAssertEqual(activity, .agentActive)
        XCTAssertNil(agent)
    }

    // MARK: - Error cases

    func testUnknownTypeStringThrows() {
        let json = #"{"type":"totally_unknown","payload":{}}"#
        XCTAssertThrowsError(try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("Expected dataCorrupted, got \(error)"); return
            }
        }
    }

    func testMalformedEnvelopeMissingType() {
        let json = #"{"payload":{}}"#
        XCTAssertThrowsError(try decoder.decode(MessageEnvelope.self, from: Data(json.utf8)))
    }

    func testMalformedEnvelopeMissingPayload() {
        let json = #"{"type":"ping"}"#
        XCTAssertThrowsError(try decoder.decode(MessageEnvelope.self, from: Data(json.utf8)))
    }

    func testEmptyTypeStringThrows() {
        let json = #"{"type":"","payload":{}}"#
        XCTAssertThrowsError(try decoder.decode(MessageEnvelope.self, from: Data(json.utf8)))
    }
}
