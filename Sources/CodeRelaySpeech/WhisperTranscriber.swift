import Foundation
import WhisperKit

/// Protocol for speech transcription — enables mock injection in tests.
public protocol SpeechTranscribing: Sendable {
    func transcribe(_ audioBuffer: [Float], skipNoSpeechFilter: Bool) async throws -> String
}

extension SpeechTranscribing {
    public func transcribe(_ audioBuffer: [Float]) async throws -> String {
        try await transcribe(audioBuffer, skipNoSpeechFilter: false)
    }
}

/// Wraps WhisperKit to transcribe [Float] audio buffers into text.
/// Shared singleton so the model stays loaded across session switches.
///
/// Lives on `@MainActor` because every call site is already main-actor-isolated
/// (`OnDeviceSpeechEngine` and SwiftUI views). This lets us hold mutable
/// `whisperKit` state safely under Swift 6 without the `@unchecked Sendable`
/// escape hatch.
@MainActor
public final class WhisperTranscriber: SpeechTranscribing {

    public static let shared = WhisperTranscriber()

    private var whisperKit: WhisperKit?
    public private(set) var isLoaded = false

    public init() {}

    /// Download and load the Whisper small.en model.
    /// WhisperKit manages its own model storage under Application Support.
    /// - Parameter progressCallback: Reports 0.0–1.0 as WhisperKit transitions
    ///   through loading → loaded → prewarming → prewarmed.
    public func loadModel(progressCallback: (@Sendable (Double) -> Void)? = nil) async throws {
        // Init without loading so we can attach the state callback first.
        let kit = try await WhisperKit(
            model: "openai_whisper-small.en",
            verbose: false,
            prewarm: false,
            load: false
        )

        if let progressCallback {
            kit.modelStateCallback = { _, newState in
                switch newState {
                case .loading:     progressCallback(0.1)
                case .loaded:      progressCallback(0.5)
                case .prewarming:  progressCallback(0.7)
                case .prewarmed:   progressCallback(1.0)
                default: break
                }
            }
        }

        try await kit.loadModels()
        try await kit.prewarmModels()

        // Clear the state callback so it doesn't fire during transcription.
        // WhisperKit re-validates model state internally and emits transitions
        // that would otherwise re-trigger the caller's progress UI.
        kit.modelStateCallback = nil

        self.whisperKit = kit
        self.isLoaded = true
    }

    /// Transcribe a 16kHz mono Float32 audio buffer.
    /// - Parameter skipNoSpeechFilter: When true, disables the no-speech
    ///   threshold (safe when VAD already confirmed speech) but keeps the
    ///   compression-ratio threshold active to catch decoder repetition loops.
    public func transcribe(
        _ audioBuffer: [Float],
        skipNoSpeechFilter: Bool
    ) async throws -> String {
        guard let whisperKit else {
            throw TranscriberError.modelNotLoaded
        }

        var options: DecodingOptions? = nil
        if skipNoSpeechFilter {
            var opts = DecodingOptions()
            opts.noSpeechThreshold = nil
            options = opts
        }

        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: audioBuffer,
            decodeOptions: options
        )

        let text = results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw TranscriberError.emptyTranscription
        }

        return Self.collapseRepetitions(text)
    }

    // Two tiers: sentence-level catches punctuated loops, char-level catches unpunctuated
    nonisolated static func collapseRepetitions(_ text: String) -> String {
        let len = text.count
        guard len > 20 else { return text }

        if let collapsed = collapseSentenceRepetitions(text) {
            return collapsed
        }

        if let collapsed = collapseCharacterRepetitions(text) {
            return collapsed
        }

        return text
    }

    /// Split on sentence-ending punctuation and check if segments are
    /// near-identical (handles "Check dir? Check dir? Check dir?").
    nonisolated private static func collapseSentenceRepetitions(_ text: String) -> String? {
        let segments = text
            .components(separatedBy: CharacterSet(charactersIn: ".?!"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard segments.count >= 2 else { return nil }

        let reference = segments[0].lowercased()
        guard reference.count >= 8 else { return nil }

        let matchCount = segments.filter { seg in
            let normalized = seg.lowercased()
            if normalized == reference { return true }
            let dist = levenshteinDistance(normalized, reference)
            return dist <= max(2, reference.count / 5)
        }.count

        guard matchCount == segments.count else { return nil }

        let originalPunctuation = text.last.map { CharacterSet(charactersIn: ".?!").contains(Unicode.Scalar(String($0))!) } ?? false
        let suffix = originalPunctuation ? String(text.last!) : ""
        return segments[0] + suffix
    }

    /// Find the shortest repeating prefix unit (handles direct concatenation
    /// like "check dircheck dircheck dir").
    nonisolated private static func collapseCharacterRepetitions(_ text: String) -> String? {
        let len = text.count
        let minUnit = 10
        guard len >= minUnit * 2 else { return nil }

        for unitLen in minUnit...(len / 2) {
            let unit = String(text.prefix(unitLen))
            let count = len / unitLen
            guard count >= 2 else { continue }
            let reconstructed = String(repeating: unit, count: count)
            guard text.hasPrefix(reconstructed) else { continue }
            let remainder = String(text.dropFirst(reconstructed.count))
            let trimmedRemainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            let tolerance = max(3, unit.count / 3)
            if trimmedRemainder.isEmpty || levenshteinDistance(trimmedRemainder, unit) <= tolerance {
                return unit.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    nonisolated private static func levenshteinDistance(_ s: String, _ t: String) -> Int {
        let sArr = Array(s)
        let tArr = Array(t)
        let sLen = sArr.count, tLen = tArr.count
        if sLen == 0 { return tLen }
        if tLen == 0 { return sLen }
        var prev = Array(0...tLen)
        var curr = [Int](repeating: 0, count: tLen + 1)
        for i in 1...sLen {
            curr[0] = i
            for j in 1...tLen {
                let cost = sArr[i-1] == tArr[j-1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
            }
            prev = curr
        }
        return prev[tLen]
    }

    /// Release the model from memory.
    public func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
        isLoaded = false
    }
}

public enum TranscriberError: Error, LocalizedError {
    case modelNotLoaded
    case emptyTranscription

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Whisper model not loaded"
        case .emptyTranscription: return "No speech detected"
        }
    }

    /// Phrases Whisper commonly hallucinates from silence or background noise.
    /// Compared case-insensitively after stripping punctuation.
    public static let silenceHallucinations: Set<String> = [
        "thank you",
        "thanks",
        "thanks for watching",
        "thank you for watching",
        "bye",
        "goodbye",
        "subscribe",
        "like and subscribe",
        "see you next time",
        "see you",
        "you",
        "the end",
        "so",
        "okay",
        "hmm",
        "oh",
        "ah"
    ]

    /// Returns true if the text is a known Whisper silence hallucination.
    public static func isSilenceHallucination(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .joined(separator: " ")
            .split(separator: " ")
            .joined(separator: " ")
        return silenceHallucinations.contains(normalized)
    }
}
