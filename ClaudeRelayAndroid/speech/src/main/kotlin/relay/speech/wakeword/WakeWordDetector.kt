package relay.speech.wakeword

import kotlin.math.max
import kotlin.math.min

/**
 * Result of a wake-word check.
 *
 * Mirrors Swift `WakeWordResult`. [Detected.residueText] is the text after the
 * wake word — ignored in strict two-phase mode (which requires a pause between
 * the wake word and the command), but returned for diagnostics / fallback use.
 */
sealed interface WakeWordResult {
    data class Detected(val residueText: String) : WakeWordResult
    data object NotDetected : WakeWordResult
    data object TranscriptionFailed : WakeWordResult
}

/**
 * Wake-word matching cascade — the recall-critical half of
 * `Sources/ClaudeRelaySpeech/WakeWordDetector.swift`.
 *
 * **Scope note:** the Swift `WakeWordDetector` intertwines audio accumulation
 * (`feedAudio`), Whisper transcription (`checkForWakeWord`, `SpeechTranscribing`),
 * and the pure matching logic (`match`, `levenshtein`, `metaphone`). Only the
 * pure, dependency-free matching + Levenshtein + alias table is ported here;
 * Whisper transcription and the audio accumulator are a later task (M3-C). The
 * preprocessing step that runs before transcription lives in
 * [WakeWordAudioPreprocessor].
 *
 * Match cascade (per candidate word, in the first [SCAN_WINDOW] words):
 *   1. Alias table (known Whisper mishearings of the keyword).
 *   2. Levenshtein edit distance <= [ALLOWED_DISTANCE].
 *   3. Metaphone phonetic equality with a first-letter guard.
 *
 * Words shorter than `max(1, keyword.length - 2)` are skipped (too short to be
 * a confident match).
 */
object WakeWordDetector {

    const val DEFAULT_KEYWORD: String = "claude"

    /** Levenshtein edit-distance bound for a fuzzy match. */
    const val ALLOWED_DISTANCE: Int = 2

    /** Only the first this-many words of a transcript are scanned. */
    const val SCAN_WINDOW: Int = 3

    /** Learned from production Whisper small.en misrecognitions of "Claude". */
    val knownAliases: Map<String, Set<String>> = mapOf(
        "claude" to setOf("lord", "cloud", "clod", "clawed", "cod", "claw", "klod", "klaud", "plot"),
    )

    fun match(transcript: String, keyword: String): WakeWordResult {
        val normalized = transcript.lowercase().trim()
        if (normalized.isEmpty()) return WakeWordResult.NotDetected

        // Split on non-letter runs (matches Swift's split(whereSeparator: !isLetter)).
        val words = normalized.split(Regex("[^\\p{L}]+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) return WakeWordResult.NotDetected

        val allowed = ALLOWED_DISTANCE
        val minLength = max(1, keyword.length - 2)
        val scanWindow = min(words.size, SCAN_WINDOW)
        val aliases = knownAliases[keyword] ?: emptySet()
        val keywordPhonetic = Metaphone.encode(keyword)

        for (index in 0 until scanWindow) {
            val candidate = words[index]
            if (candidate.length < minLength) continue

            if (aliases.contains(candidate)) {
                return WakeWordResult.Detected(residueAfter(words, index))
            }

            val distance = levenshtein(candidate, keyword)
            if (distance <= allowed) {
                return WakeWordResult.Detected(residueAfter(words, index))
            }

            // Phonetic fallback: if the word *sounds* like the keyword (same
            // Metaphone code) AND starts with the same letter, accept it. The
            // first-letter guard prevents collisions where different consonants
            // map to the same Metaphone symbol (e.g. G->K means "gold" and
            // "cold" share a code, but they don't start alike).
            val candidatePhonetic = Metaphone.encode(candidate)
            if (keywordPhonetic.isNotEmpty() &&
                candidatePhonetic == keywordPhonetic &&
                candidate.firstOrNull() == keyword.firstOrNull()
            ) {
                return WakeWordResult.Detected(residueAfter(words, index))
            }
        }

        return WakeWordResult.NotDetected
    }

    private fun residueAfter(words: List<String>, index: Int): String =
        words.drop(index + 1).joinToString(separator = " ")

    /** Classic Levenshtein edit distance. */
    fun levenshtein(a: String, b: String): Int {
        val aLen = a.length
        val bLen = b.length
        if (aLen == 0) return bLen
        if (bLen == 0) return aLen

        var previous = IntArray(bLen + 1) { it }
        var current = IntArray(bLen + 1)

        for (i in 1..aLen) {
            current[0] = i
            for (j in 1..bLen) {
                val cost = if (a[i - 1] == b[j - 1]) 0 else 1
                current[j] = minOf(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost,
                )
            }
            val tmp = previous
            previous = current
            current = tmp
        }
        return previous[bLen]
    }
}
