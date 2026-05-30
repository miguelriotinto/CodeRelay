import Foundation
import os.log

private let log = Logger(subsystem: "com.claude.relay.speech", category: "WakeWord")

/// Result of a wake-word check.
public enum WakeWordResult: Equatable, Sendable {
    /// Wake word was found within the first few words of the transcription.
    /// `residueText` is the text after the wake word (ignored in strict
    /// two-phase mode, but returned for diagnostics / fallback use).
    case detected(residueText: String)
    case notDetected
    case transcriptionFailed
}

/// Detects a wake word at the start of a short speech segment.
///
/// Usage in strict two-phase mode:
///   1. On `speechStart`, reset and start feeding audio chunks.
///   2. On `silenceStart` (or max-window timeout), call `checkForWakeWord()`.
///   3. If `.detected` with empty residue → arm the command recorder.
///   4. If `.detected` with residue → treat as not-detected (strict mode
///      requires a pause between wake word and command).
///   5. If `.notDetected` or `.transcriptionFailed` → reset and resume listening.
@MainActor
public final class WakeWordDetector {

    public let keyword: String
    public let maxListenWindowSeconds: TimeInterval

    private let transcriber: any SpeechTranscribing
    private let sampleRate: Double

    private var accumulator: [Float] = []

    public init(
        transcriber: any SpeechTranscribing,
        keyword: String = "claude",
        maxListenWindowSeconds: TimeInterval = 2.5,
        sampleRate: Double = 16000
    ) {
        self.transcriber = transcriber
        self.keyword = keyword.lowercased()
        self.maxListenWindowSeconds = maxListenWindowSeconds
        self.sampleRate = sampleRate
    }

    /// Append audio samples from the current speech segment.
    /// Automatically caps to the most recent `maxListenWindowSeconds`.
    public func feedAudio(_ samples: [Float]) {
        accumulator.append(contentsOf: samples)
        let maxSamples = Int(maxListenWindowSeconds * sampleRate)
        if accumulator.count > maxSamples {
            accumulator.removeFirst(accumulator.count - maxSamples)
        }
    }

    /// Run transcription and check for the wake word. Applies preprocessing
    /// (gain normalization + silence padding) before transcription so Whisper
    /// sees a clip closer to the distribution it was trained on.
    public func checkForWakeWord() async -> WakeWordResult {
        guard !accumulator.isEmpty else {
            log.warning("checkForWakeWord called with empty accumulator")
            return .notDetected
        }

        let rawPeak = accumulator.map { abs($0) }.max() ?? 0
        let normalized = WakeWordAudioPreprocessor.peakNormalize(accumulator)
        let padded = WakeWordAudioPreprocessor.pad(
            normalized,
            toSeconds: Self.preprocessingTargetSeconds,
            sampleRate: sampleRate
        )

        let originalDuration = Double(accumulator.count) / sampleRate
        let paddedDuration = Double(padded.count) / sampleRate
        log.info("Wake-word preprocessing: \(self.accumulator.count) samples (\(String(format: "%.2f", originalDuration))s, peak=\(String(format: "%.3f", rawPeak))) → \(padded.count) samples (\(String(format: "%.2f", paddedDuration))s, padded + gain-normalized)")

        let transcribed: String
        do {
            // VAD already confirmed speech, so skip Whisper's no-speech filter
            // to avoid "No speech detected" rejections on short utterances.
            transcribed = try await transcriber.transcribe(padded, skipNoSpeechFilter: true)
            log.info("Whisper transcription: '\(transcribed)'")
        } catch {
            log.error("Transcription failed: \(error.localizedDescription)")
            return .transcriptionFailed
        }

        let result = Self.match(transcript: transcribed, keyword: keyword)
        log.info("Match result for '\(transcribed)' vs keyword '\(self.keyword)': \(String(describing: result))")
        return result
    }

    /// Target length for the padded wake-word clip. Whisper's encoder was
    /// trained on 30s clips; ~3s is the sweet spot where it's short enough
    /// to run fast and long enough that the encoder doesn't treat the clip
    /// as an outlier surrounded by silence.
    private static let preprocessingTargetSeconds: TimeInterval = 3.0

    /// Clear accumulated audio — call after a check completes or on reset.
    public func reset() {
        accumulator.removeAll(keepingCapacity: true)
    }

    // MARK: - Matching

    // Learned from production Whisper small.en misrecognitions of "Claude"
    static let knownAliases: [String: Set<String>] = [
        "claude": ["lord", "cloud", "clod", "clawed", "cod", "claw", "klod", "klaud", "plot"]
    ]

