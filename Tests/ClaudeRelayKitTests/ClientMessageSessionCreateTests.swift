import XCTest
@testable import ClaudeRelayKit

/// Tests for the optional `cols`/`rows` fields on `ClientMessage.sessionCreate`.
final class ClientMessageSessionCreateTests: ProtocolTestCase {

    func testSessionCreateRoundTripsWithSize() throws {
        let original = ClientMessage.sessionCreate(name: "dev", cols: 120, rows: 40)
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(.sessionCreate(let name, let cols, let rows)) = decoded else {
            XCTFail("Expected sessionCreate"); return
        }
        XCTAssertEqual(name, "dev")
        XCTAssertEqual(cols, 120)
        XCTAssertEqual(rows, 40)
    }

    func testSessionCreateRoundTripsWithoutSize() throws {
        let original = ClientMessage.sessionCreate(name: "dev")
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(.sessionCreate(let name, let cols, let rows)) = decoded else {
            XCTFail("Expected sessionCreate"); return
        }
        XCTAssertEqual(name, "dev")
        XCTAssertNil(cols)
        XCTAssertNil(rows)
    }

    func testLegacySessionCreateJSONWithoutSizeDecodes() throws {
        let json = #"{"type":"session_create","payload":{"name":"legacy"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .client(.sessionCreate(let name, let cols, let rows)) = envelope else {
            XCTFail("Expected sessionCreate"); return
        }
        XCTAssertEqual(name, "legacy")
        XCTAssertNil(cols)
        XCTAssertNil(rows)
    }
}
