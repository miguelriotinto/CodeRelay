package relay.speech.turnend

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Pure-logic tests for the GATED [SmartTurnTurnEndDetector].
 *
 * These exercise the model-free helpers — [SmartTurnTurnEndDetector.padOrTruncate] and
 * [SmartTurnTurnEndDetector.thresholdToResult] — and the fail-to-done bias constant. They mirror
 * the Swift `SmartTurnTurnEndDetector.padOrTruncate` + the `predict` threshold tail.
 *
 * Real two-stage ONNX inference needs the converted `.onnx` models (M4 / `ml/validate_parity.py`)
 * and is therefore NOT covered here — that's the device-deferred / M4 part.
 */
class SmartTurnTurnEndDetectorTest {

    private val n = SmartTurnTurnEndDetector.REQUIRED_SAMPLE_COUNT // 128_000

    @Test
    fun `required sample count is 8s at 16kHz`() {
        assertEquals(128_000, SmartTurnTurnEndDetector.REQUIRED_SAMPLE_COUNT)
    }

    @Test
    fun `padOrTruncate returns same array when already exact length`() {
        val exact = FloatArray(n) { it.toFloat() }
        val out = SmartTurnTurnEndDetector.padOrTruncate(exact, n)
        assertEquals(n, out.size)
        assertArrayEquals(exact, out)
    }

    @Test
    fun `padOrTruncate zero-pads at the START for short audio (newest at end)`() {
        val short = floatArrayOf(1f, 2f, 3f)
        val out = SmartTurnTurnEndDetector.padOrTruncate(short, n)
        assertEquals(n, out.size)
        // Leading region is silence...
        for (i in 0 until n - 3) assertEquals(0f, out[i], "expected zero pad at index $i")
        // ...and the real samples sit at the END (newest at the tail).
        assertEquals(1f, out[n - 3])
        assertEquals(2f, out[n - 2])
        assertEquals(3f, out[n - 1])
    }

    @Test
    fun `padOrTruncate keeps the SUFFIX (last n samples) when too long`() {
        val long = FloatArray(n + 5) { it.toFloat() }
        val out = SmartTurnTurnEndDetector.padOrTruncate(long, n)
        assertEquals(n, out.size)
        // suffix(n): first kept sample is index 5, last is index n+4.
        assertEquals(5f, out[0])
        assertEquals((n + 4).toFloat(), out[n - 1])
    }

    @Test
    fun `threshold at or above 0_5 maps to SpeakerDone with probability as confidence`() {
        val done = SmartTurnTurnEndDetector.thresholdToResult(0.5f, 0.5f)
        assertTrue(done is TurnEndResult.SpeakerDone)
        assertEquals(0.5f, (done as TurnEndResult.SpeakerDone).confidence)

        val done2 = SmartTurnTurnEndDetector.thresholdToResult(0.9f, 0.5f)
        assertEquals(0.9f, (done2 as TurnEndResult.SpeakerDone).confidence)
    }

    @Test
    fun `threshold below 0_5 maps to SpeakerContinuing with 1 minus probability`() {
        val cont = SmartTurnTurnEndDetector.thresholdToResult(0.2f, 0.5f)
        assertTrue(cont is TurnEndResult.SpeakerContinuing)
        assertEquals(0.8f, (cont as TurnEndResult.SpeakerContinuing).confidence, 1e-6f)
    }

    @Test
    fun `fail-to-done probability is 1_0 and maps to SpeakerDone`() {
        // ANY inference error returns FAIL_TO_DONE_PROBABILITY; verify it biases to "done".
        assertEquals(1.0f, SmartTurnTurnEndDetector.FAIL_TO_DONE_PROBABILITY)
        val result = SmartTurnTurnEndDetector.thresholdToResult(
            SmartTurnTurnEndDetector.FAIL_TO_DONE_PROBABILITY,
            SmartTurnTurnEndDetector.DEFAULT_THRESHOLD,
        )
        assertTrue(result is TurnEndResult.SpeakerDone)
        assertEquals(1.0f, (result as TurnEndResult.SpeakerDone).confidence)
    }

    @Test
    fun `default threshold is 0_5`() {
        assertEquals(0.5f, SmartTurnTurnEndDetector.DEFAULT_THRESHOLD)
    }

    @Test
    fun `onnx io names match the CoreML source models`() {
        assertEquals("audio", SmartTurnTurnEndDetector.LOGMEL_INPUT)
        assertEquals("log_mel", SmartTurnTurnEndDetector.LOGMEL_OUTPUT)
        assertEquals("input_features", SmartTurnTurnEndDetector.CLASSIFIER_INPUT)
        assertEquals("probability", SmartTurnTurnEndDetector.CLASSIFIER_OUTPUT)
    }
}
