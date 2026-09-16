import XCTest
@testable import CodeRelayKit

/// The optional `cols`/`rows` grid on `session_attach` and `session_resume`
/// (the session-switch garble fix). Absent fields must decode as nil and nil
/// fields must be omitted from the JSON, so old clients and servers interoperate.
final class ClientMessageAttachGridTests: ProtocolTestCase {

    func testSessionAttachRoundTripsWithGrid() throws {
        let id = UUID()
        let data = try encoder.encode(MessageEnvelope.client(.sessionAttach(sessionId: id, cols: 100, rows: 30)))
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(.sessionAttach(let sid, let cols, let rows)) = decoded else {
            XCTFail("Expected sessionAttach"); return
        }
        XCTAssertEqual(sid, id)
        XCTAssertEqual(cols, 100)
        XCTAssertEqual(rows, 30)
    }

    func testSessionAttachOmitsGridWhenNil() throws {
        let id = UUID()
        let data = try encoder.encode(MessageEnvelope.client(.sessionAttach(sessionId: id)))
        guard let json = String(bytes: data, encoding: .utf8) else {
            XCTFail("Failed to decode JSON"); return
        }
        XCTAssertFalse(json.contains("cols"), json)
        XCTAssertFalse(json.contains("rows"), json)
        guard case .client(.sessionAttach(_, let cols, let rows)) = try decoder.decode(MessageEnvelope.self, from: data) else {
            XCTFail("Expected sessionAttach"); return
        }
        XCTAssertNil(cols)
        XCTAssertNil(rows)
    }

    func testSessionResumeRoundTripsWithGridAndSkipReplay() throws {
        let id = UUID()
        let data = try encoder.encode(MessageEnvelope.client(.sessionResume(sessionId: id, skipReplay: true, cols: 80, rows: 24)))
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(.sessionResume(let sid, let skip, let cols, let rows)) = decoded else {
            XCTFail("Expected sessionResume"); return
        }
        XCTAssertEqual(sid, id)
        XCTAssertTrue(skip)
        XCTAssertEqual(cols, 80)
        XCTAssertEqual(rows, 24)
    }

    func testLegacySessionResumeJSONWithoutGridDecodes() throws {
        let id = UUID()
        let json = #"{"type":"session_resume","payload":{"sessionId":"\#(id.uuidString)"}}"#
        guard case .client(.sessionResume(let sid, let skip, let cols, let rows)) =
                try decoder.decode(MessageEnvelope.self, from: Data(json.utf8)) else {
            XCTFail("Expected sessionResume"); return
        }
        XCTAssertEqual(sid, id)
        XCTAssertFalse(skip)
        XCTAssertNil(cols)
        XCTAssertNil(rows)
    }

    func testSessionResumeOmitsGridWhenNil() throws {
        let data = try encoder.encode(MessageEnvelope.client(.sessionResume(sessionId: UUID())))
        guard let json = String(bytes: data, encoding: .utf8) else {
            XCTFail("Failed to decode JSON"); return
        }
        XCTAssertFalse(json.contains("cols"), json)
        XCTAssertFalse(json.contains("rows"), json)
        XCTAssertFalse(json.contains("skipReplay"), json)
    }
}
