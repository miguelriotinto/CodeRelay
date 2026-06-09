package relay.speech.transcribe

import kotlin.math.max

/**
 * Transcribes 16 kHz mono Float32 audio into text via whisper.cpp.
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/WhisperTranscriber.swift`. Only the
 * pure heuristics — [collapseRepetitions] and [isSilenceHallucination] — are
 * implemented here. The native inference path is a deferred EXECUTION NOTE (see
 * [transcribe]).
 */
object WhisperTranscriber {

    /**
     * EXECUTION NOTE — whisper.cpp JNI transcription (DEVICE/CMAKE-DEFERRED, NOT
     * implemented here).
     *
     * Port of `WhisperTranscriber.transcribe(_:skipNoSpeechFilter:)`. The Swift
     * version wraps WhisperKit (CoreML / ANE). The Android equivalent loads the
     * **same Whisper small.en weights** but in **ggml format** (`ggml-small.en.bin`,
     * the whisper.cpp binary format, NOT the WhisperKit CoreML package) and calls
     * into a whisper.cpp JNI bridge.
     *
     * Contract the deferred implementation must satisfy:
     *  - Signature: `suspend fun transcribe(audioBuffer: FloatArray, skipNoSpeechFilter: Boolean): String`.
     *  - Runs the native `whisper_full` call on `Dispatchers.Default` (off the
     *    main/UI thread) — the model is a long-lived singleton kept loaded across
     *    session switches, mirroring `WhisperTranscriber.shared`.
     *  - `skipNoSpeechFilter = true` disables whisper's no-speech threshold
     *    (`no_speech_thold`) because VAD already confirmed speech, but keeps the
     *    compression-ratio threshold active to catch decoder repetition loops.
     *  - Joins all segment texts with " ", trims whitespace, throws
     *    [TranscriberError.EmptyTranscription] if the result is blank, and finally
     *    pipes the text through [collapseRepetitions] before returning.
     *  - Throws [TranscriberError.ModelNotLoaded] when called before the model is
     *    loaded.
     *
     * NOT implemented: there is no CMake / NDK native-build toolchain in this
     * environment and no device to run on, so the whisper.cpp JNI bridge is a
     * later milestone. The pure heuristics below are the testable deliverable.
     */
    @Suppress("UnusedParameter")
    suspend fun transcribe(audioBuffer: FloatArray, skipNoSpeechFilter: Boolean): String =
        throw TranscriberError.ModelNotLoaded

    /**
     * Collapse Whisper decoder repetition loops.
     *
     * Two tiers, in order:
     *  1. [collapseSentenceRepetitions] — catches punctuation-delimited loops
     *     ("Check dir? Check dir? Check dir?").
     *  2. [collapseCharacterRepetitions] — catches unpunctuated direct
     *     concatenation ("check dircheck dircheck dir").
     *
     * Gated on `length > 20`: short transcripts are returned verbatim (a real
     * "go go go" must survive).
     */
    fun collapseRepetitions(text: String): String {
        val len = text.length
        if (len <= 20) return text

        collapseSentenceRepetitions(text)?.let { return it }
        collapseCharacterRepetitions(text)?.let { return it }

        return text
    }

    /**
     * Split on sentence-ending punctuation (`.?!`) and collapse if every segment
     * is near-identical to the first (Levenshtein <= `max(2, ref.length / 5)`).
     * Returns null when no collapse applies.
     */
    private fun collapseSentenceRepetitions(text: String): String? {
        val segments = text
            .split(Regex("[.?!]"))
            .map { it.trim() }
            .filter { it.isNotEmpty() }

        if (segments.size < 2) return null

        val reference = segments[0].lowercase()
        if (reference.length < 8) return null

        val matchCount = segments.count { seg ->
            val normalized = seg.lowercase()
            if (normalized == reference) {
                true
            } else {
                levenshteinDistance(normalized, reference) <= max(2, reference.length / 5)
            }
        }

        if (matchCount != segments.size) return null

        val lastChar = text.lastOrNull()
        val originalPunctuation = lastChar != null && lastChar in ".?!"
        val suffix = if (originalPunctuation) lastChar.toString() else ""
        return segments[0] + suffix
    }

    /**
     * Find the shortest repeating prefix unit (>= 10 chars) that reconstructs the
     * whole string, tolerating a near-identical trailing remainder
     * (Levenshtein <= `max(3, unit.length / 3)`). Returns null when no collapse
     * applies.
     */
    private fun collapseCharacterRepetitions(text: String): String? {
        val len = text.length
        val minUnit = 10
        if (len < minUnit * 2) return null

        for (unitLen in minUnit..(len / 2)) {
            val unit = text.substring(0, unitLen)
            val count = len / unitLen
            if (count < 2) continue
            val reconstructed = unit.repeat(count)
            if (!text.startsWith(reconstructed)) continue
            val remainder = text.substring(reconstructed.length)
            val trimmedRemainder = remainder.trim()
            val tolerance = max(3, unit.length / 3)
            if (trimmedRemainder.isEmpty() || levenshteinDistance(trimmedRemainder, unit) <= tolerance) {
                return unit.trim()
            }
        }

        return null
    }

    /** Classic Levenshtein edit distance (two-row DP). */
    private fun levenshteinDistance(s: String, t: String): Int {
        val sLen = s.length
        val tLen = t.length
        if (sLen == 0) return tLen
        if (tLen == 0) return sLen

        var prev = IntArray(tLen + 1) { it }
        var curr = IntArray(tLen + 1)
        for (i in 1..sLen) {
            curr[0] = i
            for (j in 1..tLen) {
                val cost = if (s[i - 1] == t[j - 1]) 0 else 1
                curr[j] = minOf(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            val tmp = prev
            prev = curr
            curr = tmp
        }
        return prev[tLen]
    }

    /**
     * Phrases Whisper commonly hallucinates from silence or background noise.
     * Compared case-insensitively after stripping punctuation. Mirrors
     * `TranscriberError.silenceHallucinations`.
     */
    val silenceHallucinations: Set<String> = setOf(
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
        "ah",
    )

    /**
     * Returns true if the text is a known Whisper silence hallucination.
     *
     * Mirrors `TranscriberError.isSilenceHallucination`: lowercase, replace every
     * run of non-letter characters with a single space, trim, then test set
     * membership.
     */
    fun isSilenceHallucination(text: String): Boolean {
        val normalized = text
            .lowercase()
            .split(Regex("[^\\p{L}]+"))
            .filter { it.isNotEmpty() }
            .joinToString(separator = " ")
        return silenceHallucinations.contains(normalized)
    }
}

/** Errors thrown by [WhisperTranscriber]. Mirrors Swift `TranscriberError`. */
sealed class TranscriberError(message: String) : Exception(message) {
    data object ModelNotLoaded : TranscriberError("Whisper model not loaded")
    data object EmptyTranscription : TranscriberError("No speech detected")
}
