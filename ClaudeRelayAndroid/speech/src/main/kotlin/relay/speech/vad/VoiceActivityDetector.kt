package relay.speech.vad

import kotlin.math.max
import kotlin.math.sqrt

/**
 * Energy-based voice activity detector with hysteresis and debouncing.
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/VoiceActivityDetector.swift`.
 *
 * Baseline implementation using RMS energy as the speech/silence signal —
 * simple and dependency-free. A CoreML/ONNX-backed detector can substitute its
 * probability output for the energy score while reusing the same state machine.
 *
 * Processes 30 ms chunks (480 samples at 16 kHz).
 */
class VoiceActivityDetector(
    val config: Config = Config(),
) : VoiceActivityDetecting {

    data class Config(
        /** RMS energy above this = speech. */
        val speechThreshold: Float = 0.015f,
        /** RMS energy below this = silence. Between thresholds = hysteresis hold. */
        val silenceThreshold: Float = 0.008f,
        /** Chunk duration — fixed to 30 ms at 16 kHz. */
        val chunkDurationSeconds: Double = 0.030,
        /** Minimum sustained speech before emitting speechStart. */
        val minSpeechDuration: Double = 0.25,
        /**
         * Minimum sustained silence before emitting silenceStart.
         * 1.0s filters breath pauses (400-800ms) — turn-end classifier decides
         * actual completion.
         */
        val minSilenceDuration: Double = 1.0,
    )

    private enum class InternalState { SILENT, SPEAKING }

    private var state: InternalState = InternalState.SILENT
    private var pendingSpeechChunks: Int = 0
    private var pendingSilenceChunks: Int = 0

    override fun process(chunk: FloatArray): VadEvent {
        val energy = rms(chunk)
        val signalIsSpeech = scoreToBool(
            energy = energy,
            state = state,
            speechThreshold = config.speechThreshold,
            silenceThreshold = config.silenceThreshold,
        )
        return transition(signalIsSpeech)
    }

    override fun reset() {
        state = InternalState.SILENT
        pendingSpeechChunks = 0
        pendingSilenceChunks = 0
    }

    private fun transition(signalIsSpeech: Boolean): VadEvent {
        val minSpeechChunks = chunks(config.minSpeechDuration)
        val minSilenceChunks = chunks(config.minSilenceDuration)

        return when (state) {
            InternalState.SILENT ->
                if (signalIsSpeech) {
                    pendingSpeechChunks += 1
                    if (pendingSpeechChunks >= minSpeechChunks) {
                        state = InternalState.SPEAKING
                        pendingSpeechChunks = 0
                        pendingSilenceChunks = 0
                        VadEvent.SpeechStart
                    } else {
                        VadEvent.SilenceContinue // still silent (debouncing)
                    }
                } else {
                    pendingSpeechChunks = 0
                    VadEvent.SilenceContinue
                }

            InternalState.SPEAKING ->
                if (signalIsSpeech) {
                    pendingSilenceChunks = 0
                    VadEvent.SpeechContinue
                } else {
                    pendingSilenceChunks += 1
                    if (pendingSilenceChunks >= minSilenceChunks) {
                        state = InternalState.SILENT
                        pendingSilenceChunks = 0
                        pendingSpeechChunks = 0
                        VadEvent.SilenceStart
                    } else {
                        VadEvent.SpeechContinue // still speaking (debouncing)
                    }
                }
        }
    }

    private fun chunks(duration: Double): Int = max(1, (duration / config.chunkDurationSeconds).toInt())

    private companion object {

        /** Root-mean-square of a chunk. Allocation-free. */
        fun rms(chunk: FloatArray): Float {
            if (chunk.isEmpty()) return 0f
            var sumSquares = 0f
            for (sample in chunk) {
                sumSquares += sample * sample
            }
            return sqrt(sumSquares / chunk.size)
        }

        /** Hysteresis-aware speech/silence decision. */
        fun scoreToBool(
            energy: Float,
            state: InternalState,
            speechThreshold: Float,
            silenceThreshold: Float,
        ): Boolean = when (state) {
            InternalState.SILENT -> energy >= speechThreshold
            InternalState.SPEAKING -> energy >= silenceThreshold
        }
    }
}
