package relay.speech.turnend

/**
 * Result of predicting whether a speaker is finished with their turn.
 *
 * Faithful port of Swift `TurnEndResult` (`Sources/ClaudeRelaySpeech/TurnEndDetector.swift`).
 */
sealed interface TurnEndResult {
    data class SpeakerDone(val confidence: Float) : TurnEndResult
    data class SpeakerContinuing(val confidence: Float) : TurnEndResult

    val isDone: Boolean
        get() = this is SpeakerDone
}

/**
 * Protocol for turn-end detection — enables swapping the heuristic fallback for
 * the Smart-Turn ONNX model (a later, gated M3-E task).
 *
 * Mirrors Swift `TurnEndDetecting`.
 */
fun interface TurnEndDetecting {
    /**
     * Predict whether the speaker has finished their turn.
     * The audio should be 16 kHz mono; up to the last 8 seconds are used.
     */
    suspend fun predict(utteranceAudio: FloatArray): TurnEndResult
}

/**
 * Fallback turn-end detector that always signals "speaker done".
 *
 * Used when the Smart-Turn ML model is not bundled or fails to load. The
 * orchestrator's hard silence timeout (`SpeechProcessingOptions.turnEndSilenceTimeout`,
 * default 8.0 s) still bounds recording length, so this degrades gracefully to
 * "stop after N seconds of silence".
 *
 * Faithful port of Swift `HeuristicTurnEndDetector`.
 */
class HeuristicTurnEndDetector : TurnEndDetecting {
    override suspend fun predict(utteranceAudio: FloatArray): TurnEndResult =
        TurnEndResult.SpeakerDone(confidence = 1.0f)
}
