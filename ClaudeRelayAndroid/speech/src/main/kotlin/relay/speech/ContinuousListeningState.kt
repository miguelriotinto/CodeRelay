package relay.speech

/**
 * UI color bucket for the continuous-listening pipeline. The Swift source
 * documents three buckets in prose; the Android UI needs them as a value, so
 * this enum makes the mapping explicit. `idle`/`error` map to `null` (no bucket).
 */
enum class ListeningColor { BLUE, RED, YELLOW }

/**
 * State machine for the continuous listening pipeline.
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/ContinuousListeningState.swift`.
 *
 * UX contract — strict two-phase wake word:
 *   1. The user says the wake word ("Claude"); the mic acknowledges by turning
 *      [ListeningColor.RED] ([Armed]).
 *   2. The user then speaks the command. A combined utterance like "Claude,
 *      list my files" spoken in one breath is **rejected** — the red-light
 *      handshake is the whole point. The wake-word matcher requires an empty
 *      residue after the wake word.
 *   3. [Armed] times out back to [Listening] after ~4 s if the user never
 *      starts the command.
 *
 * The UI shows three color buckets (see [color]):
 *   - Blue   — waiting for wake word ([Listening], [DetectingWakeWord])
 *   - Red    — armed / recording the command ([Armed], [Recording], [DetectingTurnEnd])
 *   - Yellow — processing the captured utterance ([Transcribing], [Cleaning], [Outputting])
 */
sealed interface ContinuousListeningState {
    data object Idle : ContinuousListeningState

    /** Mic open, waiting for speech (blue). */
    data object Listening : ContinuousListeningState

    /** Speech heard, checking if it's the wake word (blue). */
    data object DetectingWakeWord : ContinuousListeningState

    /** Wake word heard, waiting for command speech (red). */
    data object Armed : ContinuousListeningState

    /** Capturing command utterance (red). */
    data object Recording : ContinuousListeningState

    /** Checking if speaker is done (red). */
    data object DetectingTurnEnd : ContinuousListeningState

    /** Running Whisper on the full utterance (yellow). */
    data object Transcribing : ContinuousListeningState

    /** Text cleanup / prompt enhancement (yellow). */
    data object Cleaning : ContinuousListeningState

    /** Delivering to terminal (yellow). */
    data object Outputting : ContinuousListeningState

    data class Error(val message: String) : ContinuousListeningState

    /** True when the engine is doing anything (opposite of idle/error). */
    val isActive: Boolean
        get() = when (this) {
            Idle, is Error -> false
            else -> true
        }

    /** True when actively accumulating the user's command audio. */
    val isCapturing: Boolean
        get() = when (this) {
            Recording, DetectingTurnEnd -> true
            else -> false
        }

    /**
     * True when the UI should show "armed" red (wake word was heard, we're
     * listening to the user's command).
     */
    val isArmed: Boolean
        get() = when (this) {
            Armed, Recording, DetectingTurnEnd -> true
            else -> false
        }

    /** UI color bucket, or `null` for [Idle] / [Error] (no bucket). */
    val color: ListeningColor?
        get() = when (this) {
            Listening, DetectingWakeWord -> ListeningColor.BLUE
            Armed, Recording, DetectingTurnEnd -> ListeningColor.RED
            Transcribing, Cleaning, Outputting -> ListeningColor.YELLOW
            Idle, is Error -> null
        }

    val description: String
        get() = when (this) {
            Idle -> "Idle"
            Listening -> "Listening"
            DetectingWakeWord -> "Checking wake word"
            Armed -> "Ready"
            Recording -> "Recording"
            DetectingTurnEnd -> "Checking turn end"
            Transcribing -> "Transcribing"
            Cleaning -> "Cleaning"
            Outputting -> "Outputting"
            is Error -> "Error: $message"
        }
}
