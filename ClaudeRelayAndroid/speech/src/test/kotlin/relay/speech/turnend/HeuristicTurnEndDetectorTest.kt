package relay.speech.turnend

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Mirrors `Tests/ClaudeRelaySpeechTests/TurnEndDetectorTests.swift`.
 *
 * The Swift `HeuristicTurnEndDetector` is the graceful-degradation fallback used
 * when the Smart-Turn ML model is unavailable: it ALWAYS reports "speaker done",
 * relying on the orchestrator's hard silence timeout to bound recording length.
 * The Smart-Turn ONNX detector is a later, gated task (M3-E).
 */
class HeuristicTurnEndDetectorTest {

    @Test
    fun `heuristic always returns speaker done`() = runTest {
        val detector = HeuristicTurnEndDetector()
        val audio = FloatArray(16000) { 0.2f }

        val result = detector.predict(utteranceAudio = audio)
        assertEquals(TurnEndResult.SpeakerDone(confidence = 1.0f), result)
    }

    @Test
    fun `heuristic handles short audio`() = runTest {
        val detector = HeuristicTurnEndDetector()
        val audio = FloatArray(100) { 0.1f }

        val result = detector.predict(utteranceAudio = audio)
        assertEquals(TurnEndResult.SpeakerDone(confidence = 1.0f), result)
    }

    @Test
    fun `heuristic handles empty audio`() = runTest {
        val detector = HeuristicTurnEndDetector()
        val result = detector.predict(utteranceAudio = FloatArray(0))
        assertEquals(TurnEndResult.SpeakerDone(confidence = 1.0f), result)
    }

    @Test
    fun `turn end result equatable`() {
        assertEquals(
            TurnEndResult.SpeakerDone(confidence = 0.9f),
            TurnEndResult.SpeakerDone(confidence = 0.9f),
        )
        assertNotEquals(
            TurnEndResult.SpeakerDone(confidence = 0.9f) as TurnEndResult,
            TurnEndResult.SpeakerContinuing(confidence = 0.9f) as TurnEndResult,
        )
    }

    @Test
    fun `isDone reflects the case`() {
        assertTrue(TurnEndResult.SpeakerDone(confidence = 0.5f).isDone)
        assertFalse(TurnEndResult.SpeakerContinuing(confidence = 0.5f).isDone)
    }
}
