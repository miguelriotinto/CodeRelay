package relay.speech

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import relay.speech.audio.AudioInterruptionEvent
import relay.speech.audio.StreamingAudioBuffer
import relay.speech.audio.StreamingAudioSourcing
import relay.speech.cleanup.CloudPromptEnhancer
import relay.speech.cleanup.SpeechPostProcessor
import relay.speech.cleanup.TextCleaner
import relay.speech.transcribe.SpeechTranscribing
import relay.speech.transcribe.whisperAdapter
import relay.speech.turnend.HeuristicTurnEndDetector
import relay.speech.turnend.TurnEndDecision
import relay.speech.turnend.TurnEndDetecting
import relay.speech.turnend.raceTurnEnd
import relay.speech.vad.VadEvent
import relay.speech.vad.VoiceActivityDetecting
import relay.speech.vad.VoiceActivityDetector
import relay.speech.wakeword.WakeWordAudioPreprocessor
import relay.speech.wakeword.WakeWordDetector
import relay.speech.wakeword.WakeWordResult

/**
 * Orchestrates the continuous-listening pipeline in **strict two-phase** mode.
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`.
 *
 * ```
 * Phase 1 — wake word:
 *   listening (blue) → speechStart → detectingWakeWord (blue)
 *     → silenceStart → transcribe → bare "claude"?
 *         yes → armed (red)
 *         no  → listening (blue)
 *
 * Phase 2 — command:
 *   armed (red) → speechStart → recording (red)
 *     → silenceStart → detectingTurnEnd (red) → turn-end → transcribing (yellow)
 *     → cleaning (yellow) → outputting (yellow) → listening (blue)
 * ```
 *
 * **Strict two-phase red-handshake.** After the wake word, the residue (anything
 * after the matched keyword in the same utterance) must be EMPTY. A combined
 * "Claude, list my files" spoken in one breath is rejected and snaps back to
 * `listening` — the user must pause so the red signal can confirm.
 *
 * **Classifier authoritative, timer is a safety net.** [raceTurnEnd] races the
 * turn-end classifier against [SpeechProcessingOptions.turnEndSilenceTimeout]. Only
 * a classifier `done` transcribes; a timer win ([TurnEndDecision.INFERENCE_TIMED_OUT])
 * **resumes recording** rather than forcing a chop.
 *
 * ## Testability / concurrency
 * - State is exposed as a [StateFlow]; the Swift `@Published var state` analog.
 * - All async work (wake-word check, turn-end, transcription) is launched in the
 *   injected [scope] as [pendingJob]; tests pass a `TestScope` so `runTest`
 *   virtual time drives the armed-timeout and turn-end safety-net timer, and
 *   `advanceUntilIdle()` settles pending coroutines deterministically. The Swift
 *   `@MainActor` single-thread confinement maps onto the single test dispatcher.
 * - Audio is fed via [ingest]; the production microphone capture
 *   ([StreamingAudioSourcing]) is **device-deferred** (see `AudioCaptureContract`).
 *   The injected [audioSource] is used only for start/stop accounting and
 *   interruption routing; tests use a fake and drive the state machine directly
 *   through [ingest].
 *
 * @param scope the coroutine scope used for all async work and timers. In the app
 *   this is a main-confined scope; in tests it is the `runTest` scope.
 */
