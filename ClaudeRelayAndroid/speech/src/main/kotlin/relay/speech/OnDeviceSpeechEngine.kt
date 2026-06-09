package relay.speech

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import relay.speech.audio.AudioCapturing
import relay.speech.cleanup.SpeechPostProcessor
import relay.speech.transcribe.SpeechTranscribing
import relay.speech.transcribe.whisperAdapter

/**
 * Push-to-talk speech orchestrator: record → transcribe → post-process → deliver.
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/OnDeviceSpeechEngine.swift`. This is
 * the simpler tap-to-record alternative to the always-on
 * [ContinuousListeningEngine]; both share [SpeechPostProcessor] so
 * `smartCleanupEnabled` / `promptEnhancementEnabled` behave identically.
 *
 * ## Testability / device-deferred capture
 * - State is exposed as a [StateFlow] (Swift `@Published var state` analog).
 * - The transcriber and post-processor (clean/enhance lambdas) are injected, so
 *   the full record → transcribe → process flow is unit-tested headlessly with
 *   fakes.
 * - The microphone [AudioCapturing] is **device-deferred** — see `AudioCaptureContract`
 *   for the Oboe/AudioRecord + resampler contract and the min/max-duration guards.
 *   Tests inject a fake that returns a pre-set buffer on `stop()`.
 *
 * **Not ported (device/platform-specific, deferred):** the iOS memory-warning
 * observer (`UIApplication.didReceiveMemoryWarning` → unload cleanup model) maps
 * to Android `ComponentCallbacks2.onTrimMemory` and is wired with the model store
 * in M3-F; the macOS mic-permission prompt has no headless analog. Model
 * loading/`prepareModels`/`preloadInBackground` belong with the device-deferred
 * native bridges and `SpeechModelStore` (M3-F), so this engine assumes the
 * injected transcriber is ready (or throws, which is treated as "no output").
 */
class OnDeviceSpeechEngine(
    private val transcriber: SpeechTranscribing,
    private val postProcessor: SpeechPostProcessor,
    private val capture: AudioCapturing,
) {

    private val _state = MutableStateFlow<SpeechEngineState>(SpeechEngineState.Idle)
    val state: StateFlow<SpeechEngineState> = _state.asStateFlow()

    // MARK: - Recording

    /** Begin capturing. No-op unless idle. Mirrors Swift `startRecording()`. */
    fun startRecording() {
        if (_state.value != SpeechEngineState.Idle) return
        try {
            capture.start()
            _state.value = SpeechEngineState.Recording
        } catch (e: Throwable) {
            _state.value = SpeechEngineState.Error(e.message ?: "Microphone unavailable")
        }
    }

    /**
     * Stop recording and process the audio via [SpeechPostProcessor]. Returns the
     * string to deliver, or `null` when the utterance should produce no output
     * (not recording, empty/short capture, transcription failure, silence
     * hallucination, refusal-to-empty). Mirrors Swift `stopAndProcess(options:)`.
     */
    suspend fun stopAndProcess(options: SpeechProcessingOptions): String? {
        if (_state.value != SpeechEngineState.Recording) return null

        val audioBuffer = capture.stop()
        if (audioBuffer == null) {
            _state.value = SpeechEngineState.Idle
            return null
        }

        _state.value = SpeechEngineState.Transcribing
        val rawText: String = try {
            transcriber.transcribe(audioBuffer, skipNoSpeechFilter = false)
        } catch (e: Throwable) {
            _state.value = SpeechEngineState.Idle
            return null
        }

        // Surface the cleaning state only when post-processing will actually run,
        // matching the Swift `willProcess` gate.
        if (options.smartCleanupEnabled || options.promptEnhancementEnabled) {
            _state.value = SpeechEngineState.Cleaning
        }

        val processed = postProcessor.process(rawText, options)
        _state.value = SpeechEngineState.Idle
        return processed.deliverableText
    }

    /** Cancel in-flight recording/processing and reset to idle. */
    fun cancel() {
        if (capture.isRecording) capture.stop()
        _state.value = SpeechEngineState.Idle
    }

    companion object {
        /**
         * Factory wiring the device-deferred whisper.cpp transcriber and the
         * shared post-processor. The microphone [AudioCapturing] is provided by the
         * caller (wired in M3-F).
         */
        fun makeDefault(
            capture: AudioCapturing,
            transcriber: SpeechTranscribing = whisperAdapter(),
            postProcessor: SpeechPostProcessor,
        ): OnDeviceSpeechEngine = OnDeviceSpeechEngine(
            transcriber = transcriber,
            postProcessor = postProcessor,
            capture = capture,
        )
    }
}
