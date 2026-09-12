import Foundation

/// Protocol for cloud-based prompt enhancement — enables mock injection.
public protocol CloudEnhancing: Sendable {
    func enhance(_ text: String, bearerToken: String, region: String) async throws -> String
}

/// Calls AWS Bedrock Converse API with Claude Haiku to enhance transcribed speech into
/// a clear, actionable prompt. Requires a bearer token for authentication.
public final class CloudPromptEnhancer: CloudEnhancing {

    /// Bedrock cross-region inference profile for Claude Haiku.
    /// On-demand throughput requires an inference profile ID, not the raw model ID.
    public static let defaultModelId = "us.anthropic.claude-haiku-4-5-20251001-v1:0"

    /// The Bedrock model/inference-profile ID used by this enhancer.
    /// Defaults to `defaultModelId`, but can be overridden per instance (e.g.
    /// to target a newer Haiku after an upgrade).
    public let modelId: String

    /// System prompt that guides Haiku to enhance while staying faithful to intent.
    public static let systemPrompt = """
        You are a prompt enhancement engine. Your job is to take rough speech-to-text input \
        and sharpen it into a clear, well-structured instruction — while staying faithful \
        to the speaker's original intent.

        Rules:
        - Stay close to the original meaning — enhance clarity, do not change the task
        - Remove filler words, hesitation, and vague hedging
        - Make implicit expectations explicit (e.g. "do a review" → "review and identify issues")
        - Add reasonable scope qualifiers when the speaker's intent is obvious \
        (e.g. "improve performance" → "identify performance improvement opportunities")
        - Preserve ALL technical details exactly (file names, function names, error messages, paths)
        - Keep it concise — one focused instruction, not a paragraph
        - Do NOT invent requirements the speaker did not mention
        - Do NOT add commentary, explanation, or preamble
        - Output ONLY the enhanced prompt, nothing else

        Example:
        Input: "please do a review of this repo and improve the performance"
        Output: "Review the repository and identify simple performance improvement opportunities. \
        Focus on obvious inefficiencies and provide concise, actionable suggestions."
        """

    public init(modelId: String = CloudPromptEnhancer.defaultModelId) {
        self.modelId = modelId
    }

    /// Enhance a transcribed text into a clear prompt using Bedrock Haiku.
    /// - Parameters:
    ///   - text: Raw transcription from Whisper.
    ///   - bearerToken: AWS Bedrock bearer token.
    ///   - region: AWS region (e.g. "us-east-1").
    /// - Returns: The enhanced prompt string.
    private static let refusalPrefixes = [
        "I cannot enhance",
        "I can't enhance",
        "I'm unable to enhance",
        "I need actual",
        "I need more",
        "Need actual",
        "Need more",
        "This is not",
        "This isn't",
        "This doesn't appear",
        "This does not appear",
        "If you have a task",
        "Please provide",
        "I'd need",
        "I would need",
        "Could you clarify",
        "Can you clarify",
        "What specifically"
    ]

    /// Substrings that reveal Haiku is asking the user clarifying questions
    /// instead of producing a rewritten prompt.
    private static let refusalPhrases = [
        "could you clarify",
        "is unclear",
        "what is \"this\"",
        "provide those details",
        "need more context",
        "need more details"
    ]

    public func enhance(_ text: String, bearerToken: String, region: String) async throws -> String {
        guard !bearerToken.isEmpty else {
            throw EnhancerError.missingBearerToken
        }

        let endpoint = URL(
            string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(self.modelId)/converse"
        )!

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "system": [
                ["text": Self.systemPrompt]
            ],
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["text": "Enhance this into a clear prompt:\n\(text)"]
                    ]
                ]
            ],
            "inferenceConfig": [
                "maxTokens": 512,
                "temperature": 0.3
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EnhancerError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EnhancerError.bedrockError(statusCode: httpResponse.statusCode, message: body)
        }

        let enhanced = try parseResponse(data)

        let lowered = enhanced.lowercased()
        for prefix in Self.refusalPrefixes {
            if lowered.hasPrefix(prefix.lowercased()) {
                throw EnhancerError.refused
            }
        }
        for phrase in Self.refusalPhrases {
            if lowered.contains(phrase) {
                throw EnhancerError.refused
            }
        }

        return enhanced
    }

    /// Parse the Bedrock Converse API response to extract the assistant's text.
    private func parseResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [String: Any],
              let message = output["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw EnhancerError.invalidResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum EnhancerError: Error, LocalizedError {
    case missingBearerToken
    case invalidResponse
    case refused
    case bedrockError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingBearerToken:
            return "Bearer token not configured. Add it in Settings."
        case .invalidResponse:
            return "Invalid response from Bedrock"
        case .refused:
            return "Could not enhance — input was unclear."
        case .bedrockError(let code, let message):
            return "Bedrock error \(code): \(Self.sanitizeBedrockError(message))"
        }
    }

    /// Strips auth material and returns at most 200 characters of the Bedrock
    /// error body. When the response is JSON-shaped we extract the `message`
    /// field; otherwise we fall back to a length-capped copy with any
    /// `Bearer <token>` fragments redacted.
    private static func sanitizeBedrockError(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = json["message"] as? String {
            return String(msg.prefix(200))
        }
        let truncated = String(body.prefix(200))
        return truncated.replacingOccurrences(
            of: "Bearer [A-Za-z0-9+/=._-]+",
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
    }
}
