package relay.speech.vad

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

/**
 * Pure-logic tests for the GATED [SileroVoiceActivityDetector].
 *
 * These exercise the model-free [SileroVoiceActivityDetector.buildAudioInput] tensor-shaping helper
 * and the I/O / threshold constants, all verified against `SileroVAD.mlmodelc/metadata.json` and the
 * Swift `SileroVoiceActivityDetector`. Real LSTM-threaded ONNX inference needs the converted
 * `silero_vad.onnx` (M4 / `ml/validate_parity.py`) and is NOT covered here.
 */
class SileroVoiceActivityDetectorTest {

    @Test
    fun `model input size is context plus chunk = 576`() {
        assertEquals(64, SileroVoiceActivityDetector.CONTEXT_SIZE)
        assertEquals(512, SileroVoiceActivityDetector.CHUNK_SAMPLES)
        assertEquals(576, SileroVoiceActivityDetector.MODEL_INPUT_SIZE)
    }

    @Test
    fun `lstm state size is 128`() {
        assertEquals(128, SileroVoiceActivityDetector.STATE_SIZE)
    }

    @Test
    fun `buildAudioInput lays out context then window`() {
        val context = FloatArray(SileroVoiceActivityDetector.CONTEXT_SIZE) { -1f }
        val window = FloatArray(SileroVoiceActivityDetector.CHUNK_SAMPLES) { it.toFloat() }

        val input = SileroVoiceActivityDetector.buildAudioInput(context, window)

        assertEquals(SileroVoiceActivityDetector.MODEL_INPUT_SIZE, input.size)
        // First 64 are context.
        for (i in 0 until SileroVoiceActivityDetector.CONTEXT_SIZE) {
            assertEquals(-1f, input[i], "expected context at index $i")
        }
        // Next 512 are the window, in order.
        assertEquals(0f, input[SileroVoiceActivityDetector.CONTEXT_SIZE])
        assertEquals(511f, input[SileroVoiceActivityDetector.MODEL_INPUT_SIZE - 1])
    }

    @Test
    fun `buildAudioInput rejects wrong context size`() {
        assertThrows(IllegalArgumentException::class.java) {
            SileroVoiceActivityDetector.buildAudioInput(
                FloatArray(10),
                FloatArray(SileroVoiceActivityDetector.CHUNK_SAMPLES),
            )
        }
    }

    @Test
    fun `buildAudioInput rejects wrong window size`() {
        assertThrows(IllegalArgumentException::class.java) {
            SileroVoiceActivityDetector.buildAudioInput(
                FloatArray(SileroVoiceActivityDetector.CONTEXT_SIZE),
                FloatArray(10),
            )
        }
    }

    @Test
    fun `silero threshold overrides match Swift`() {
        assertEquals(0.5f, SileroVoiceActivityDetector.SILERO_SPEECH_THRESHOLD)
        assertEquals(0.35f, SileroVoiceActivityDetector.SILERO_SILENCE_THRESHOLD)
        assertEquals(0.1, SileroVoiceActivityDetector.SILERO_CHUNK_DURATION_SECONDS)
    }

    @Test
    fun `onnx io names match the CoreML source model`() {
        assertEquals("audio_input", SileroVoiceActivityDetector.AUDIO_INPUT)
        assertEquals("hidden_state", SileroVoiceActivityDetector.HIDDEN_INPUT)
        assertEquals("cell_state", SileroVoiceActivityDetector.CELL_INPUT)
        assertEquals("vad_output", SileroVoiceActivityDetector.VAD_OUTPUT)
        assertEquals("new_hidden_state", SileroVoiceActivityDetector.NEW_HIDDEN_OUTPUT)
        assertEquals("new_cell_state", SileroVoiceActivityDetector.NEW_CELL_OUTPUT)
    }
}
