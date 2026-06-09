package relay.speech.turnend

import kotlinx.coroutines.delay
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

/**
 * Three-way outcome from racing the turn-end classifier against a safety-net
 * timer.
 *
 * Faithful port of `ContinuousListeningEngine.TurnEndDecision` (Swift). This is
 * the **engine-facing** decision, distinct from the **detector-facing**
 * [TurnEndResult]: a [TurnEndDetecting] returns a `TurnEndResult` (done /
 * continuing with confidence); [raceTurnEnd] wraps that with a timeout safety net
 * and collapses it to this three-way decision.
 */
enum class TurnEndDecision {
    DONE,
    CONTINUING,

    /**
     * The classifier exceeded the safety-net window. Treat as "continuing" at the
     * call site — we never want to force-transcribe on timeout because that
     * re-creates the exact bug where natural pauses chop the user off.
     */
    INFERENCE_TIMED_OUT,
}

/**
 * Race the turn-end classifier against a safety-net timer that guards against a
 * hung inference. The timer **never** produces a [TurnEndDecision.DONE] verdict —
 * the classifier is authoritative. If the timer wins, the result is
 * [TurnEndDecision.INFERENCE_TIMED_OUT] and the caller resumes recording.
 *
 * Faithful port of `ContinuousListeningEngine.raceTurnEnd`.
 *
 * @param detector the turn-end classifier (heuristic fallback or Smart-Turn ML).
 * @param utterance 16 kHz mono audio; up to the last 8 s are used by the detector.
 * @param timeoutSeconds safety-net window (default
 *   `SpeechProcessingOptions.turnEndSilenceTimeout` = 8.0 s).
 */
suspend fun raceTurnEnd(
    detector: TurnEndDetecting,
    utterance: FloatArray,
    timeoutSeconds: Double,
): TurnEndDecision = coroutineScope {
    val classifier = async {
        val result = detector.predict(utteranceAudio = utterance)
        if (result.isDone) TurnEndDecision.DONE else TurnEndDecision.CONTINUING
    }
    val timer = async {
        delay((timeoutSeconds * 1000).toLong())
        TurnEndDecision.INFERENCE_TIMED_OUT
    }

    val decision = select {
        classifier.onAwait { it }
        timer.onAwait { it }
    }
    classifier.cancel()
    timer.cancel()
    decision
}
