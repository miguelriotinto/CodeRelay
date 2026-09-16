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
        let client = HTTPMessagesClient(http: http, endpoint: .anthropic, apiKey: "sk-ant-secret",
                                         provider: "anthropic", model: "claude-sonnet-5")
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
            let client = HTTPMessagesClient(http: http, endpoint: .anthropic, apiKey: "k",
                                         provider: "anthropic", model: "claude-sonnet-5")
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
        let client = HTTPMessagesClient(http: http, endpoint: .anthropic, apiKey: "k",
                                         provider: "anthropic", model: "claude-sonnet-5")
        do {
            _ = try await client.send(body: Data())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? OptimizerError, .unavailable)
        }
    }

    /// Review B-5/S-3: a 400 is the *permanent* misconfiguration (a model id this
    /// provider does not know) and it reaches the user as "could not rewrite this
    /// prompt", about their draft. It has to be diagnosable without turning debug
    /// logging on, and the two config values that caused it have to be in the line.
    func testNon2xxLogsTheStatusProviderAndModelWithoutTheBodyOrKey() async {
        let marker = "ZEBRA-BODY-7731"
        let http = ScriptedHTTP()
        await http.script(status: 400, body: Data(#"{"error":{"message":"model: \#(marker)"}}"#.utf8))
        let client = HTTPMessagesClient(http: http, endpoint: .anthropic, apiKey: "sk-ant-secret-7731",
                                        provider: "bedrock", model: "claude-sonnet-5")
        do {
            _ = try await client.send(body: Data())
            XCTFail("400 should throw")
        } catch {
            XCTAssertEqual(error as? OptimizerError, .malformed)
        }

        let recent = RelayLogger.store.recent(count: 2_000)
        let line = recent.last { $0.contains("messages HTTP 400") }
        XCTAssertNotNil(line, "a non-2xx must be logged")
        XCTAssertTrue(line?.contains("provider=bedrock") == true)
        XCTAssertTrue(line?.contains("model=claude-sonnet-5") == true)
        XCTAssertFalse(recent.contains { $0.contains(marker) }, "the response body reached the log")
        XCTAssertFalse(recent.contains { $0.contains("sk-ant-secret-7731") }, "the key reached the log")
    }

    /// Review S-1: the client only ever sees "try again", which reads as
    /// transient. A blocked egress or a wrong region is not, so the operator gets
    /// one error line naming the transport failure — redacted, and with the two
    /// config values that decide the endpoint.
    func testTransportFailureIsLoggedAtErrorWithoutTheKey() async {
        let http = ScriptedHTTP()
        await http.script(failure: PushHTTPError.transport("connection refused: bearer sk-leak-7731"))
        let client = HTTPMessagesClient(http: http, endpoint: .anthropic, apiKey: "sk-ant-secret",
                                        provider: "anthropic", model: "claude-opus-5")
        do {
            _ = try await client.send(body: Data())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? OptimizerError, .unavailable)
        }
        let recent = RelayLogger.store.recent(count: 2_000)
        let line = recent.last { $0.contains("messages transport failure") }
        XCTAssertNotNil(line, "a transport failure must be logged")
        XCTAssertTrue(line?.contains("provider=anthropic model=claude-opus-5") == true)
        XCTAssertTrue(line?.contains("connection refused") == true)
        XCTAssertFalse(recent.contains { $0.contains("sk-leak-7731") }, "PushHTTP.redact did not run")
    }

    /// T1 gap 4: a 200 carrying an HTML error page (misconfigured proxy) or a
    /// truncated body is not a transport failure and not a status failure — the
    /// client hands the bytes on and the *parse* is what refuses, with the fixed
    /// "could not rewrite this prompt" string rather than a raw decode error.
    func testTwoHundredWithANonJSONBodyIsMalformed() async {
        let http = ScriptedHTTP()
        await http.script(status: 200, body: Data("<html><body>502 Bad Gateway</body></html>".utf8))
        let client = HTTPMessagesClient(http: http, endpoint: .anthropic, apiKey: "k",
                                        provider: "anthropic", model: "claude-sonnet-5")
        let optimizer = PromptOptimizer(client: client, model: "claude-sonnet-5", sharesScreen: false)
        let context = PromptContext(draft: "hi", agentId: nil, agentDisplayName: nil,
                                    workingDirectory: "/tmp", screenLines: [],
                                    bracketedPaste: true, keyboardFlagsRawValue: 0)
        do {
            _ = try await optimizer.optimize(context)
            XCTFail("a non-JSON 200 should throw")
        } catch {
            XCTAssertEqual(error as? OptimizerError, .malformed)
            XCTAssertEqual((error as? OptimizerError)?.clientMessage,
                           "Optimizer could not rewrite this prompt")
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
