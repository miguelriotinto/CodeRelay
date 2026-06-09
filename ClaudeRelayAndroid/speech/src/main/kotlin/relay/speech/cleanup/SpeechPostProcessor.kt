package relay.speech.cleanup

import relay.speech.ProcessedText
import relay.speech.SpeechProcessingOptions
import relay.speech.transcribe.WhisperTranscriber

/**
 * Unified post-processing for raw Whisper transcripts. Called by both the
 * push-to-talk and continuous-listening engines so `smartCleanupEnabled` /
 * `promptEnhancementEnabled` behave identically across modes.
 *
 * **Never throws** — failures fall back to passthrough or cleanup.
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/SpeechPostProcessor.swift`. The
 * `enhance` / `clean` operations are injected as suspend lambdas so the
 * orchestration is testable with fakes; the production wiring adapts the
 * [CloudEnhancing] / [TextCleaning] interfaces (see [invoke]).
 *
 * @param enhance `(text, bearerToken, region) -> enhanced`; may throw
 *   [EnhancerError] (notably [EnhancerError.Refused]) or any other error.
 * @param clean `(text) -> cleaned`; may throw any error.
 */
class SpeechPostProcessor(
    private val enhance: suspend (text: String, bearerToken: String, region: String) -> String,
    private val clean: suspend (text: String) -> String,
) {

    suspend fun process(rawText: String, options: SpeechProcessingOptions): ProcessedText {
        val trimmed = rawText.trim()
        if (trimmed.isEmpty()) return ProcessedText.Empty

        // Short-circuit BEFORE any enhance/clean work: a single word or a known
        // Whisper silence hallucination is never worth delivering.
        val wordCount = trimmed.split(Regex("\\s+")).filter { it.isNotEmpty() }.size
        if (wordCount < 2 || WhisperTranscriber.isSilenceHallucination(trimmed)) {
            return ProcessedText.Empty
        }

        val wantsEnhancement =
            options.promptEnhancementEnabled && options.bedrockBearerToken.isNotEmpty()

        if (wantsEnhancement) {
            return try {
                val enhanced = enhance(trimmed, options.bedrockBearerToken, options.bedrockRegion)
                ProcessedText.Enhanced(enhanced)
            } catch (refusal: EnhancerError.Refused) {
                // Refusal does NOT fall through to cleanup — deliver the original.
                ProcessedText.Refused(original = trimmed)
            } catch (e: Throwable) {
                // Any other enhancer failure falls through to cleanup/passthrough.
                if (options.smartCleanupEnabled) runCleanup(trimmed) else ProcessedText.Passthrough(trimmed)
            }
        }

        return if (options.smartCleanupEnabled) {
            runCleanup(trimmed)
        } else {
            ProcessedText.Passthrough(trimmed)
        }
    }

    private suspend fun runCleanup(text: String): ProcessedText =
        try {
            ProcessedText.Cleaned(clean(text))
        } catch (e: Throwable) {
            ProcessedText.Passthrough(text)
        }

    companion object {
        /** Production wiring: adapt the [CloudEnhancing] / [TextCleaning] interfaces. */
        operator fun invoke(
            cleaner: TextCleaning,
            enhancer: CloudEnhancing,
        ): SpeechPostProcessor = SpeechPostProcessor(
            enhance = { text, token, region -> enhancer.enhance(text, token, region) },
            clean = { text -> cleaner.clean(text) },
        )
    }
}
