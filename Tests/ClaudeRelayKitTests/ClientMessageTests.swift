import XCTest
@testable import ClaudeRelayKit

/// Encoding, decoding, and round-trip tests for `ClientMessage`.
final class ClientMessageTests: ProtocolTestCase {

    // MARK: - ClientMessage Encoding Structure

    func testAuthRequestEncoding() throws {
        let msg = ClientMessage.authRequest(token: "my-token")
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "auth_request")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?["token"] as? String, "my-token")
    }

    func testSessionCreateEncoding() throws {
        let msg = ClientMessage.sessionCreate()
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_create")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertNotNil(payload)
        XCTAssertTrue(payload?.isEmpty ?? true)
    }

    func testSessionAttachEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ClientMessage.sessionAttach(sessionId: id)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_attach")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    }

    func testSessionResumeEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ClientMessage.sessionResume(sessionId: id)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_resume")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    }

    func testSessionDetachEncoding() throws {
        let msg = ClientMessage.sessionDetach
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)
        XCTAssertEqual(obj["type"] as? String, "session_detach")
    }

    func testResizeEncoding() throws {
        let msg = ClientMessage.resize(cols: 120, rows: 40)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "resize")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["cols"] as? Int, 120)
        XCTAssertEqual(payload?["rows"] as? Int, 40)
    }

    func testPingEncoding() throws {
        let msg = ClientMessage.ping
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)
        XCTAssertEqual(obj["type"] as? String, "ping")
    }

    func testRefreshEncoding() throws {
        let msg = ClientMessage.refresh
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)
        XCTAssertEqual(obj["type"] as? String, "refresh")
        XCTAssertEqual((obj["payload"] as? [String: Any])?.isEmpty, true)
    }

    // MARK: - Round-trip

    func testClientMessageRoundTrips() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let messages: [ClientMessage] = [
            .authRequest(token: "abc123"),
            .sessionCreate(),
            .sessionAttach(sessionId: id),
            .sessionResume(sessionId: id),
            .sessionDetach,
            .resize(cols: 80, rows: 24),
            .refresh,
            .ping
        ]

        for original in messages {
            let envelope = MessageEnvelope.client(original)
            let data = try encoder.encode(envelope)
            let decoded = try decoder.decode(MessageEnvelope.self, from: data)

            guard case .client(let roundTripped) = decoded else {
                XCTFail("Expected .client envelope, got \(decoded)")
                continue
            }
            XCTAssertEqual(original, roundTripped, "Round-trip failed for \(original)")
        }
    }

    // MARK: - Field Verification

    func testAuthRequestFieldVerification() throws {
        let json = #"{"type":"auth_request","payload":{"token":"secret-token-123"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .client(.authRequest(let token, let protocolVersion)) = envelope else {
            XCTFail("Expected authRequest"); return
        }
        XCTAssertEqual(token, "secret-token-123")
        XCTAssertNil(protocolVersion)
    }

    func testResizeFieldVerification() throws {
        let json = #"{"type":"resize","payload":{"cols":200,"rows":60}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .client(.resize(let cols, let rows)) = envelope else {
            XCTFail("Expected resize"); return
        }
        XCTAssertEqual(cols, 200)
        XCTAssertEqual(rows, 60)
    }

    // MARK: - sessionCreate with name

    func testSessionCreateWithNameEncoding() throws {
        let msg = ClientMessage.sessionCreate(name: "Rhaegar")
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_create")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["name"] as? String, "Rhaegar")
    }

    func testSessionCreateWithoutNameEncoding() throws {
        let msg = ClientMessage.sessionCreate(name: nil)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)
        XCTAssertEqual(obj["type"] as? String, "session_create")
    }

    func testSessionCreateWithNameRoundTrip() throws {
        let original = ClientMessage.sessionCreate(name: "Tyrion")
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(let roundTripped) = decoded else {
            XCTFail("Expected .client envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    func testSessionCreateWithoutNameRoundTrip() throws {
        let original = ClientMessage.sessionCreate(name: nil)
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(let roundTripped) = decoded else {
            XCTFail("Expected .client envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    // MARK: - sessionRename

    func testSessionRenameEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ClientMessage.sessionRename(sessionId: id, name: "Daenerys")
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_rename")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["name"] as? String, "Daenerys")
    }

    func testSessionRenameRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let original = ClientMessage.sessionRename(sessionId: id, name: "Sansa")
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(let roundTripped) = decoded else {
            XCTFail("Expected .client envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    func testSessionRenameFieldVerification() throws {
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"session_rename","payload":{"sessionId":"\#(id)","name":"Arya"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .client(.sessionRename(let sessionId, let name)) = envelope else {
            XCTFail("Expected sessionRename"); return
        }
        XCTAssertEqual(sessionId.uuidString, id)
        XCTAssertEqual(name, "Arya")
    }

    // MARK: - Previously untested cases

    func testSessionTerminateEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ClientMessage.sessionTerminate(sessionId: id)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_terminate")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    }

    func testSessionTerminateRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let original = ClientMessage.sessionTerminate(sessionId: id)
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(let roundTripped) = decoded else {
            XCTFail("Expected .client envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    func testSessionListEncoding() throws {
        let msg = ClientMessage.sessionList
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)
        XCTAssertEqual(obj["type"] as? String, "session_list")
    }

    func testSessionListAllEncoding() throws {
        let msg = ClientMessage.sessionListAll
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)
        XCTAssertEqual(obj["type"] as? String, "session_list_all")
    }

    func testSessionListRoundTrip() throws {
        let original = ClientMessage.sessionList
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(let roundTripped) = decoded else {
            XCTFail("Expected .client envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    func testSessionListAllRoundTrip() throws {
        let original = ClientMessage.sessionListAll
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(let roundTripped) = decoded else {
            XCTFail("Expected .client envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    func testPasteImageEncoding() throws {
        let base64 = "iVBORw0KGgoAAAANSUhEUg=="
        let msg = ClientMessage.pasteImage(data: base64)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "paste_image")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["data"] as? String, base64)
    }

    func testPasteImageRoundTrip() throws {
        let original = ClientMessage.pasteImage(data: "SGVsbG8gV29ybGQ=")
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(let roundTripped) = decoded else {
            XCTFail("Expected .client envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    // MARK: - skipReplay and protocolVersion

    func testSessionResumeWithSkipReplayTrue() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ClientMessage.sessionResume(sessionId: id, skipReplay: true)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["skipReplay"] as? Bool, true)
    }

    func testSessionResumeSkipReplayFalseOmitted() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ClientMessage.sessionResume(sessionId: id, skipReplay: false)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        let payload = obj["payload"] as? [String: Any]
        XCTAssertNil(payload?["skipReplay"], "skipReplay=false should be omitted from payload")
    }

    func testSessionResumeWithSkipReplayRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let original = ClientMessage.sessionResume(sessionId: id, skipReplay: true)
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(let roundTripped) = decoded else {
            XCTFail("Expected .client envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    func testAuthRequestWithProtocolVersion() throws {
        let msg = ClientMessage.authRequest(token: "tok", protocolVersion: 1)
        let envelope = MessageEnvelope.client(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["protocolVersion"] as? Int, 1)
    }

    func testAuthRequestWithProtocolVersionRoundTrip() throws {
        let original = ClientMessage.authRequest(token: "tok", protocolVersion: 1)
        let envelope = MessageEnvelope.client(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(let roundTripped) = decoded else {
            XCTFail("Expected .client envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    // MARK: - Boundary values

    func testResizeBoundaryValues() throws {
        let cases: [(UInt16, UInt16)] = [(0, 0), (1, 1), (65535, 65535)]
        for (cols, rows) in cases {
            let original = ClientMessage.resize(cols: cols, rows: rows)
            let envelope = MessageEnvelope.client(original)
            let data = try encoder.encode(envelope)
            let decoded = try decoder.decode(MessageEnvelope.self, from: data)
            guard case .client(let roundTripped) = decoded else {
                XCTFail("Expected .client envelope for \(cols)x\(rows)"); continue
            }
            XCTAssertEqual(original, roundTripped)
        }
    }

    // MARK: - Equatable

    func testClientMessageEquatable() {
        let id = UUID()
        XCTAssertEqual(ClientMessage.ping, ClientMessage.ping)
        XCTAssertEqual(ClientMessage.sessionCreate(), ClientMessage.sessionCreate())
        XCTAssertEqual(ClientMessage.authRequest(token: "a"), ClientMessage.authRequest(token: "a"))
        XCTAssertNotEqual(ClientMessage.authRequest(token: "a"), ClientMessage.authRequest(token: "b"))
        XCTAssertEqual(ClientMessage.sessionAttach(sessionId: id), ClientMessage.sessionAttach(sessionId: id))
        XCTAssertNotEqual(ClientMessage.ping, ClientMessage.sessionCreate())
    }
}
