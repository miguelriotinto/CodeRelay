import XCTest
@testable import CodeRelayServer

private actor ScriptedHTTP: PushHTTPExecuting {
    var status: UInt = 200
    var body = Data()
    var failure: Error?
    private(set) var lastURL: String?
    private(set) var lastHeaders: [(String, String)] = []
    private(set) var lastBody = Data()

    func script(status: UInt = 200, body: Data = Data(), failure: Error? = nil) {
        self.status = status; self.body = body; self.failure = failure
    }
    func post(url: String, headers: [(String, String)], body: Data) async throws -> PushHTTPResponse {
        lastURL = url; lastHeaders = headers; lastBody = body
        if let failure { throw failure }
        return PushHTTPResponse(status: status, headers: [], body: self.body)
    }
    func captured() -> (url: String?, headers: [(String, String)], body: Data) { (lastURL, lastHeaders, lastBody) }
}

final class MessagesClientTests: XCTestCase {
    func testEndpointsAndDefaults() throws {
        XCTAssertEqual(MessagesEndpoint.anthropic.url, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(MessagesEndpoint.anthropic.defaultModel, "claude-sonnet-5")
        let bedrock = MessagesEndpoint.bedrock(region: "eu-west-1")
        XCTAssertEqual(bedrock.url, "https://bedrock-mantle.eu-west-1.api.aws/anthropic/v1/messages")
        XCTAssertEqual(bedrock.defaultModel, "anthropic.claude-sonnet-5")

        XCTAssertEqual(try MessagesEndpoint.resolve(provider: "anthropic", region: "us-east-1"), .anthropic)
        XCTAssertEqual(try MessagesEndpoint.resolve(provider: "bedrock", region: "us-east-1"), .bedrock(region: "us-east-1"))
        XCTAssertThrowsError(try MessagesEndpoint.resolve(provider: "openai", region: "us-east-1")) {
            XCTAssertEqual($0 as? OptimizerError, .configuration("unknown promptOptimizerProvider: openai"))
        }
        XCTAssertThrowsError(try MessagesEndpoint.resolve(provider: "bedrock", region: "bad/region")) {
            XCTAssertEqual($0 as? OptimizerError, .configuration("invalid promptOptimizerRegion: bad/region"))
        }
    }

    func testSendPostsBodyWithAnthropicHeaders() async throws {
        let http = ScriptedHTTP()
        await http.script(status: 200, body: Data(#"{"ok":true}"#.utf8))
        let client = HTTPMessagesClient(http: http, endpoint: .anthropic, apiKey: "sk-ant-secret")
        let out = try await client.send(body: Data(#"{"model":"m"}"#.utf8))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), #"{"ok":true}"#)

        let captured = await http.captured()
        XCTAssertEqual(captured.url, MessagesEndpoint.anthropic.url)
        XCTAssertEqual(String(decoding: captured.body, as: UTF8.self), #"{"model":"m"}"#)
        let headers = Dictionary(uniqueKeysWithValues: captured.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["x-api-key"], "sk-ant-secret")
        XCTAssertEqual(headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(headers["content-type"], "application/json")
        XCTAssertNil(headers["authorization"], "Mantle and Anthropic both take x-api-key; no bearer header")
    }

    func testStatusMapping() async {
        let cases: [(UInt, OptimizerError)] = [
            (401, .keyRejected), (403, .keyRejected),
            (429, .unavailable), (500, .unavailable), (529, .unavailable),
            (400, .malformed), (404, .malformed),
        ]
        for (status, expected) in cases {
            let http = ScriptedHTTP()
            await http.script(status: status, body: Data("{}".utf8))
            let client = HTTPMessagesClient(http: http, endpoint: .anthropic, apiKey: "k")
            do {
                _ = try await client.send(body: Data())
                XCTFail("\(status) should throw")
            } catch {
                XCTAssertEqual(error as? OptimizerError, expected, "status \(status)")
            }
        }
    }

    func testTransportFailureIsUnavailable() async {
        let http = ScriptedHTTP()
        await http.script(failure: PushHTTPError.transport("connection refused"))
        let client = HTTPMessagesClient(http: http, endpoint: .anthropic, apiKey: "k")
        do {
            _ = try await client.send(body: Data())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? OptimizerError, .unavailable)
        }
    }

    func testClientMessagesAreTheFixedStrings() {
        XCTAssertEqual(OptimizerError.unavailable.clientMessage, "Optimizer unavailable, try again")
        XCTAssertEqual(OptimizerError.keyRejected.clientMessage, "Optimizer key rejected on the relay")
        XCTAssertEqual(OptimizerError.refused.clientMessage, "Optimizer could not rewrite this prompt")
        XCTAssertEqual(OptimizerError.malformed.clientMessage, "Optimizer could not rewrite this prompt")
        XCTAssertEqual(OptimizerError.draftTooLong.clientMessage, "Prompt too long to optimize")
        XCTAssertEqual(OptimizerError.configuration("x").clientMessage, "Optimizer not configured on the relay")
    }
}
