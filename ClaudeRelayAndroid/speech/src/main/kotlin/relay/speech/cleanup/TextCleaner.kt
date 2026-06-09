package relay.speech.cleanup

/**
 * Protocol for local text cleanup — enables mock injection in tests and is the
 * target of [SpeechPostProcessor]'s `clean` lambda.
 *
 * Mirrors Swift `TextCleaning`.
 */
fun interface TextCleaning {
    /** Clean a transcription (filler-word removal, punctuation). May throw. */
    suspend fun clean(text: String): String
}

/**
 * EXECUTION NOTE — llama.cpp on-device text cleaner (CMAKE/DEVICE-DEFERRED, the
 * native inference is NOT implemented here).
 *
 * Port of `Sources/ClaudeRelaySpeech/TextCleaner.swift`. The Swift version runs a
 * local Qwen 3.5 0.8B GGUF model via llama.cpp (Metal GPU) to strip filler words
 * and fix punctuation — prompt enhancement stays cloud-based (see
 * [CloudPromptEnhancer]).
 *
 * Contract the deferred Android implementation must satisfy:
 *  - Model: the **same Qwen GGUF as iOS** — `qwen35-0.8b-q4km.gguf` (~0.5 GB),
 *    loaded via a llama.cpp JNI bridge (no CoreML on Android).
 *  - Context window: **512 tokens** total (system prompt ~150 + user ~100 +
 *    output ~200). Keeping it tight prevents the model rambling in `<think>`
 *    blocks.
 *  - System prompt: [SYSTEM_PROMPT] (ported verbatim from Swift).
 *  - Short-input bypass: inputs with `< minimumWordCount` (= [MINIMUM_WORD_COUNT]
 *    = 3) words are returned unchanged without invoking the model.
 *  - Timeout race: race the native completion against an **8 s** timeout; on
 *    timeout, stop the model and return the **original** text.
 *  - Hallucination guard: run [sanitizeResponse] then [looksHallucinated]; if it
 *    looks hallucinated (or is empty), return the original text.
 *  - Memory: unload the model on `onTrimMemory` / idle (the Swift side unloads
 *    after a 30 s idle timer and on memory pressure). Android should additionally
 *    unload from `ComponentCallbacks2.onTrimMemory`.
 *
 * NOT implemented: there is no CMake / NDK native-build toolchain in this
 * environment, so the llama.cpp JNI bridge is a later milestone. [clean] throws
 * [CleanerError.ModelNotLoaded] as a stub; the post-processor catches all cleaner
 * failures and falls back to passthrough, so this degrades gracefully.
 *
 * The pure helpers ([sanitizeResponse], [looksHallucinated]) ARE implemented and
 * tested so the deferred bridge can rely on them.
 */
class TextCleaner : TextCleaning {

    /** Path to the GGUF model file on disk. Set by the model store after download. */
    var modelPath: String? = null

    /** Stub: native inference is a deferred EXECUTION NOTE (no CMake/device). */
    override suspend fun clean(text: String): String {
        val wordCount = text.split(" ").filter { it.isNotEmpty() }.size
        if (wordCount < MINIMUM_WORD_COUNT) return text
        throw CleanerError.ModelNotLoaded
    }

    companion object {
        /** Minimum word count worth sending through the LLM. */
        const val MINIMUM_WORD_COUNT = 3

        /** Idle timeout (seconds) before unloading the model to free memory. */
        const val IDLE_TIMEOUT_SECONDS = 30L

        /** Wall-clock seconds before the cleanup race reverts to the original text. */
        const val CLEANUP_TIMEOUT_SECONDS = 8L

        val SYSTEM_PROMPT = """
            You are a transcription cleanup engine. Output ONLY the cleaned text. Do NOT think, reason, or explain. Do NOT use <think> tags. Remove filler words (um, uh, like, you know, so, basically). Fix punctuation and capitalization. Preserve the speaker's meaning exactly. Do NOT add or rephrase content.
        """.trimIndent()

        /** Strip any `<think>` reasoning blocks from LLM output. */
        fun sanitizeResponse(response: String): String {
            var result = response
            while (true) {
                val start = result.indexOf("<think>")
                val end = result.indexOf("</think>")
                if (start == -1 || end == -1) break
                result = result.removeRange(start until (end + "</think>".length))
            }
            return result.trim()
        }

        /** Detect likely hallucinated output from the LLM. */
        fun looksHallucinated(input: String, output: String): Boolean {
            if (output.length > input.length * 3 && output.length > 100) return true
            if (output.contains("```")) return true
            if (output.contains("<div") || output.contains("<script") || output.contains("<html")) return true
            return false
        }
    }
}

/** Errors thrown by [TextCleaner]. Mirrors Swift `CleanerError`. */
sealed class CleanerError(message: String) : Exception(message) {
    data object ModelNotLoaded : CleanerError("Cleanup model not loaded")
    data object ModelFileNotFound : CleanerError("Cleanup model file not found on disk")
}