    static func match(transcript: String, keyword: String) -> WakeWordResult {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            log.debug("match: normalized text is empty")
            return .notDetected
        }

        let words = normalized.split(whereSeparator: { !$0.isLetter })
        guard !words.isEmpty else {
            log.debug("match: no letter-words found in '\(normalized)'")
            return .notDetected
        }

        let allowed = 2
        let minLength = max(1, keyword.count - 2)
        let scanWindow = min(words.count, 3)
        let aliases = knownAliases[keyword] ?? []
        let keywordPhonetic = metaphone(keyword)

        log.info("match: words=\(words.map(String.init)), scanWindow=\(scanWindow), keyword='\(keyword)' (metaphone=\(keywordPhonetic)), allowed=\(allowed), minLen=\(minLength)")

        for index in 0..<scanWindow {
            let candidate = String(words[index])
            if candidate.count < minLength {
                log.debug("  word[\(index)]='\(candidate)' — too short (len \(candidate.count) < \(minLength)), skipping")
                continue
            }

            if aliases.contains(candidate) {
                let residue = residueAfter(words, index: index)
                log.info("  word[\(index)]='\(candidate)' → alias match! residue='\(residue)'")
                return .detected(residueText: residue)
            }

            let distance = levenshtein(candidate, keyword)
            if distance <= allowed {
                let residue = residueAfter(words, index: index)
                log.info("  word[\(index)]='\(candidate)' → levenshtein=\(distance) ≤ \(allowed) — MATCH, residue='\(residue)'")
                return .detected(residueText: residue)
            }

            // Phonetic fallback: if the word *sounds* like the keyword (same
            // Metaphone code) AND starts with the same letter, accept it.
            // The first-letter guard prevents collisions where different
            // consonants map to the same Metaphone symbol (e.g. G→K means
            // "gold" and "cold" share a code, but they don't start alike).
            let candidatePhonetic = metaphone(candidate)
            if !keywordPhonetic.isEmpty,
               candidatePhonetic == keywordPhonetic,
               candidate.first == keyword.first {
                let residue = residueAfter(words, index: index)
                log.info("  word[\(index)]='\(candidate)' → metaphone=\(candidatePhonetic) matches keyword — MATCH, residue='\(residue)'")
                return .detected(residueText: residue)
            }

            log.debug("  word[\(index)]='\(candidate)' → levenshtein=\(distance), metaphone=\(candidatePhonetic) — no match")
        }

