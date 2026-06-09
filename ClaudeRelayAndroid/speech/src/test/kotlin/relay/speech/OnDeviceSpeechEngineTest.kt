package relay.speech

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import relay.speech.audio.AudioCapturing
import relay.speech.cleanup.SpeechPostProcessor
import relay.speech.transcribe.SpeechTranscribing
import relay.speech.transcribe.TranscriberError

/**
 * Mirrors `Tests/ClaudeRelaySpeechTests` coverage for `OnDeviceSpeechEngine`
 * (push-to-talk). The transcriber, post-processor (clean/enhance lambdas), and
 * audio capture are injected fakes; the real mic capture is device-deferred
 * (see `AudioCaptureContract`). No virtual-time timers are needed — the PTT flow
 * is a straight record → stop → transcribe → post-process pipeline.
 */
class OnDeviceSpeechEngineTest {

    private class StubTranscriber : SpeechTranscribing {
        var result: String = ""
        var shouldThrow: Boolean = false
        var callCount = 0
        override suspend fun transcribe(audioBuffer: FloatArray, skipNoSpeechFilter: Boolean): String {
            callCount++
            if (shouldThrow) throw TranscriberError.EmptyTranscription
            return result
        }
    }

    private class StubCleaner {
        var result: String? = null
        suspend fun clean(text: String): String = result ?: text
    }

    private class MockEnhancer {
        var resultToReturn: String = "enhanced text"
        var callCount = 0
        suspend fun enhance(text: String, bearerToken: String, region: String): String {
            callCount++
            return resultToReturn
        }
    }

    /** Fake mic: hands back a pre-set buffer on stop (real capture is device-deferred). */
    private class FakeCapture : AudioCapturing {
        var bufferToReturn: FloatArray? = FloatArray(16_000) { 0.1f }
        override var isRecording: Boolean = false
        var startCallCount = 0
        var stopCallCount = 0
        override fun start() {
            startCallCount++
            isRecording = true
        }
        override fun stop(): FloatArray? {
            stopCallCount++
            isRecording = false
            return bufferToReturn
        }
    }

    private fun makeEngine(
        transcriber: StubTranscriber = StubTranscriber(),
        cleaner: StubCleaner = StubCleaner(),
        enhancer: MockEnhancer = MockEnhancer(),
        capture: FakeCapture = FakeCapture(),
    ): OnDeviceSpeechEngine = OnDeviceSpeechEngine(
        transcriber = transcriber,
        postProcessor = SpeechPostProcessor(
            enhance = { t, token, region -> enhancer.enhance(t, token, region) },
            clean = { t -> cleaner.clean(t) },
        ),
        capture = capture,
    )

    @Test
    fun `initial state is idle`() = runTest {
        assertEquals(SpeechEngineState.Idle, makeEngine().state.value)
    }

    @Test
    fun `start recording transitions to recording`() = runTest {
        val capture = FakeCapture()
        val engine = makeEngine(capture = capture)
        engine.startRecording()
        assertEquals(SpeechEngineState.Recording, engine.state.value)
        assertEquals(1, capture.startCallCount)
    }

    @Test
    fun `start recording twice is no-op`() = runTest {
        val capture = FakeCapture()
        val engine = makeEngine(capture = capture)
        engine.startRecording()
        engine.startRecording()
        assertEquals(1, capture.startCallCount)
    }

    @Test
    fun `start feed stop delivers utterance`() = runTest {
        val transcriber = StubTranscriber().apply { result = "list my files" }
        val cleaner = StubCleaner().apply { result = "List my files" }
        val engine = makeEngine(transcriber = transcriber, cleaner = cleaner)

        engine.startRecording()
        val delivered = engine.stopAndProcess(SpeechProcessingOptions())

        assertEquals("List my files", delivered)
        assertEquals(SpeechEngineState.Idle, engine.state.value)
        assertEquals(1, transcriber.callCount)
    }

    @Test
    fun `stop when not recording returns null`() = runTest {
        val engine = makeEngine()
        val delivered = engine.stopAndProcess(SpeechProcessingOptions())
        assertNull(delivered)
        assertEquals(SpeechEngineState.Idle, engine.state.value)
    }

    @Test
    fun `nil capture buffer returns null and resets to idle`() = runTest {
        val capture = FakeCapture().apply { bufferToReturn = null }
        val engine = makeEngine(capture = capture)
        engine.startRecording()
        val delivered = engine.stopAndProcess(SpeechProcessingOptions())
        assertNull(delivered)
        assertEquals(SpeechEngineState.Idle, engine.state.value)
    }

    @Test
    fun `transcription failure returns null`() = runTest {
        val transcriber = StubTranscriber().apply { shouldThrow = true }
        val engine = makeEngine(transcriber = transcriber)
        engine.startRecording()
        val delivered = engine.stopAndProcess(SpeechProcessingOptions())
        assertNull(delivered)
        assertEquals(SpeechEngineState.Idle, engine.state.value)
    }

    @Test
    fun `empty post-process result returns null`() = runTest {
        // Known silence hallucination → ProcessedText.Empty → null deliverable.
        val transcriber = StubTranscriber().apply { result = "Thank you" }
        val engine = makeEngine(transcriber = transcriber)
        engine.startRecording()
        val delivered = engine.stopAndProcess(SpeechProcessingOptions())
        assertNull(delivered)
        assertEquals(SpeechEngineState.Idle, engine.state.value)
    }

    @Test
    fun `passthrough when cleanup disabled`() = runTest {
        val transcriber = StubTranscriber().apply { result = "hello world" }
        val engine = makeEngine(transcriber = transcriber)
        engine.startRecording()
        val delivered = engine.stopAndProcess(SpeechProcessingOptions(smartCleanupEnabled = false))
        assertEquals("hello world", delivered)
    }

    @Test
    fun `cloud enhancement path delivers enhanced text`() = runTest {
        val transcriber = StubTranscriber().apply { result = "list my files" }
        val enhancer = MockEnhancer().apply { resultToReturn = "List all files in the directory" }
        val engine = makeEngine(transcriber = transcriber, enhancer = enhancer)

        engine.startRecording()
        val delivered = engine.stopAndProcess(
            SpeechProcessingOptions(promptEnhancementEnabled = true, bedrockBearerToken = "token"),
        )

        assertEquals("List all files in the directory", delivered)
        assertEquals(1, enhancer.callCount)
    }

    @Test
    fun `cancel from recording stops capture and resets to idle`() = runTest {
        val capture = FakeCapture()
        val engine = makeEngine(capture = capture)
        engine.startRecording()
        engine.cancel()
        assertEquals(SpeechEngineState.Idle, engine.state.value)
        assertEquals(1, capture.stopCallCount)
    }

    @Test
    fun `cancel when idle is harmless`() = runTest {
        val capture = FakeCapture()
        val engine = makeEngine(capture = capture)
        engine.cancel()
        assertEquals(SpeechEngineState.Idle, engine.state.value)
        assertEquals(0, capture.stopCallCount)
    }
}
