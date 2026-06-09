package relay.speech

/**
 * All runtime-configurable options that control how a transcript is processed
 * and how the continuous pipeline behaves. Pushed from the UI into both engines;
 * captured at the moment work kicks off so mid-session setting changes take
 * effect on the next utterance.
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/SpeechProcessingOptions.swift`.
 *
 * @property turnEndSilenceTimeout Safety net: the maximum wall-clock time (in
 *   **seconds**) the turn-end classifier is allowed to run before the engine
 *   assumes it has hung and resumes recording. This is NOT a "force done" timer
 *   — when it fires the engine returns to recording and waits for the next real
 *   silence. Defaults to 8.0 s. Not user-tunable.
 */
data class SpeechProcessingOptions(
    val smartCleanupEnabled: Boolean = true,
    val promptEnhancementEnabled: Boolean = false,
    val bedrockBearerToken: String = "",
    val bedrockRegion: String = "us-east-1",
    val wakeWord: String = "claude",
    val turnEndSilenceTimeout: Double = 8.0,
)
