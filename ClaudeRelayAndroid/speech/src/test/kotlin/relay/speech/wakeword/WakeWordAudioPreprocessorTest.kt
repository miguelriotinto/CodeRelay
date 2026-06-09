package relay.speech.wakeword

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import kotlin.math.abs

/**
 * Mirrors `Tests/ClaudeRelaySpeechTests/WakeWordAudioPreprocessorTests.swift`.
 */
class WakeWordAudioPreprocessorTest {

    private fun FloatArray.peak(): Float = fold(0f) { acc, v -> maxOf(acc, abs(v)) }

    // MARK: - Peak normalization

    @Test
    fun `peakNormalize boosts quiet audio to ~0_95`() {
        val quiet = floatArrayOf(0.0f, 0.05f, -0.04f, 0.02f, -0.01f)
        val result = WakeWordAudioPreprocessor.peakNormalize(quiet)
        assertEquals(0.95f, result.peak(), 0.001f, "Peak should be scaled to ~0.95")
    }

    @Test
    fun `peakNormalize preserves relative shape`() {
        val samples = floatArrayOf(0.1f, -0.05f, 0.02f, -0.1f)
        val result = WakeWordAudioPreprocessor.peakNormalize(samples)
        // Scale factor is 0.95 / 0.1 = 9.5
        assertEquals(0.95f, result[0], 0.001f)
        assertEquals(-0.475f, result[1], 0.001f)
        assertEquals(0.19f, result[2], 0.001f)
        assertEquals(-0.95f, result[3], 0.001f)
    }

    @Test
    fun `peakNormalize leaves loud audio alone`() {
        val loud = floatArrayOf(0.95f, -0.93f, 0.90f)
        val result = WakeWordAudioPreprocessor.peakNormalize(loud)
        assertEquals(0.95f, result.peak(), 0.001f)
        assertEquals(0.95f, result[0], 0.001f)
    }

    @Test
    fun `peakNormalize ignores silence`() {
        val silent = FloatArray(100) { 0f }
        val result = WakeWordAudioPreprocessor.peakNormalize(silent)
        assertArrayEquals(silent, result)
    }

    @Test
    fun `peakNormalize ignores below noise floor`() {
        // Peak 0.0008 <= noiseFloor 0.001 → unchanged.
        val noise = floatArrayOf(0.0005f, -0.0003f, 0.0008f, -0.0002f)
        val result = WakeWordAudioPreprocessor.peakNormalize(noise)
        assertArrayEquals(noise, result)
    }

    @Test
    fun `peakNormalize handles empty buffer`() {
        assertArrayEquals(FloatArray(0), WakeWordAudioPreprocessor.peakNormalize(FloatArray(0)))
    }

    // MARK: - Padding

    @Test
    fun `pad adds trailing silence to exactly 48000 samples`() {
        val samples = FloatArray(16000) { 0.1f } // 1s @ 16kHz
        val padded = WakeWordAudioPreprocessor.pad(samples, toSeconds = 3.0, sampleRate = 16000.0)

        assertEquals(48000, padded.size, "Should be padded to 3s = 48000 samples")
        assertEquals(0.1f, padded[0])
        assertEquals(0.1f, padded[15999])
        assertEquals(0.0f, padded[16000])
        assertEquals(0.0f, padded[47999])
    }

    @Test
    fun `pad leaves audio already at length alone`() {
        val samples = FloatArray(48000) { 0.1f } // 3s
        val padded = WakeWordAudioPreprocessor.pad(samples, toSeconds = 3.0, sampleRate = 16000.0)
        assertEquals(48000, padded.size)
        assertArrayEquals(samples, padded)
    }

    @Test
    fun `pad never truncates longer audio`() {
        val samples = FloatArray(64000) { 0.1f } // 4s
        val padded = WakeWordAudioPreprocessor.pad(samples, toSeconds = 3.0, sampleRate = 16000.0)
        assertEquals(64000, padded.size, "Padding shouldn't truncate")
        assertArrayEquals(samples, padded)
    }

    @Test
    fun `pad handles empty buffer`() {
        val padded = WakeWordAudioPreprocessor.pad(FloatArray(0), toSeconds = 1.0, sampleRate = 16000.0)
        assertEquals(16000, padded.size)
        assertTrue(padded.all { it == 0f })
    }
}
