package relay.speech.vad

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Mirrors `Tests/ClaudeRelaySpeechTests/VoiceActivityDetectorTests.swift` and
 * `VADEventTests.swift`.
 */
class VoiceActivityDetectorTest {

    // 30 ms chunk at 16 kHz = 480 samples.
    private val chunkSize = 480

    private fun silenceChunk() = FloatArray(chunkSize) { 0f }

    private fun speechChunk(amplitude: Float = 0.3f) = FloatArray(chunkSize) { amplitude }

    // MARK: - VadEvent helpers

    @Test
    fun `isSpeech is true for speech events`() {
        assertTrue(VadEvent.SpeechStart.isSpeech)
        assertTrue(VadEvent.SpeechContinue.isSpeech)
    }

    @Test
    fun `isSpeech is false for silence events`() {
        assertFalse(VadEvent.SilenceStart.isSpeech)
        assertFalse(VadEvent.SilenceContinue.isSpeech)
    }

    @Test
    fun `isEdge is true for start events`() {
        assertTrue(VadEvent.SpeechStart.isEdge)
        assertTrue(VadEvent.SilenceStart.isEdge)
    }

    @Test
    fun `isEdge is false for continue events`() {
        assertFalse(VadEvent.SpeechContinue.isEdge)
        assertFalse(VadEvent.SilenceContinue.isEdge)
    }

    @Test
    fun `there are exactly four VadEvent cases`() {
        assertEquals(4, VadEvent.entries.size)
    }

    // MARK: - Detector state machine

    @Test
    fun `initial silence emits silence events`() {
        val vad = VoiceActivityDetector()
        val event = vad.process(silenceChunk())
        assertFalse(event.isSpeech)
    }

    @Test
    fun `speech chunk after silence emits speechStart`() {
        val vad = VoiceActivityDetector()
        // Prime with silence first.
        repeat(5) { vad.process(silenceChunk()) }

        var sawSpeechStart = false
        repeat(15) {
            val event = vad.process(speechChunk())
            if (event == VadEvent.SpeechStart) {
                sawSpeechStart = true
                return@repeat
            }
        }
        assertTrue(sawSpeechStart, "Expected a speechStart event after sustained speech")
    }

    @Test
    fun `speechStart is followed by speechContinue`() {
        val vad = VoiceActivityDetector()
        // Drive to speaking state.
        var sawStart = false
        repeat(15) {
            if (vad.process(speechChunk()) == VadEvent.SpeechStart) sawStart = true
        }
        assertTrue(sawStart)
        // Subsequent loud chunks are speechContinue.
        assertEquals(VadEvent.SpeechContinue, vad.process(speechChunk()))
    }

    @Test
    fun `silence after speech emits silenceStart`() {
        val vad = VoiceActivityDetector()
        repeat(15) { vad.process(speechChunk()) }
        // minSilenceDuration is 1.0s; each chunk is 30ms, so we need 34+ silent
        // chunks before silenceStart can fire. Loop well past that.
        var sawSilenceStart = false
        repeat(60) {
            val event = vad.process(silenceChunk())
            if (event == VadEvent.SilenceStart) {
                sawSilenceStart = true
                return@repeat
            }
        }
        assertTrue(sawSilenceStart, "Expected a silenceStart event after sustained silence")
    }

    @Test
    fun `silenceStart is followed by silenceContinue`() {
        val vad = VoiceActivityDetector()
        repeat(15) { vad.process(speechChunk()) }
        var sawStart = false
        repeat(60) {
            if (vad.process(silenceChunk()) == VadEvent.SilenceStart) sawStart = true
        }
        assertTrue(sawStart)
        assertEquals(VadEvent.SilenceContinue, vad.process(silenceChunk()))
    }

    @Test
    fun `brief speech spike is debounced and does not trip speechStart`() {
        val vad = VoiceActivityDetector()
        repeat(5) { vad.process(silenceChunk()) }
        // One single speech chunk — below minSpeechDuration, should NOT trip speechStart.
        val event = vad.process(speechChunk())
        assertNotEquals(VadEvent.SpeechStart, event)
    }

    @Test
    fun `transient single-chunk dip while speaking does not flip to silence`() {
        val vad = VoiceActivityDetector()
        // Drive to speaking.
        repeat(15) { vad.process(speechChunk()) }
        // One quiet chunk — far below minSilenceDuration (needs ~34 chunks).
        val dip = vad.process(silenceChunk())
        assertNotEquals(VadEvent.SilenceStart, dip)
        assertEquals(VadEvent.SpeechContinue, dip)
        // Resuming speech immediately stays in speech.
        assertEquals(VadEvent.SpeechContinue, vad.process(speechChunk()))
    }

    @Test
    fun `reset clears state`() {
        val vad = VoiceActivityDetector()
        repeat(15) { vad.process(speechChunk()) }
        vad.reset()
        // After reset, first silence chunk should emit a non-speech, non-edge event.
        val event = vad.process(silenceChunk())
        assertFalse(event.isSpeech)
        assertFalse(event.isEdge)
    }

    @Test
    fun `hysteresis holds speech between thresholds`() {
        val vad = VoiceActivityDetector()
        repeat(15) { vad.process(speechChunk()) }
        // Energy between silenceThreshold (0.008) and speechThreshold (0.015):
        // amplitude 0.01 → RMS 0.01, which is >= silenceThreshold so stays speaking.
        assertEquals(VadEvent.SpeechContinue, vad.process(speechChunk(amplitude = 0.01f)))
    }
}