class ContinuousListeningEngine(
    private val scope: CoroutineScope,
    private val vad: VoiceActivityDetecting,
    wakeWordKeyword: String,
    private val turnEndDetector: TurnEndDetecting,
    private val transcriber: SpeechTranscribing,
    private val postProcessor: SpeechPostProcessor,
    private val audioSource: StreamingAudioSourcing? = null,
    bufferCapacitySeconds: Double = 30.0,
    private val sampleRate: Double = 16_000.0,
) {

    private val _state = MutableStateFlow<ContinuousListeningState>(ContinuousListeningState.Idle)
    val state: StateFlow<ContinuousListeningState> = _state.asStateFlow()

    /** Called with the final, cleaned utterance text after each turn. */
    var onUtteranceReady: ((String) -> Unit)? = null

    private val audioBuffer = StreamingAudioBuffer(
        capacitySeconds = bufferCapacitySeconds,
        sampleRate = sampleRate,
    )

    /** Wake-word accumulator + matcher. Rebuilt when the keyword changes. */
    private var wakeWordSession = WakeWordSession(transcriber, wakeWordKeyword)

    /** Snapshot of [StreamingAudioBuffer.currentPosition] at command-speech onset. */
    private var utteranceStartPosition: Long = 0

    /** Current runtime options. Defaults so the engine works unconfigured. */
    private var currentOptions = SpeechProcessingOptions()

    /** In-flight async work (wake-word check / turn-end / transcription). */
    private var pendingJob: Job? = null
    private var armedTimer: Job? = null
    private var wakeWordTimer: Job? = null

    // MARK: - Tuning constants (ported from Swift)

    /** Pre-roll grabbed when entering detectingWakeWord — covers the VAD debounce. */
    private val wakeWordPreRollSeconds: Double = 0.5

    /** Max time in detectingWakeWord before forcing a check (in case VAD never returns to silence). */
    private val wakeWordMaxDurationMs: Long = 3_000

    /** How long the engine stays armed waiting for command speech before timing out. */
    private val armedTimeoutMs: Long = 4_000

    // MARK: - Lifecycle

    fun enable() {
        if (_state.value != ContinuousListeningState.Idle) return
        vad.reset()
        wakeWordSession.reset()
        try {
            audioSource?.let { src ->
                src.onChunk = { samples -> ingest(samples) }
                src.onInterruption = { event -> handleInterruption(event) }
                src.start()
            }
            _state.value = ContinuousListeningState.Listening
        } catch (e: Throwable) {
            _state.value = ContinuousListeningState.Error(e.message ?: "Audio source failed to start")
        }
    }

    fun disable() {
        if (_state.value == ContinuousListeningState.Idle) return
        pendingJob?.cancel()
        pendingJob = null
        cancelWakeWordTimer()
        cancelArmedTimer()
        audioSource?.stop()
        vad.reset()
        wakeWordSession.reset()
        _state.value = ContinuousListeningState.Idle
    }

    // MARK: - Options

    /**
     * Update runtime options. If [SpeechProcessingOptions.wakeWord] changed,
     * rebuilds the wake-word session. Takes effect on the next utterance.
     */
    fun updateOptions(new: SpeechProcessingOptions) {
        val wakeWordChanged = new.wakeWord != currentOptions.wakeWord
        currentOptions = new
        if (wakeWordChanged) {
            wakeWordSession = WakeWordSession(transcriber, new.wakeWord)
        }
    }

    // MARK: - Interruption handling

    private fun handleInterruption(event: AudioInterruptionEvent) {
        when (event) {
            AudioInterruptionEvent.Began -> disable()
            is AudioInterruptionEvent.Ended -> if (event.shouldResume) enable()
        }
    }

    // MARK: - Audio ingestion

    /**
     * Process one audio chunk. In production this is called from the capture tap
     * via [StreamingAudioSourcing.onChunk]; in tests it is called directly with
     * synthetic samples.
     */
    fun ingest(chunk: FloatArray) {
        if (_state.value == ContinuousListeningState.Idle) return

        audioBuffer.append(chunk)
        val event = vad.process(chunk)

        when (_state.value) {
            ContinuousListeningState.Listening -> {
                if (event == VadEvent.SpeechStart) {
                    wakeWordSession.reset()
                    // Pre-roll captures audio during the VAD debounce so the wake
                    // word itself isn't cut off.
                    val preRoll = audioBuffer.lastSeconds(wakeWordPreRollSeconds)
                    if (preRoll.isNotEmpty()) wakeWordSession.feedAudio(preRoll)
                    wakeWordSession.feedAudio(chunk)
                    _state.value = ContinuousListeningState.DetectingWakeWord
                    startWakeWordTimer()
                }
            }

            ContinuousListeningState.DetectingWakeWord -> {
                wakeWordSession.feedAudio(chunk)
                if (event == VadEvent.SilenceStart) {
                    cancelWakeWordTimer()
                    pendingJob?.cancel()
                    runWakeWordCheck()
                }
            }

            ContinuousListeningState.Armed -> {
                if (event == VadEvent.SpeechStart) {
                    cancelArmedTimer()
                    utteranceStartPosition = audioBuffer.currentPosition - chunk.size
                    _state.value = ContinuousListeningState.Recording
                }
            }

            ContinuousListeningState.Recording -> {
                if (event == VadEvent.SilenceStart) {
                    _state.value = ContinuousListeningState.DetectingTurnEnd
                    runTurnEndCheck()
                }
            }

            ContinuousListeningState.DetectingTurnEnd -> {
                if (event == VadEvent.SpeechStart) {
                    _state.value = ContinuousListeningState.Recording
                }
            }

            ContinuousListeningState.Idle,
            ContinuousListeningState.Transcribing,
            ContinuousListeningState.Cleaning,
            ContinuousListeningState.Outputting,
            is ContinuousListeningState.Error,
            -> Unit
        }
    }

    /** Await any in-flight async work. Public for tests / clean shutdown. */
    suspend fun waitForPendingWork() {
        pendingJob?.join()
    }

    // MARK: - Timers

    private fun startWakeWordTimer() {
        cancelWakeWordTimer()
        wakeWordTimer = scope.launch {
            delay(wakeWordMaxDurationMs)
            if (!isActive || _state.value != ContinuousListeningState.DetectingWakeWord) return@launch
            pendingJob?.cancel()
            runWakeWordCheck()
        }
    }

    private fun cancelWakeWordTimer() {
        wakeWordTimer?.cancel()
        wakeWordTimer = null
    }

    private fun startArmedTimer() {
        cancelArmedTimer()
        armedTimer = scope.launch {
            delay(armedTimeoutMs)
            if (!isActive || _state.value != ContinuousListeningState.Armed) return@launch
            vad.reset()
            _state.value = ContinuousListeningState.Listening
        }
    }

    private fun cancelArmedTimer() {
        armedTimer?.cancel()
        armedTimer = null
    }

    // MARK: - Pipeline steps

    private fun runWakeWordCheck() {
        pendingJob = scope.launch {
            val result = wakeWordSession.checkForWakeWord()
            if (!isActive) return@launch
            handleWakeWordResult(result)
        }
    }

    private fun handleWakeWordResult(result: WakeWordResult) {
        wakeWordSession.reset()
        when (result) {
            is WakeWordResult.Detected -> {
                val trimmedResidue = result.residueText.trim()
                if (trimmedResidue.isEmpty()) {
                    // Bare wake word — arm and wait for the command.
                    vad.reset()
                    _state.value = ContinuousListeningState.Armed
                    startArmedTimer()
                } else {
                    // Strict two-phase: reject combined phrases. The user must
                    // pause after the wake word so the red signal can confirm.
                    vad.reset()
                    _state.value = ContinuousListeningState.Listening
                }
            }
            WakeWordResult.NotDetected,
            WakeWordResult.TranscriptionFailed,
            -> {
                vad.reset()
                _state.value = ContinuousListeningState.Listening
            }
        }
    }

    private fun runTurnEndCheck() {
        val timeoutSeconds = currentOptions.turnEndSilenceTimeout
        pendingJob = scope.launch {
            val utterance = audioBuffer.audioSince(utteranceStartPosition)
            val decision = raceTurnEnd(
                detector = turnEndDetector,
                utterance = utterance,
                timeoutSeconds = timeoutSeconds,
            )
            if (!isActive) return@launch

            when (decision) {
                TurnEndDecision.DONE -> runTranscription(utterance)
                TurnEndDecision.CONTINUING -> _state.value = ContinuousListeningState.Recording
                // Classifier exceeded the safety-net window. Resume recording
                // rather than forcing a chop — the user is almost certainly still
                // speaking or pausing mid-thought. The next silenceStart fires
                // another check.
                TurnEndDecision.INFERENCE_TIMED_OUT -> _state.value = ContinuousListeningState.Recording
            }
        }
    }

    /** Runs inside the turn-end [pendingJob]; not a separately tracked job. */
    private suspend fun runTranscription(utterance: FloatArray) {
        val options = currentOptions
        _state.value = ContinuousListeningState.Transcribing
        val rawText: String = try {
            transcriber.transcribe(utterance, skipNoSpeechFilter = true)
        } catch (e: Throwable) {
            vad.reset()
            _state.value = ContinuousListeningState.Listening
            return
        }

        _state.value = ContinuousListeningState.Cleaning
        val processed = postProcessor.process(rawText, options)

        _state.value = ContinuousListeningState.Outputting
        processed.deliverableText?.let { onUtteranceReady?.invoke(it) }
        vad.reset()
        _state.value = ContinuousListeningState.Listening
    }

    /**
     * Wake-word accumulator + matcher. The Swift `WakeWordDetector` is a class
     * that owns audio accumulation (`feedAudio`), transcription (`checkForWakeWord`),
     * AND the pure matching cascade. The Kotlin [WakeWordDetector] is a pure
     * `object` (matching only), so this private session re-creates the
     * accumulate → preprocess → transcribe → match flow and delegates matching to
     * the object. The transcriber is injected for headless testing.
     */
    private class WakeWordSession(
        private val transcriber: SpeechTranscribing,
        val keyword: String,
        private val sampleRate: Double = 16_000.0,
    ) {
        private var accumulated = FloatArray(0)

        fun feedAudio(chunk: FloatArray) {
            accumulated += chunk
        }

        fun reset() {
            accumulated = FloatArray(0)
        }

        /**
         * Transcribe the accumulated wake-word audio and run the matching cascade.
         * Mirrors `WakeWordDetector.checkForWakeWord()`: peak-normalize + pad to
         * [PREPROCESSING_TARGET_SECONDS] before transcription, then delegate to
         * [WakeWordDetector.match].
         */
        suspend fun checkForWakeWord(): WakeWordResult {
            if (accumulated.isEmpty()) return WakeWordResult.NotDetected
            val normalized = WakeWordAudioPreprocessor.peakNormalize(accumulated)
            val padded = WakeWordAudioPreprocessor.pad(
                samples = normalized,
                toSeconds = PREPROCESSING_TARGET_SECONDS,
                sampleRate = sampleRate,
            )
            val transcript = try {
                transcriber.transcribe(padded, skipNoSpeechFilter = true)
            } catch (e: Throwable) {
                return WakeWordResult.TranscriptionFailed
            }
            return WakeWordDetector.match(transcript, keyword)
        }

        private companion object {
            /** Target length for the padded wake-word clip (Whisper encoder window). */
            const val PREPROCESSING_TARGET_SECONDS: Double = 3.0
        }
    }

    companion object {
        /**
         * Factory: wires the best-available **M3** detectors. For this milestone
         * that is the energy-based [VoiceActivityDetector] and the
         * [HeuristicTurnEndDetector]. The Silero VAD and Smart-Turn ONNX detectors
         * are gated to M3-E and substitute in here once their consuming code lands
         * (mirroring how the Swift `makeDefault` prefers `SileroVoiceActivityDetector`
         * / `SmartTurnTurnEndDetector` when bundled).
         *
         * The transcriber + post-processor are the device-deferred whisper.cpp /
         * llama.cpp paths via their interface adapters; the real microphone
         * [StreamingAudioSourcing] is wired in M3-F.
         */
        fun makeDefault(
            scope: CoroutineScope,
            options: SpeechProcessingOptions = SpeechProcessingOptions(),
            transcriber: SpeechTranscribing = whisperAdapter(),
            postProcessor: SpeechPostProcessor = SpeechPostProcessor(
                cleaner = TextCleaner(),
                enhancer = CloudPromptEnhancer(),
            ),
            audioSource: StreamingAudioSourcing? = null,
        ): ContinuousListeningEngine {
            val engine = ContinuousListeningEngine(
                scope = scope,
                vad = VoiceActivityDetector(),
                wakeWordKeyword = options.wakeWord,
                turnEndDetector = HeuristicTurnEndDetector(),
                transcriber = transcriber,
                postProcessor = postProcessor,
                audioSource = audioSource,
            )
            engine.updateOptions(options)
            return engine
        }
    }
}
