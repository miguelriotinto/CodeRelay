import XCTest
@testable import CodeRelayKit

/// Wire shapes for the prompt optimizer RPCs (spec §5.1). The one JSON literal
/// in `sharedOptimizeResultFixture` is byte-for-byte the Kotlin fixture
/// `CodeRelayAndroid/core-protocol/src/test/resources/shared_optimize_prompt_result.json`,
/// so both decoders are pinned to one contract.
final class OptimizerProtocolMessageTests: ProtocolTestCase {

    static let sharedOptimizeResultFixture =
        #"{"type":"optimize_prompt_result","payload":{"status":"ok","original":"get status and fix the failing test","prompt":"Run `git status`, then fix the failing test."}}"#

    private let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

    // MARK: Client → server

    func testOptimizePromptEncodesShareScreenEvenWhenFalse() throws {
        let data = try encoder.encode(MessageEnvelope.client(.optimizePrompt(sessionId: id, shareScreen: false)))
        let obj = try jsonObject(data)
        XCTAssertEqual(obj["type"] as? String, "optimize_prompt")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
        XCTAssertEqual(payload?["shareScreen"] as? Bool, false, "shareScreen is always explicit on the wire")
    }

    func testOptimizePromptRoundTrips() throws {
        let original = ClientMessage.optimizePrompt(sessionId: id, shareScreen: true)
        let data = try encoder.encode(MessageEnvelope.client(original))
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        XCTAssertEqual(decoded, .client(original))
    }

    func testOptimizePromptDefaultsShareScreenToFalseWhenAbsent() throws {
        let json = #"{"type":"optimize_prompt","payload":{"sessionId":"12345678-1234-1234-1234-123456789ABC"}}"#
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .client(.optimizePrompt(sessionId: id, shareScreen: false)))
    }

    func testReplacePromptRoundTripsMultiLineText() throws {
        let original = ClientMessage.replacePrompt(sessionId: id, text: "line one\nline two\n  indented")
        let data = try encoder.encode(MessageEnvelope.client(original))
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        XCTAssertEqual(decoded, .client(original))
    }

    // MARK: Server → client

    func testAuthSuccessOmitsCapabilitiesWhenNil() throws {
        let data = try encoder.encode(MessageEnvelope.server(.authSuccess(protocolVersion: 2, tokenId: "tok")))
        let payload = try jsonObject(data)["payload"] as? [String: Any]
        XCTAssertNil(payload?["capabilities"], "an absent capability list must not encode as null")
    }

    func testAuthSuccessFromOlderServerDecodesWithoutCapabilities() throws {
        let json = #"{"type":"auth_success","payload":{"protocolVersion":1,"tokenId":"tok"}}"#
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .server(.authSuccess(protocolVersion: 1, tokenId: "tok", capabilities: nil)))
    }

    func testAuthSuccessRoundTripsCapabilities() throws {
        let original = ServerMessage.authSuccess(protocolVersion: 2, tokenId: "tok",
                                                 capabilities: [CodeRelayKit.promptOptimizerCapability])
        let data = try encoder.encode(MessageEnvelope.server(original))
        let payload = try jsonObject(data)["payload"] as? [String: Any]
        XCTAssertEqual(payload?["capabilities"] as? [String], ["prompt_optimizer"])
        XCTAssertEqual(try decoder.decode(MessageEnvelope.self, from: data), .server(original))
    }

    func testOptimizePromptResultOmitsNilFields() throws {
        let data = try encoder.encode(MessageEnvelope.server(
            .optimizePromptResult(status: "failed", message: "Session not attached")))
        let obj = try jsonObject(data)
        XCTAssertEqual(obj["type"] as? String, "optimize_prompt_result")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["status"] as? String, "failed")
        XCTAssertEqual(payload?["message"] as? String, "Session not attached")
        XCTAssertNil(payload?["original"])
        XCTAssertNil(payload?["prompt"])
    }

    func testOptimizePromptResultDecodesSharedFixture() throws {
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(Self.sharedOptimizeResultFixture.utf8))
        XCTAssertEqual(decoded, .server(.optimizePromptResult(
            status: "ok",
            original: "get status and fix the failing test",
            prompt: "Run `git status`, then fix the failing test.",
            message: nil)))
    }

    func testOptimizePromptResultRoundTripsAllFields() throws {
        let original = ServerMessage.optimizePromptResult(status: "ok", original: "a", prompt: "b", message: "c")
        let data = try encoder.encode(MessageEnvelope.server(original))
        XCTAssertEqual(try decoder.decode(MessageEnvelope.self, from: data), .server(original))
    }

    func testReplacePromptResultRoundTrips() throws {
        for original in [ServerMessage.replacePromptResult(status: "ok"),
                         .replacePromptResult(status: "failed", message: "Replacement too long")] {
            let data = try encoder.encode(MessageEnvelope.server(original))
            XCTAssertEqual(try jsonObject(data)["type"] as? String, "replace_prompt_result")
            XCTAssertEqual(try decoder.decode(MessageEnvelope.self, from: data), .server(original))
        }
    }

    // MARK: Registry

    func testNewTypeStringsAreRegisteredAndDisjoint() {
        XCTAssertTrue(ClientMessage.allTypeStrings.isSuperset(of: ["optimize_prompt", "replace_prompt"]))
        XCTAssertTrue(ServerMessage.allTypeStrings.isSuperset(of: ["optimize_prompt_result", "replace_prompt_result"]))
        XCTAssertTrue(ClientMessage.allTypeStrings.isDisjoint(with: ServerMessage.allTypeStrings))
    }

    func testProtocolVersionAndCapabilityName() {
        XCTAssertEqual(CodeRelayKit.protocolVersion, 2)
        XCTAssertEqual(CodeRelayKit.minProtocolVersion, 0, "older clients keep connecting")
        XCTAssertEqual(CodeRelayKit.promptOptimizerCapability, "prompt_optimizer")
    }
}
