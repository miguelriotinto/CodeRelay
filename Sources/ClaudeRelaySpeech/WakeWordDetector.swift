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
    static func metaphone(_ word: String) -> String {
        // Normalize to ASCII lowercase letters only.
        let chars: [UInt8] = word.unicodeScalars.compactMap { scalar -> UInt8? in
            let v = scalar.value
            if v >= 0x61 && v <= 0x7A { return UInt8(v) }            // lowercase
            if v >= 0x41 && v <= 0x5A { return UInt8(v + 0x20) }     // uppercase → lower
            return nil
        }
        guard !chars.isEmpty else { return "" }

        let count = chars.count
        let a: UInt8 = 0x61, e: UInt8 = 0x65, i_: UInt8 = 0x69
        let o: UInt8 = 0x6F, u: UInt8 = 0x75, y: UInt8 = 0x79

        func get(_ idx: Int) -> UInt8? {
            (idx >= 0 && idx < count) ? chars[idx] : nil
        }
        func isVowel(_ code: UInt8?) -> Bool {
            guard let code else { return false }
            return code == a || code == e || code == i_ || code == o || code == u
        }

        var out = ""
        var idx = 0

        // Leading-silent-letter rules.
        if count >= 2 {
            let c0 = chars[0], c1 = chars[1]
            let knStart = (c0 == 0x6B && c1 == 0x6E)  // kn
            let gnStart = (c0 == 0x67 && c1 == 0x6E)  // gn
            let pnStart = (c0 == 0x70 && c1 == 0x6E)  // pn
            let aeStart = (c0 == 0x61 && c1 == 0x65)  // ae
            let wrStart = (c0 == 0x77 && c1 == 0x72)  // wr
            if knStart || gnStart || pnStart || aeStart || wrStart { idx = 1 }
            if c0 == 0x78 { out.append("S"); idx = 1 }                // x at start → S
        }

        while idx < count {
            let c = chars[idx]
            let prev = get(idx - 1)
            let next = get(idx + 1)
            let nextNext = get(idx + 2)

            // Skip duplicate consecutive letters (except 'c').
            if c == prev, c != 0x63 {
                idx += 1
                continue
            }

            switch c {
            case a, e, i_, o, u:
                if idx == 0 {
                    out.append(String(UnicodeScalar(c - 0x20)))  // uppercase vowel
                }

            case 0x62:  // b
                // Silent 'b' at end after 'm' (e.g. "dumb").
                if !(idx == count - 1 && prev == 0x6D) { out.append("B") }

            case 0x63:  // c
                if next == i_, nextNext == a {
                    out.append("X")                                    // "cia"
                } else if next == 0x68 {
                    out.append("X")                                    // "ch"
                } else if next == i_ || next == e || next == y {
                    out.append("S")                                    // soft c
                } else {
                    out.append("K")
                }

            case 0x64:  // d
                if next == 0x67, let nn = nextNext, (nn == e || nn == i_ || nn == y) {
                    out.append("J")                                    // "dge/dgi/dgy"
                } else {
                    out.append("T")
                }

            case 0x66: out.append("F")

            case 0x67:  // g
                if next == 0x68 {
                    if isVowel(prev), idx > 0 { /* silent gh */ }
                    else { out.append("F") }
                } else if next == 0x6E {
                    if idx == count - 2 { /* silent gn at end */ }
                    else { out.append("K") }
                } else if let n = next, (n == e || n == i_ || n == y) {
                    out.append("J")                                    // soft g
                } else {
                    out.append("K")
                }

            case 0x68:  // h
                if isVowel(prev), !isVowel(next) { /* silent */ }
                else if let p = prev, (p == 0x63 || p == 0x73 || p == 0x70 || p == 0x74 || p == 0x67) {
                    /* silent — already consumed */
                } else {
                    out.append("H")
                }

            case 0x6A: out.append("J")

            case 0x6B:  // k
                if prev != 0x63 { out.append("K") }                    // not after 'c'

            case 0x6C: out.append("L")
            case 0x6D: out.append("M")
            case 0x6E: out.append("N")

            case 0x70:  // p
                if next == 0x68 { out.append("F") }                    // "ph"
                else { out.append("P") }

            case 0x71: out.append("K")
            case 0x72: out.append("R")

            case 0x73:  // s
                if next == 0x68 { out.append("X") }
                else if next == i_, let nn = nextNext, (nn == a || nn == o) {
                    out.append("X")
                } else {
                    out.append("S")
                }

            case 0x74:  // t
                if next == 0x68 { out.append("0") }                    // "th"
                else if next == i_, let nn = nextNext, (nn == a || nn == o) {
                    out.append("X")
                } else if next == 0x63, nextNext == 0x68 { /* silent "tch" */ }
                else { out.append("T") }

            case 0x76: out.append("F")                                 // v

            case 0x77:  // w
                // 'w' before a vowel makes a sound ("water"); after a vowel
                // it's silent/diphthong ("saw", "clawed") — emit nothing.
                if isVowel(next), !isVowel(prev) { out.append("W") }

            case 0x78: out.append("KS")                                // x

            case 0x79:  // y
                if isVowel(next) { out.append("Y") }                   // only before vowel

            case 0x7A: out.append("S")                                 // z

            default: break
            }

            idx += 1
        }

        return out
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
