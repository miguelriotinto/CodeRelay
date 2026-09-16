import Foundation
import CodeRelayKit

/// Where to POST an Anthropic Messages request and which model to use when
/// the operator did not pick one. Both providers speak the same request and
/// response format; only the host and the model id differ.
struct MessagesEndpoint: Equatable, Sendable {
    let url: String
    let defaultModel: String

    static let anthropic = MessagesEndpoint(
        url: "https://api.anthropic.com/v1/messages",
        defaultModel: "claude-sonnet-5")

    /// Bedrock Mantle: Anthropic-compatible Messages API on AWS, bearer/API-key
    /// auth, no SigV4.
    static func bedrock(region: String) -> MessagesEndpoint {
        MessagesEndpoint(
            url: "https://bedrock-mantle.\(region).api.aws/anthropic/v1/messages",
            defaultModel: "anthropic.claude-sonnet-5")
    }

    static func resolve(provider: String, region: String) throws -> MessagesEndpoint {
        switch provider {
        case "anthropic":
            return .anthropic
        case "bedrock":
            guard RelayConfig.isValidOptimizerRegion(region) else {
                throw OptimizerError.configuration("invalid promptOptimizerRegion: \(region)")
            }
            return .bedrock(region: region)
        default:
            throw OptimizerError.configuration("unknown promptOptimizerProvider: \(provider)")
        }
    }
}

/// One Messages round trip: JSON in, JSON out. Abstracted so
/// `PromptOptimizer` is testable without a socket.
protocol MessagesSending: Sendable {
    func send(body: Data) async throws -> Data
}

/// `MessagesSending` over the push layer's bounded HTTP wrapper. Construct the
/// `PushHTTP` with `maxRetries: 0` — the optimizer has its own 12 s deadline
/// and a retry would only turn a slow failure into a guaranteed one.
struct HTTPMessagesClient: MessagesSending {
    private let http: any PushHTTPExecuting
    private let endpoint: MessagesEndpoint
    private let apiKey: String
    /// Carried for the log line only — see `send`. `provider`/`model` are the
    /// two config values that decide whether a request can ever succeed, so a
    /// failure that does not name them is a failure the operator has to guess at.
    private let provider: String
    private let model: String

    init(http: any PushHTTPExecuting, endpoint: MessagesEndpoint, apiKey: String,
         provider: String, model: String) {
        self.http = http
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.provider = provider
        self.model = model
    }

    func send(body: Data) async throws -> Data {
        let headers = [
            ("x-api-key", apiKey),
            ("anthropic-version", "2023-06-01"),
            ("content-type", "application/json"),
        ]
        let response: PushHTTPResponse
        do {
            response = try await http.post(url: endpoint.url, headers: headers, body: body)
        } catch {
            // The client only ever sees "Optimizer unavailable, try again", which
            // reads as transient; a blocked egress or a wrong region is not. The
            // key is in a header and never in the thrown description, and
            // `redact` is belt-and-braces for anything PushHTTP quotes back
            // (review S-1).
            RelayLogger.log(.error, category: "optimizer",
                "messages transport failure (provider=\(provider) model=\(model)): "
                + PushHTTP.redact("\(error)"))
            throw OptimizerError.unavailable
        }
        if response.status != 200 {
            // Status, provider and model — never the body (it can quote the draft
            // back at us) and never the key.
            //
            // The level splits on "can this request ever succeed?" (reviews B-5,
            // S-3; `RelayLogLevel` has no warning case, so it is error or info):
            // 400/404 means the configured model id does not exist for this
            // provider — permanent, and the client reads it as "could not rewrite
            // this prompt", i.e. as being about their draft, so it has to be
            // visible without turning debug logging on. 429 and 5xx are transient,
            // and 401/403 already draws a warn-once error from `PromptOptimizer`,
            // so those stay at info and cannot spam.
            let transient = response.status == 429 || response.status >= 500
                || response.status == 401 || response.status == 403
            RelayLogger.log(transient ? .info : .error, category: "optimizer",
                "messages HTTP \(response.status) (provider=\(provider) model=\(model))")
        }
        switch response.status {
        case 200: return response.body
        case 401, 403: throw OptimizerError.keyRejected
        case 429, 500...: throw OptimizerError.unavailable
        default: throw OptimizerError.malformed
        }
    }
}
