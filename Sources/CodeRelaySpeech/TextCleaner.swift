import Foundation
import LLM

/// Protocol for local text cleanup — enables mock injection in tests.
public protocol TextCleaning: Sendable {
    func clean(_ text: String) async throws -> String
}

/// Runs a local Qwen 3.5 0.8B GGUF model via llama.cpp (Metal GPU) to clean transcriptions.
/// Only handles filler word removal and punctuation fixes — prompt enhancement is cloud-based.
@MainActor
public final class TextCleaner: TextCleaning {

    public static let shared = TextCleaner()

    private var llm: LLM?
    private var unloadTimer: Task<Void, Never>?
    public private(set) var isLoaded = false

    /// Idle timeout before unloading the model to free memory.
    public static let idleTimeout: TimeInterval = 30

    /// Minimum word count worth sending through the LLM.
    public static let minimumWordCount = 3

    /// Path to the GGUF model file. Set by OnDeviceSpeechEngine after download.
    public var modelPath: URL?

    public init() {}

    /// Load a GGUF model from disk.
    public func loadModel(from path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw CleanerError.modelFileNotFound
        }

        // Context window: 512 tokens total (system prompt ~150 + user input ~100 + output ~200).
        // Keeping this tight prevents the model from rambling in <think> blocks.
        guard let model = LLM(from: path, maxTokenCount: 512) else {
            throw CleanerError.modelNotLoaded
        }

        model.useResolvedTemplate(
            systemPrompt: Self.systemPrompt
        )

        self.llm = model
        self.isLoaded = true
    }

    /// Remove filler words and fix punctuation using the on-device LLM.
    public func clean(_ text: String) async throws -> String {
        let wordCount = text.split(separator: " ").count

        // Short inputs don't benefit from LLM processing
        if wordCount < Self.minimumWordCount {
            return text
        }

        // Auto-load on first use
        if llm == nil, let path = modelPath {
            try loadModel(from: path)
        }

        guard let llm else {
            throw CleanerError.modelNotLoaded
        }

        llm.useResolvedTemplate(systemPrompt: Self.systemPrompt)
        resetIdleTimer()

        let prompt = "Clean this transcription:\n\(text)"

        // Race the LLM against a timeout — if cleanup takes too long, return original text.
        let model = llm
        let response: String = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await model.getCompletion(from: prompt)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                model.stop()
                return nil
            }
            // First non-nil result wins; cancel the other.
            for await result in group {
                if let result { group.cancelAll(); return result }
            }
            return text
        }

        let cleaned = Self.sanitizeResponse(response)

        if Self.looksHallucinated(input: text, output: cleaned) {
            return text
        }

        return cleaned.isEmpty ? text : cleaned
    }

    /// Release the model from memory.
    public func unload() {
        unloadTimer?.cancel()
        unloadTimer = nil
        llm = nil
        isLoaded = false
    }

    // MARK: - Private

    private func resetIdleTimer() {
        unloadTimer?.cancel()
        unloadTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTimeout))
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    public static let systemPrompt = """
        You are a transcription cleanup engine. Output ONLY the cleaned text. \
        Do NOT think, reason, or explain. Do NOT use <think> tags. \
        Remove filler words (um, uh, like, you know, so, basically). \
        Fix punctuation and capitalization. \
        Preserve the speaker's meaning exactly. \
        Do NOT add or rephrase content.
        """

    /// Strip any <think> reasoning blocks from LLM output.
    public static func sanitizeResponse(_ response: String) -> String {
        var result = response

        while let thinkStart = result.range(of: "<think>"),
              let thinkEnd = result.range(of: "</think>") {
            result.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detect likely hallucinated output from the LLM.
    public static func looksHallucinated(input: String, output: String) -> Bool {
        if output.count > input.count * 3, output.count > 100 {
            return true
        }
        if output.contains("```") { return true }
        if output.contains("<div") || output.contains("<script") || output.contains("<html") {
            return true
        }
        return false
    }
}

public enum CleanerError: Error, LocalizedError {
    case modelNotLoaded
    case modelFileNotFound

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Cleanup model not loaded"
        case .modelFileNotFound: return "Cleanup model file not found on disk"
        }
    }
}