        log.info("  ❌ No match in scan window")
        return .notDetected
    }

    private static func residueAfter(_ words: [Substring], index: Int) -> String {
        words.dropFirst(index + 1).map(String.init).joined(separator: " ")
    }

    // MARK: - Metaphone (phonetic encoding)

    /// English Metaphone encoding (Lawrence Philips, 1990). Returns a
    /// short string representing how the word sounds. Words that sound
    /// alike produce the same code.
    ///
    /// Examples: "claude", "cloud", "clod", "clawed" → "KLT".
    /// Exposed for testing.
    // swiftlint:disable:next cyclomatic_complexity
    static func metaphone(_ word: String) -> String {
        let ctx = MetaphoneContext(word)
        guard !ctx.chars.isEmpty else { return "" }

        var out = ""
        var idx = ctx.skipLeadingSilent(&out)

        while idx < ctx.count {
            let ch = ctx.chars[idx]
            if ch == ctx.get(idx - 1), ch != 0x63 {
                idx += 1
                continue
            }
            ctx.emit(ch, at: idx, into: &out)
            idx += 1
        }
        return out
    }

    private struct MetaphoneContext {
        let chars: [UInt8]
        let count: Int
        private static let vowels: Set<UInt8> = [0x61, 0x65, 0x69, 0x6F, 0x75]

        init(_ word: String) {
            chars = word.unicodeScalars.compactMap { scalar -> UInt8? in
                let val = scalar.value
                if val >= 0x61 && val <= 0x7A { return UInt8(val) }
                if val >= 0x41 && val <= 0x5A { return UInt8(val + 0x20) }
                return nil
            }
            count = chars.count
        }

        func get(_ idx: Int) -> UInt8? {
            (idx >= 0 && idx < count) ? chars[idx] : nil
        }

        func isVowel(_ code: UInt8?) -> Bool {
            guard let code else { return false }
            return Self.vowels.contains(code)
        }

        func skipLeadingSilent(_ out: inout String) -> Int {
            guard count >= 2 else { return 0 }
            let c0 = chars[0], c1 = chars[1]
            let silentPairs: [(UInt8, UInt8)] = [
                (0x6B, 0x6E), (0x67, 0x6E), (0x70, 0x6E),
                (0x61, 0x65), (0x77, 0x72)
            ]
            if silentPairs.contains(where: { $0.0 == c0 && $0.1 == c1 }) { return 1 }
            if c0 == 0x78 { out.append("S"); return 1 }
            return 0
        }

        // swiftlint:disable:next cyclomatic_complexity function_body_length
        func emit(_ ch: UInt8, at idx: Int, into out: inout String) {
            let prev = get(idx - 1)
            let next = get(idx + 1)
            let nextNext = get(idx + 2)

            switch ch {
            case 0x61, 0x65, 0x69, 0x6F, 0x75:
                if idx == 0 { out.append(String(UnicodeScalar(ch - 0x20))) }
            case 0x62:
                if !(idx == count - 1 && prev == 0x6D) { out.append("B") }
            case 0x63:
                emitC(next: next, nextNext: nextNext, into: &out)
            case 0x64:
                emitD(next: next, nextNext: nextNext, into: &out)
            case 0x66:
                out.append("F")
            case 0x67:
                emitG(prev: prev, next: next, nextNext: nextNext, at: idx, into: &out)
            case 0x68:
                emitH(prev: prev, next: next, into: &out)
            case 0x6A:
                out.append("J")
            case 0x6B:
                if prev != 0x63 { out.append("K") }
            case 0x6C: out.append("L")
            case 0x6D: out.append("M")
            case 0x6E: out.append("N")
            case 0x70:
                out.append(next == 0x68 ? "F" : "P")
            case 0x71: out.append("K")
            case 0x72: out.append("R")
            case 0x73:
                emitS(next: next, nextNext: nextNext, into: &out)
            case 0x74:
                emitT(next: next, nextNext: nextNext, into: &out)
            case 0x76: out.append("F")
            case 0x77:
                if isVowel(next), !isVowel(prev) { out.append("W") }
            case 0x78: out.append("KS")
            case 0x79:
                if isVowel(next) { out.append("Y") }
            case 0x7A: out.append("S")
            default: break
            }
        }

        private func emitC(next: UInt8?, nextNext: UInt8?, into out: inout String) {
            if next == 0x69, nextNext == 0x61 { out.append("X") }
            else if next == 0x68 { out.append("X") }
            else if next == 0x69 || next == 0x65 || next == 0x79 { out.append("S") }
            else { out.append("K") }
        }

        private func emitD(next: UInt8?, nextNext: UInt8?, into out: inout String) {
            if next == 0x67, let nn = nextNext, (nn == 0x65 || nn == 0x69 || nn == 0x79) {
                out.append("J")
            } else {
                out.append("T")
            }
        }

        private func emitG(prev: UInt8?, next: UInt8?, nextNext: UInt8?,
                           at idx: Int, into out: inout String) {
            if next == 0x68 {
                if !(isVowel(prev) && idx > 0) { out.append("F") }
            } else if next == 0x6E {
                if idx != count - 2 { out.append("K") }
            } else if let nx = next, (nx == 0x65 || nx == 0x69 || nx == 0x79) {
                out.append("J")
            } else {
                out.append("K")
            }
        }

        private func emitH(prev: UInt8?, next: UInt8?, into out: inout String) {
            if isVowel(prev), !isVowel(next) { return }
            let silentAfter: Set<UInt8> = [0x63, 0x73, 0x70, 0x74, 0x67]
            if let pr = prev, silentAfter.contains(pr) { return }
            out.append("H")
        }

        private func emitS(next: UInt8?, nextNext: UInt8?, into out: inout String) {
            if next == 0x68 { out.append("X") }
            else if next == 0x69, let nn = nextNext, (nn == 0x61 || nn == 0x6F) {
                out.append("X")
            } else { out.append("S") }
        }

        private func emitT(next: UInt8?, nextNext: UInt8?, into out: inout String) {
            if next == 0x68 { out.append("0") }
            else if next == 0x69, let nn = nextNext, (nn == 0x61 || nn == 0x6F) {
                out.append("X")
            } else if next == 0x63, nextNext == 0x68 { return }
            else { out.append("T") }
        }
    }

    /// Classic Levenshtein edit distance. Exposed for testing.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        if n == 0 { return m }
        if m == 0 { return n }

        var previous = Array(0...m)
        var current = Array(repeating: 0, count: m + 1)

        for i in 1...n {
            current[0] = i
            for j in 1...m {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,       // deletion
                    current[j - 1] + 1,    // insertion
                    previous[j - 1] + cost // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[m]
    }
}
