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

    init(http: any PushHTTPExecuting, endpoint: MessagesEndpoint, apiKey: String) {
        self.http = http
        self.endpoint = endpoint
        self.apiKey = apiKey
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
            // Transport errors are already redacted by PushHTTP; the key is
            // in a header, never in the thrown description.
            throw OptimizerError.unavailable
        }
        if response.status != 200 {
            // Status only — the body can quote the draft back at us.
            RelayLogger.log(.debug, category: "optimizer", "messages HTTP \(response.status)")
        }
        switch response.status {
        case 200: return response.body
        case 401, 403: throw OptimizerError.keyRejected
        case 429, 500...: throw OptimizerError.unavailable
        default: throw OptimizerError.malformed
        }
    }
}
