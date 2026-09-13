import Foundation

enum OptimizerOutcome: Equatable, Sendable {
    case optimized(String)
    case passthrough
}

/// What the handlers and the admin route depend on. `sharesScreen` is the
/// server-wide cap from `promptOptimizerShareScreen`; screen is included in
/// the optimizer request only when both it and the client's `shareScreen` are
/// true. The handler (Task 11) performs the AND.
protocol PromptOptimizing: Sendable {
    var sharesScreen: Bool { get }
    func optimize(_ context: PromptContext) async throws -> OptimizerOutcome
}

/// Builds the Messages request, sends it, parses the forced `deliver_prompt`
/// tool call. Stateless apart from the warn-once flag for a rejected key.
final class PromptOptimizer: PromptOptimizing, @unchecked Sendable {
    static let maxDraftBytes = 4096
    static let toolName = "deliver_prompt"

    let sharesScreen: Bool
    private let client: any MessagesSending
    private let model: String
    private let lock = NSLock()
    private var warnedKeyRejected = false

    init(client: any MessagesSending, model: String, sharesScreen: Bool) {
        self.client = client
        self.model = model
        self.sharesScreen = sharesScreen
    }

    func optimize(_ context: PromptContext) async throws -> OptimizerOutcome {
        guard context.draft.utf8.count <= Self.maxDraftBytes else { throw OptimizerError.draftTooLong }
        let body = try Self.requestBody(model: model, context: context)
        let started = ContinuousClock.now
        let data: Data
        do {
            data = try await client.send(body: body)
        } catch OptimizerError.keyRejected {
            warnKeyRejectedOnce()
            throw OptimizerError.keyRejected
        }
        let (outcome, cacheRead) = try Self.parseResponse(data)
        // Debug telemetry only: sizes, cache hit, latency. Never the text.
        let latencyMs = (ContinuousClock.now - started).components.seconds * 1000 + (ContinuousClock.now - started).components.attoseconds / 1_000_000_000_000_000
        RelayLogger.log(.debug, category: "optimizer",
            "optimize: draft=\(context.draft.utf8.count)B screen=\(context.screenLines.count) lines cache_read=\(cacheRead.map(String.init) ?? "-") latencyMs=\(latencyMs)")
        return outcome
    }

    private func warnKeyRejectedOnce() {
        lock.lock(); defer { lock.unlock() }
        guard !warnedKeyRejected else { return }
        warnedKeyRejected = true
        RelayLogger.log(.error, category: "optimizer",
            "provider rejected the API key (401/403); check promptOptimizerKeyPath")
    }

    // MARK: - Request

    static func requestBody(model: String, context: PromptContext) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": [[
                "type": "text",
                "text": OptimizerSystemPrompt.text,
                "cache_control": ["type": "ephemeral"],
            ]],
            "tools": [[
                "name": toolName,
                "description": "Deliver the rewritten prompt, or pass the draft through unchanged.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": ["optimized", "passthrough"]],
                        "prompt": ["type": "string", "description": "The rewritten prompt. Required when kind is optimized; omit for passthrough."],
                    ],
                    "required": ["kind"],
                    "additionalProperties": false,
                ],
            ]],
            "tool_choice": ["type": "tool", "name": toolName],
            "messages": [["role": "user", "content": userContent(context)]],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// `<agent>` is omitted for a plain shell, `<screen>` when not shared.
    /// Closing tags inside user-controlled text are defanged so the draft or
    /// the screen cannot terminate their own block early.
    static func userContent(_ context: PromptContext) -> String {
        var parts: [String] = []
        if let name = context.agentDisplayName {
            parts.append("<agent>\(escape(name))</agent>")
        }
        parts.append("<cwd>\(escape(context.workingDirectory ?? "unknown"))</cwd>")
        if !context.screenLines.isEmpty {
            parts.append("<screen untrusted=\"true\">\n\(context.screenLines.map(escape).joined(separator: "\n"))\n</screen>")
        }
        parts.append("<draft>\(escape(context.draft))</draft>")
        return parts.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "</", with: "<\u{200B}/")
    }

    // MARK: - Response

    static func parseOutcome(_ data: Data) throws -> OptimizerOutcome {
        let (outcome, _) = try parseResponse(data)
        return outcome
    }

    private static func parseResponse(_ data: Data) throws -> (outcome: OptimizerOutcome, cacheReadTokens: Int?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OptimizerError.malformed
        }
        if json["stop_reason"] as? String == "refusal" { throw OptimizerError.refused }
        guard let content = json["content"] as? [[String: Any]],
              let block = content.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == toolName }),
              let input = block["input"] as? [String: Any],
              let kind = input["kind"] as? String else {
            throw OptimizerError.malformed
        }
        let allowedKeys: Set<String> = ["kind", "prompt"]
        guard Set(input.keys).isSubset(of: allowedKeys) else { throw OptimizerError.malformed }
        let outcome: OptimizerOutcome
        switch kind {
        case "passthrough":
            guard input["prompt"] == nil else { throw OptimizerError.malformed }
            outcome = .passthrough
        case "optimized":
            guard let prompt = input["prompt"] as? String,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OptimizerError.malformed
            }
            outcome = .optimized(prompt)
        default:
            throw OptimizerError.malformed
        }
        let cacheRead = (json["usage"] as? [String: Any])?["cache_read_input_tokens"] as? Int
        return (outcome, cacheRead)
    }
}
