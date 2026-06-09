package relay.speech

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.speech.audio.AudioInterruptionEvent
import relay.speech.audio.StreamingAudioSourcing
import relay.speech.cleanup.SpeechPostProcessor
import relay.speech.transcribe.SpeechTranscribing
import relay.speech.transcribe.TranscriberError
import relay.speech.turnend.TurnEndDetecting
import relay.speech.turnend.TurnEndResult
import relay.speech.vad.VadEvent
import relay.speech.vad.VoiceActivityDetecting

/**
 * Mirrors `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift`.
 *
 * The engine is driven headlessly: VAD events, the transcriber, the turn-end
 * classifier, and the post-processor are all injected fakes, and audio is fed
 * directly via [ContinuousListeningEngine.ingest] (the real mic capture is
 * device-deferred — see `AudioCaptureContract`).
 *
 * **Settling model — mirrors Swift.** The engine launches its async work
 * (wake-word check / turn-end race / transcription) as a single tracked
 * `pendingJob` in the injected [runTest] scope. Tests call
 * [ContinuousListeningEngine.waitForPendingWork] (= `pendingJob.join()`) to settle
 * that work — exactly like the Swift `await engine.waitForPendingWork()`. Joining
 * auto-advances `runTest` virtual time through the turn-end classifier delay and
 * the safety-net timer, but it deliberately does NOT join the 4 s armed timer
 * (a separate job), so phase transitions don't spuriously trip the timeout. The
 * armed-timeout test advances virtual time explicitly with [advanceTimeBy].
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ContinuousListeningEngineTest {

    // MARK: - Fakes

    private class MockVad : VoiceActivityDetecting {
        var eventsToReturn: MutableList<VadEvent> = mutableListOf()
        var processedChunks = 0
        var resetCallCount = 0

        override fun process(chunk: FloatArray): VadEvent {
            processedChunks++
            return if (eventsToReturn.isEmpty()) VadEvent.SilenceContinue else eventsToReturn.removeAt(0)
        }

        override fun reset() {
            resetCallCount++
        }
    }

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

    private class MockTurnEnd(
        var resultToReturn: TurnEndResult = TurnEndResult.SpeakerDone(confidence = 1.0f),
        var delayMs: Long = 0,
    ) : TurnEndDetecting {
        var predictCallCount = 0

        override suspend fun predict(utteranceAudio: FloatArray): TurnEndResult {
            predictCallCount++
            if (delayMs > 0) delay(delayMs)
            return resultToReturn
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

    private class FakeAudioSource : StreamingAudioSourcing {
        override var onChunk: ((FloatArray) -> Unit)? = null
        override var onInterruption: ((AudioInterruptionEvent) -> Unit)? = null
        var startCallCount = 0
        var stopCallCount = 0
        override fun start() {
            startCallCount++
        }
        override fun stop() {
            stopCallCount++
        }
    }

    // MARK: - Builders

    private fun chunk(value: Float = 0.3f) = FloatArray(480) { value }

    private fun makeEngine(
        scope: CoroutineScope,
        vad: MockVad = MockVad(),
        turnEnd: TurnEndDetecting = MockTurnEnd(),
        transcriber: StubTranscriber = StubTranscriber(),
        cleaner: StubCleaner = StubCleaner(),
        enhancer: MockEnhancer = MockEnhancer(),
        audioSource: FakeAudioSource = FakeAudioSource(),
        keyword: String = "claude",
    ): ContinuousListeningEngine = ContinuousListeningEngine(
        scope = scope,
        vad = vad,
        wakeWordKeyword = keyword,
        turnEndDetector = turnEnd,
        transcriber = transcriber,
        postProcessor = SpeechPostProcessor(
            enhance = { t, token, region -> enhancer.enhance(t, token, region) },
            clean = { t -> cleaner.clean(t) },
        ),
        audioSource = audioSource,
    )

    // MARK: - Lifecycle

    @Test
    fun `initial state is idle`() = runTest {
        val engine = makeEngine(this)
        assertEquals(ContinuousListeningState.Idle, engine.state.value)
    }

    @Test
    fun `enable transitions to listening`() = runTest {
        val engine = makeEngine(this)
        engine.enable()
        assertEquals(ContinuousListeningState.Listening, engine.state.value)
    }

    @Test
    fun `disable transitions to idle`() = runTest {
        val engine = makeEngine(this)
        engine.enable()
        engine.disable()
        assertEquals(ContinuousListeningState.Idle, engine.state.value)
    }

    @Test
    fun `enable twice is no-op`() = runTest {
        val engine = makeEngine(this)
        engine.enable()
        engine.enable()
        assertEquals(ContinuousListeningState.Listening, engine.state.value)
    }

    @Test
    fun `disable from idle is no-op`() = runTest {
        val engine = makeEngine(this)
        engine.disable()
        assertEquals(ContinuousListeningState.Idle, engine.state.value)
    }

    @Test
    fun `enable starts audio source`() = runTest {
        val source = FakeAudioSource()
        val engine = makeEngine(this, audioSource = source)
        engine.enable()
        assertEquals(1, source.startCallCount)
        assertEquals(0, source.stopCallCount)
    }

    @Test
    fun `disable stops audio source`() = runTest {
        val source = FakeAudioSource()
        val engine = makeEngine(this, audioSource = source)
        engine.enable()
        engine.disable()
        assertEquals(1, source.startCallCount)
        assertEquals(1, source.stopCallCount)
    }

    @Test
    fun `makeDefault returns engine in idle`() = runTest {
        val engine = ContinuousListeningEngine.makeDefault(scope = this)
        assertEquals(ContinuousListeningState.Idle, engine.state.value)
    }

    // MARK: - Phase 1: wake word detection

    @Test
    fun `speechStart transitions to detectingWakeWord`() = runTest {
        val vad = MockVad()
        val engine = makeEngine(this, vad = vad)
        engine.enable()

        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart)
        engine.ingest(chunk())

        assertEquals(ContinuousListeningState.DetectingWakeWord, engine.state.value)
    }

    @Test
    fun `no wake word returns to listening`() = runTest {
        val vad = MockVad()
        val transcriber = StubTranscriber().apply { result = "hello there" }
        val engine = makeEngine(this, vad = vad, transcriber = transcriber)
        engine.enable()

        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        assertEquals(ContinuousListeningState.Listening, engine.state.value)
    }

    @Test
    fun `bare wake word transitions to armed`() = runTest {
        val vad = MockVad()
        val transcriber = StubTranscriber().apply { result = "claude" }
        val engine = makeEngine(this, vad = vad, transcriber = transcriber)
        engine.enable()

        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        assertEquals(ContinuousListeningState.Armed, engine.state.value)
    }

    @Test
    fun `wake word with residue rejected in strict mode`() = runTest {
        val vad = MockVad()
        // Combined phrase — strict two-phase must reject this.
        val transcriber = StubTranscriber().apply { result = "claude list my files" }
        val engine = makeEngine(this, vad = vad, transcriber = transcriber)
        engine.enable()

        var delivered: String? = null
        engine.onUtteranceReady = { delivered = it }

        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        assertEquals(
            ContinuousListeningState.Listening,
            engine.state.value,
            "Combined phrase should snap back to listening, not arm",
        )
        assertNull(delivered, "Strict mode must not deliver a combined utterance")
    }

    @Test
    fun `alias wake word also arms`() = runTest {
        // Whisper commonly mishears "Claude" as "Lord".
        val vad = MockVad()
        val transcriber = StubTranscriber().apply { result = "lord" }
        val engine = makeEngine(this, vad = vad, transcriber = transcriber)
        engine.enable()

        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        assertEquals(ContinuousListeningState.Armed, engine.state.value, "Known alias should still arm the engine")
    }

    // MARK: - Phase 2: command capture

    @Test
    fun `armed speechStart transitions to recording`() = runTest {
        val vad = MockVad()
        val transcriber = StubTranscriber().apply { result = "claude" }
        val engine = makeEngine(this, vad = vad, transcriber = transcriber)
        engine.enable()

        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()
        assertEquals(ContinuousListeningState.Armed, engine.state.value)

        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart)
        engine.ingest(chunk(0.3f))
        assertEquals(ContinuousListeningState.Recording, engine.state.value)
    }

    @Test
    fun `full pipeline delivers command text`() = runTest {
        val vad = MockVad()
        val transcriber = StubTranscriber()
        val cleaner = StubCleaner()
        val turnEnd = MockTurnEnd(resultToReturn = TurnEndResult.SpeakerDone(confidence = 0.95f))

        val engine = makeEngine(this, vad = vad, turnEnd = turnEnd, transcriber = transcriber, cleaner = cleaner)
        engine.enable()

        var delivered: String? = null
        engine.onUtteranceReady = { delivered = it }

        // Phase 1: wake word
        transcriber.result = "claude"
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()
        assertEquals(ContinuousListeningState.Armed, engine.state.value)

        // Phase 2: command
        transcriber.result = "list my files"
        cleaner.result = "List my files"
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        assertEquals("List my files", delivered)
        assertEquals(ContinuousListeningState.Listening, engine.state.value)
    }

    @Test
    fun `armed silenceContinue does not change state`() = runTest {
        val vad = MockVad()
        val transcriber = StubTranscriber().apply { result = "claude" }
        val engine = makeEngine(this, vad = vad, transcriber = transcriber)
        engine.enable()

        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()
        assertEquals(ContinuousListeningState.Armed, engine.state.value)

        vad.eventsToReturn = mutableListOf(VadEvent.SilenceContinue)
        engine.ingest(chunk(0.01f))
        assertEquals(ContinuousListeningState.Armed, engine.state.value, "silenceContinue shouldn't leave armed")
    }

    @Test
    fun `armed times out back to listening after 4s`() = runTest {
        val vad = MockVad()
        val transcriber = StubTranscriber().apply { result = "claude" }
        val engine = makeEngine(this, vad = vad, transcriber = transcriber)
        engine.enable()

        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()
        assertEquals(ContinuousListeningState.Armed, engine.state.value)

        // No command speech for 4 s → snaps back to listening.
        advanceTimeBy(4_001)
        advanceUntilIdle()
        assertEquals(ContinuousListeningState.Listening, engine.state.value)
    }

    @Test
    fun `speaker continuing keeps recording`() = runTest {
        val vad = MockVad()
        val transcriber = StubTranscriber().apply { result = "claude" }
        val turnEnd = MockTurnEnd(resultToReturn = TurnEndResult.SpeakerContinuing(confidence = 0.8f))

        val engine = makeEngine(this, vad = vad, turnEnd = turnEnd, transcriber = transcriber)
        engine.enable()

        // Phase 1: arm
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()
        assertEquals(ContinuousListeningState.Armed, engine.state.value)

        // Phase 2: start speaking, pause briefly
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        // Classifier says "continuing" → engine back in recording.
        assertEquals(ContinuousListeningState.Recording, engine.state.value)
    }

    @Test
    fun `disable cancels inflight work`() = runTest {
        val vad = MockVad()
        val transcriber = StubTranscriber().apply { result = "claude" }
        val engine = makeEngine(this, vad = vad, transcriber = transcriber)
        engine.enable()

        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.disable()

        assertEquals(ContinuousListeningState.Idle, engine.state.value)
    }

    // MARK: - Options & post-processing

    @Test
    fun `updateOptions takes effect on next utterance`() = runTest {
        val vad = MockVad()
        val transcriber = StubTranscriber()
        val cleaner = StubCleaner()
        val turnEnd = MockTurnEnd(resultToReturn = TurnEndResult.SpeakerDone(confidence = 0.9f))

        val engine = makeEngine(this, vad = vad, turnEnd = turnEnd, transcriber = transcriber, cleaner = cleaner)
        engine.enable()

        var delivered: String? = null
        engine.onUtteranceReady = { delivered = it }

        engine.updateOptions(SpeechProcessingOptions(smartCleanupEnabled = false))

        // Arm, then speak — cleanup disabled → raw passthrough.
        transcriber.result = "claude"
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        transcriber.result = "hello world"
        cleaner.result = "HELLO WORLD"
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        assertEquals("hello world", delivered)
        delivered = null

        engine.updateOptions(SpeechProcessingOptions(smartCleanupEnabled = true))

        // Round 2: arm again, speak — cleanup enabled → cleaned.
        transcriber.result = "claude"
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        transcriber.result = "hello world"
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        assertEquals("HELLO WORLD", delivered)
    }

    @Test
    fun `cloud enhancement path delivers enhanced text`() = runTest {
        val vad = MockVad()
        val transcriber = StubTranscriber()
        val enhancer = MockEnhancer().apply { resultToReturn = "List all files in the current directory" }
        val turnEnd = MockTurnEnd()

        val engine = makeEngine(this, vad = vad, turnEnd = turnEnd, transcriber = transcriber, enhancer = enhancer)
        engine.enable()

        var delivered: String? = null
        engine.onUtteranceReady = { delivered = it }

        engine.updateOptions(
            SpeechProcessingOptions(promptEnhancementEnabled = true, bedrockBearerToken = "token"),
        )

        // Arm
        transcriber.result = "claude"
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        // Command
        transcriber.result = "list my files"
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        assertEquals("List all files in the current directory", delivered)
        assertEquals(1, enhancer.callCount)
    }

    @Test
    fun `updateOptions with new wake word rebuilds detector`() = runTest {
        val vad = MockVad()
        val transcriber = StubTranscriber()
        val engine = makeEngine(this, vad = vad, transcriber = transcriber)
        engine.enable()

        engine.updateOptions(SpeechProcessingOptions(wakeWord = "hermes"))

        // Arm with the new keyword.
        transcriber.result = "hermes"
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        assertEquals(ContinuousListeningState.Armed, engine.state.value, "New wake word should arm the engine")
    }

    @Test
    fun `empty post-process result does not emit`() = runTest {
        // A silence hallucination ("Thank you") → ProcessedText.Empty → no emit.
        val vad = MockVad()
        val transcriber = StubTranscriber()
        val turnEnd = MockTurnEnd(resultToReturn = TurnEndResult.SpeakerDone(confidence = 1.0f))
        val engine = makeEngine(this, vad = vad, turnEnd = turnEnd, transcriber = transcriber)
        engine.enable()

        var delivered: String? = null
        var deliverCount = 0
        engine.onUtteranceReady = { delivered = it; deliverCount++ }

        // Arm
        transcriber.result = "claude"
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        // Command: a known hallucination → Empty.
        transcriber.result = "Thank you"
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        assertNull(delivered, "Empty post-process result must not be delivered")
        assertEquals(0, deliverCount, "onUtteranceReady must not fire for Empty")
        assertEquals(ContinuousListeningState.Listening, engine.state.value)
    }

    @Test
    fun `turn-end inference timeout resumes recording not transcribe`() = runTest {
        // When the classifier takes longer than the safety-net timeout, the
        // engine must NOT force transcription — it resumes recording.
        val vad = MockVad()
        val transcriber = StubTranscriber().apply { result = "claude" }
        // Would say "done" if it finished, but it stalls 5 s.
        val turnEnd = MockTurnEnd(resultToReturn = TurnEndResult.SpeakerDone(confidence = 0.9f), delayMs = 5_000)

        val engine = makeEngine(this, vad = vad, turnEnd = turnEnd, transcriber = transcriber)
        engine.enable()

        engine.updateOptions(SpeechProcessingOptions(turnEndSilenceTimeout = 0.1)) // 100 ms safety net wins

        var delivered: String? = null
        engine.onUtteranceReady = { delivered = it }

        // Arm
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        // Command: silence fires turn-end; classifier stalls 5 s so timer wins at 100 ms.
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        assertNull(delivered, "Timeout must NOT force transcription")
        assertEquals(
            ContinuousListeningState.Recording,
            engine.state.value,
            "After safety-net timeout, engine resumes recording",
        )
    }

    @Test
    fun `turn-end classifier is authoritative when it returns inside the window`() = runTest {
        val vad = MockVad()
        val transcriber = StubTranscriber().apply { result = "claude" }
        // 200 ms → finishes within the 1 s safety net; verdict = continuing.
        val turnEnd = MockTurnEnd(resultToReturn = TurnEndResult.SpeakerContinuing(confidence = 0.9f), delayMs = 200)

        val engine = makeEngine(this, vad = vad, turnEnd = turnEnd, transcriber = transcriber)
        engine.enable()

        engine.updateOptions(SpeechProcessingOptions(turnEndSilenceTimeout = 1.0))

        var delivered: String? = null
        engine.onUtteranceReady = { delivered = it }

        // Arm
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        // Command
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        // Classifier said "continuing" — no transcription, back to recording.
        assertNull(delivered)
        assertEquals(ContinuousListeningState.Recording, engine.state.value)
    }

    @Test
    fun `classifier done transcribes before the safety-net timer`() = runTest {
        // Classifier returns DONE instantly with a long (8 s) safety net; the
        // engine should transcribe immediately rather than wait for the timer.
        val vad = MockVad()
        val transcriber = StubTranscriber()
        val cleaner = StubCleaner()
        val turnEnd = MockTurnEnd(resultToReturn = TurnEndResult.SpeakerDone(confidence = 1.0f))

        val engine = makeEngine(this, vad = vad, turnEnd = turnEnd, transcriber = transcriber, cleaner = cleaner)
        engine.enable()

        var delivered: String? = null
        engine.onUtteranceReady = { delivered = it }

        engine.updateOptions(SpeechProcessingOptions(turnEndSilenceTimeout = 8.0))

        // Arm
        transcriber.result = "claude"
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        // Command — classifier wins instantly; joining does not wait the 8 s timer.
        transcriber.result = "build the project"
        cleaner.result = "Build the project"
        vad.eventsToReturn = mutableListOf(VadEvent.SpeechStart, VadEvent.SilenceStart)
        engine.ingest(chunk(0.3f))
        engine.ingest(chunk(0.1f))
        engine.waitForPendingWork()

        assertEquals("Build the project", delivered)
        assertEquals(ContinuousListeningState.Listening, engine.state.value)
    }

    // MARK: - Interruptions

    @Test
    fun `interruption began disables engine`() = runTest {
        val source = FakeAudioSource()
        val engine = makeEngine(this, audioSource = source)
        engine.enable()
        assertEquals(ContinuousListeningState.Listening, engine.state.value)

        source.onInterruption?.invoke(AudioInterruptionEvent.Began)
        advanceUntilIdle()

        assertEquals(ContinuousListeningState.Idle, engine.state.value)
        assertEquals(1, source.stopCallCount)
    }

    @Test
    fun `interruption ended with shouldResume re-enables`() = runTest {
        val source = FakeAudioSource()
        val engine = makeEngine(this, audioSource = source)
        engine.enable()
        source.onInterruption?.invoke(AudioInterruptionEvent.Began)
        advanceUntilIdle()

        source.onInterruption?.invoke(AudioInterruptionEvent.Ended(shouldResume = true))
        advanceUntilIdle()

        assertEquals(ContinuousListeningState.Listening, engine.state.value)
        assertEquals(2, source.startCallCount)
    }

    @Test
    fun `interruption ended without shouldResume stays idle`() = runTest {
        val source = FakeAudioSource()
        val engine = makeEngine(this, audioSource = source)
        engine.enable()
        source.onInterruption?.invoke(AudioInterruptionEvent.Began)
        advanceUntilIdle()

        source.onInterruption?.invoke(AudioInterruptionEvent.Ended(shouldResume = false))
        advanceUntilIdle()

        assertEquals(ContinuousListeningState.Idle, engine.state.value)
        assertEquals(1, source.startCallCount)
    }

    // MARK: - Color bucket sanity (UX contract)

    @Test
    fun `armed and recording are red bucket`() = runTest {
        assertEquals(ListeningColor.RED, ContinuousListeningState.Armed.color)
        assertEquals(ListeningColor.RED, ContinuousListeningState.Recording.color)
        assertTrue(ContinuousListeningState.Listening.color == ListeningColor.BLUE)
    }
}
