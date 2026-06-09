package relay.speech

/**
 * Pipeline states for the push-to-talk [OnDeviceSpeechEngine].
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/SpeechEngineState.swift`. The UI
 * observes this to drive the mic-button color and progress indicators.
 *
 * Distinct from [ContinuousListeningState], which drives the always-on
 * wake-word pipeline; PTT is the simpler tap-to-record alternative mode.
 */
sealed interface SpeechEngineState {
    data object Idle : SpeechEngineState

    /** Whisper model loading into memory (first use after launch). */
    data object LoadingModel : SpeechEngineState

    data object Recording : SpeechEngineState

    data object Transcribing : SpeechEngineState

    /** Smart cleanup (local LLM) or prompt enhancement (cloud). */
    data object Cleaning : SpeechEngineState

    data class Error(val message: String) : SpeechEngineState

    /** True when the engine is doing anything (opposite of idle/error). */
    val isActive: Boolean
        get() = when (this) {
            Idle, is Error -> false
            else -> true
        }

    val description: String
        get() = when (this) {
            Idle -> "Idle"
            LoadingModel -> "Loading model..."
            Recording -> "Recording..."
            Transcribing -> "Transcribing..."
            Cleaning -> "Processing..."
            is Error -> "Error: $message"
        }
}
