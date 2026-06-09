package relay.speech.turnend

import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * Tests [raceTurnEnd] — the engine's safety-net race that wraps a
 * [TurnEndDetecting] classifier. Mirrors the
 * `ContinuousListeningEngine.raceTurnEnd` semantics: the classifier is
 * authoritative; the timer can only ever produce
 * [TurnEndDecision.INFERENCE_TIMED_OUT] (never DONE), and the caller treats that
 * as "continuing — give the user more time".
 *
 * Uses `runTest` virtual time so the silence timeout is exercised without real
 * wall-clock delay.
 */
class RaceTurnEndTest {

    private class FakeDetector(
        private val result: TurnEndResult,
        private val responseDelayMs: Long = 0,
    ) : TurnEndDetecting {
        override suspend fun predict(utteranceAudio: FloatArray): TurnEndResult {
            if (responseDelayMs > 0) delay(responseDelayMs)
            return result
        }
    }

    @Test
    fun `fast classifier 'done' wins over the timer`() = runTest {
        val decision = raceTurnEnd(
            detector = FakeDetector(TurnEndResult.SpeakerDone(confidence = 1.0f)),
            utterance = FloatArray(0),
            timeoutSeconds = 8.0,
        )
        assertEquals(TurnEndDecision.DONE, decision)
    }

    @Test
    fun `fast classifier 'continuing' wins over the timer`() = runTest {
        val decision = raceTurnEnd(
            detector = FakeDetector(TurnEndResult.SpeakerContinuing(confidence = 0.4f)),
            utterance = FloatArray(0),
            timeoutSeconds = 8.0,
        )
        assertEquals(TurnEndDecision.CONTINUING, decision)
    }

    @Test
    fun `timer wins as inferenceTimedOut when classifier hangs past the timeout`() = runTest {
        // Classifier takes 9 s; safety-net is 8 s -> timer wins.
        val decision = raceTurnEnd(
            detector = FakeDetector(
                TurnEndResult.SpeakerDone(confidence = 1.0f),
                responseDelayMs = 9_000,
            ),
            utterance = FloatArray(0),
            timeoutSeconds = 8.0,
        )
        assertEquals(TurnEndDecision.INFERENCE_TIMED_OUT, decision)
    }

    @Test
    fun `classifier just inside the timeout still wins`() = runTest {
        // 7 s classifier vs 8 s timer -> classifier wins.
        val decision = raceTurnEnd(
            detector = FakeDetector(
                TurnEndResult.SpeakerDone(confidence = 1.0f),
                responseDelayMs = 7_000,
            ),
            utterance = FloatArray(0),
            timeoutSeconds = 8.0,
        )
        assertEquals(TurnEndDecision.DONE, decision)
    }

    @Test
    fun `heuristic detector resolves to done before the timeout`() = runTest {
        // The HeuristicTurnEndDetector returns instantly -> DONE, never times out.
        val decision = raceTurnEnd(
            detector = HeuristicTurnEndDetector(),
            utterance = FloatArray(16000) { 0.1f },
            timeoutSeconds = 8.0,
        )
        assertEquals(TurnEndDecision.DONE, decision)
    }
}
