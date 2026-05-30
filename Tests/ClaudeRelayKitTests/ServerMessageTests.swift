import XCTest
@testable import ClaudeRelayKit

// swiftlint:disable:next type_body_length
final class ServerMessageTests: ProtocolTestCase {

    // MARK: - ServerMessage Encoding Structure

    func testAuthSuccessEncoding() throws {
        let msg = ServerMessage.authSuccess()
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)
        XCTAssertEqual(obj["type"] as? String, "auth_success")
    }

    func testAuthFailureEncoding() throws {
        let msg = ServerMessage.authFailure(reason: "invalid token")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "auth_failure")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["reason"] as? String, "invalid token")
    }

    func testSessionCreatedEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionCreated(sessionId: id, cols: 80, rows: 24)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_created")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["cols"] as? Int, 80)
        XCTAssertEqual(payload?["rows"] as? Int, 24)
    }

    func testSessionAttachedEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionAttached(sessionId: id, state: "running")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_attached")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["state"] as? String, "running")
    }

    func testSessionResumedEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionResumed(sessionId: id)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_resumed")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    }

    func testReplayCompleteEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.replayComplete(sessionId: id)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "replay_complete")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    }

    func testReplayCompleteFieldVerification() throws {
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"replay_complete","payload":{"sessionId":"\#(id)"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.replayComplete(let sessionId)) = envelope else {
            XCTFail("Expected replayComplete"); return
        }
        XCTAssertEqual(sessionId.uuidString, id)
    }

    func testReplayCompleteTypeString() {
        let id = UUID()
        let msg = ServerMessage.replayComplete(sessionId: id)
        XCTAssertEqual(msg.typeString, "replay_complete")
        XCTAssert(ServerMessage.allTypeStrings.contains("replay_complete"))
    }

    func testSessionDetachedEncoding() throws {
        let msg = ServerMessage.sessionDetached
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)
        XCTAssertEqual(obj["type"] as? String, "session_detached")
    }

    func testSessionTerminatedEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionTerminated(sessionId: id, reason: "user exit")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_terminated")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["reason"] as? String, "user exit")
    }

    func testSessionExpiredEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionExpired(sessionId: id)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_expired")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    }

    func testSessionStateEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionState(sessionId: id, state: "idle")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_state")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["state"] as? String, "idle")
    }

    func testResizeAckEncoding() throws {
        let msg = ServerMessage.resizeAck(cols: 120, rows: 40)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "resize_ack")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["cols"] as? Int, 120)
        XCTAssertEqual(payload?["rows"] as? Int, 40)
    }

    func testPongEncoding() throws {
        let msg = ServerMessage.pong
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)
        XCTAssertEqual(obj["type"] as? String, "pong")
    }

    func testErrorEncoding() throws {
        let msg = ServerMessage.error(code: 404, message: "not found")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "error")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["code"] as? Int, 404)
        XCTAssertEqual(payload?["message"] as? String, "not found")
    }

    // MARK: - Round-trip

    func testServerMessageRoundTrips() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let messages: [ServerMessage] = [
            .authSuccess(),
            .authFailure(reason: "bad creds"),
            .sessionCreated(sessionId: id, cols: 80, rows: 24),
            .sessionAttached(sessionId: id, state: "running"),
            .sessionResumed(sessionId: id),
            .replayComplete(sessionId: id),
            .sessionDetached,
            .sessionTerminated(sessionId: id, reason: "exit"),
            .sessionExpired(sessionId: id),
            .sessionState(sessionId: id, state: "idle"),
            .sessionActivity(sessionId: id, activity: .agentIdle, agent: "claude"),
            .sessionStolen(sessionId: id),
            .sessionRenamed(sessionId: id, name: "Varys"),
            .resizeAck(cols: 120, rows: 40),
            .pong,
            .error(code: 500, message: "internal")
        ]

        for original in messages {
            let envelope = MessageEnvelope.server(original)
            let data = try encoder.encode(envelope)
            let decoded = try decoder.decode(MessageEnvelope.self, from: data)

            guard case .server(let roundTripped) = decoded else {
                XCTFail("Expected .server envelope, got \(decoded)")
                continue
            }
            XCTAssertEqual(original, roundTripped, "Round-trip failed for \(original)")
        }
    }

    // MARK: - Field Verification

    func testSessionCreatedFieldVerification() throws {
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"session_created","payload":{"sessionId":"\#(id)","cols":132,"rows":50}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionCreated(let sessionId, let cols, let rows)) = envelope else {
            XCTFail("Expected sessionCreated"); return
        }
        XCTAssertEqual(sessionId.uuidString, id)
        XCTAssertEqual(cols, 132)
        XCTAssertEqual(rows, 50)
    }

    func testErrorFieldVerification() throws {
        let json = #"{"type":"error","payload":{"code":429,"message":"rate limited"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.error(let code, let message)) = envelope else {
            XCTFail("Expected error"); return
        }
        XCTAssertEqual(code, 429)
        XCTAssertEqual(message, "rate limited")
    }

    func testSessionTerminatedFieldVerification() throws {
        let id = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let json = #"{"type":"session_terminated","payload":{"sessionId":"\#(id)","reason":"timeout"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionTerminated(let sessionId, let reason)) = envelope else {
            XCTFail("Expected sessionTerminated"); return
        }
        XCTAssertEqual(sessionId.uuidString, id)
        XCTAssertEqual(reason, "timeout")
    }

    // MARK: - sessionActivity

    func testSessionActivityEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionActivity(sessionId: id, activity: .agentIdle, agent: "codex")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_activity")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["activity"] as? String, "agent_idle")
        XCTAssertEqual(payload?["agent"] as? String, "codex")
    }

    func testSessionActivityFieldVerification() throws {
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"session_activity","payload":{"sessionId":"\#(id)","activity":"agent_active","agent":"claude"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionActivity(let sessionId, let activity, let agent)) = envelope else {
            XCTFail("Expected sessionActivity"); return
        }
        XCTAssertEqual(sessionId.uuidString, id)
        XCTAssertEqual(activity, .agentActive)
        XCTAssertEqual(agent, "claude")
    }

    func testSessionActivityRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let states: [ActivityState] = [.active, .idle, .agentActive, .agentIdle]
        for state in states {
            let original = ServerMessage.sessionActivity(sessionId: id, activity: state, agent: "claude")
            let envelope = MessageEnvelope.server(original)
            let data = try encoder.encode(envelope)
            let decoded = try decoder.decode(MessageEnvelope.self, from: data)
            guard case .server(let roundTripped) = decoded else {
                XCTFail("Expected .server envelope"); continue
            }
            XCTAssertEqual(original, roundTripped, "Round-trip failed for activity \(state)")
        }
    }

    // MARK: - sessionStolen

    func testSessionStolenEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionStolen(sessionId: id)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_stolen")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    }

    func testSessionStolenFieldVerification() throws {
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"session_stolen","payload":{"sessionId":"\#(id)"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionStolen(let sessionId)) = envelope else {
            XCTFail("Expected sessionStolen"); return
        }
        XCTAssertEqual(sessionId.uuidString, id)
    }

    // MARK: - sessionRenamed

    func testSessionRenamedEncoding() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionRenamed(sessionId: id, name: "Cersei")
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_renamed")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["name"] as? String, "Cersei")
    }

    func testSessionRenamedRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let original = ServerMessage.sessionRenamed(sessionId: id, name: "Jon Snow")
        let envelope = MessageEnvelope.server(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .server(let roundTripped) = decoded else {
            XCTFail("Expected .server envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    func testSessionRenamedFieldVerification() throws {
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"session_renamed","payload":{"sessionId":"\#(id)","name":"Bran"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionRenamed(let sessionId, let name)) = envelope else {
            XCTFail("Expected sessionRenamed"); return
        }
        XCTAssertEqual(sessionId.uuidString, id)
        XCTAssertEqual(name, "Bran")
    }

    // MARK: - Previously untested cases

    func testSessionListResultEncoding() throws {
        let msg = ServerMessage.sessionList(sessions: [])
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_list_result")
        let payload = obj["payload"] as? [String: Any]
        let sessions = payload?["sessions"] as? [Any]
        XCTAssertEqual(sessions?.count, 0)
    }

    func testSessionListAllResultEncoding() throws {
        let msg = ServerMessage.sessionListAll(sessions: [])
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "session_list_all_result")
    }

    func testSessionListRoundTrip() throws {
        let original = ServerMessage.sessionList(sessions: [])
        let envelope = MessageEnvelope.server(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .server(let roundTripped) = decoded else {
            XCTFail("Expected .server envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    func testSessionListAllRoundTrip() throws {
        let original = ServerMessage.sessionListAll(sessions: [])
        let envelope = MessageEnvelope.server(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .server(let roundTripped) = decoded else {
            XCTFail("Expected .server envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    func testPasteImageResultTrueEncoding() throws {
        let msg = ServerMessage.pasteImageResult(success: true)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        XCTAssertEqual(obj["type"] as? String, "paste_image_result")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["success"] as? Bool, true)
    }

    func testPasteImageResultFalseEncoding() throws {
        let msg = ServerMessage.pasteImageResult(success: false)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["success"] as? Bool, false)
    }

    func testPasteImageResultRoundTrip() throws {
        for success in [true, false] {
            let original = ServerMessage.pasteImageResult(success: success)
            let envelope = MessageEnvelope.server(original)
            let data = try encoder.encode(envelope)
            let decoded = try decoder.decode(MessageEnvelope.self, from: data)
            guard case .server(let roundTripped) = decoded else {
                XCTFail("Expected .server envelope"); continue
            }
            XCTAssertEqual(original, roundTripped)
        }
    }

    func testAuthSuccessWithProtocolVersion() throws {
        let msg = ServerMessage.authSuccess(protocolVersion: 1)
        let envelope = MessageEnvelope.server(msg)
        let data = try encoder.encode(envelope)
        let obj = try jsonObject(data)

        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["protocolVersion"] as? Int, 1)
    }

    func testAuthSuccessWithProtocolVersionRoundTrip() throws {
        let original = ServerMessage.authSuccess(protocolVersion: 1)
        let envelope = MessageEnvelope.server(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .server(let roundTripped) = decoded else {
            XCTFail("Expected .server envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    func testSessionActivityWithNilAgent() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let original = ServerMessage.sessionActivity(sessionId: id, activity: .active, agent: nil)
        let envelope = MessageEnvelope.server(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .server(let roundTripped) = decoded else {
            XCTFail("Expected .server envelope"); return
        }
        XCTAssertEqual(original, roundTripped)
    }

    // MARK: - Equatable

    func testServerMessageEquatable() {
        let id = UUID()
        XCTAssertEqual(ServerMessage.pong, ServerMessage.pong)
        XCTAssertEqual(ServerMessage.authSuccess(), ServerMessage.authSuccess())
        XCTAssertEqual(ServerMessage.error(code: 1, message: "a"), ServerMessage.error(code: 1, message: "a"))
        XCTAssertNotEqual(ServerMessage.error(code: 1, message: "a"), ServerMessage.error(code: 2, message: "a"))
        XCTAssertEqual(ServerMessage.sessionCreated(sessionId: id, cols: 80, rows: 24),
                       ServerMessage.sessionCreated(sessionId: id, cols: 80, rows: 24))
    }
}
