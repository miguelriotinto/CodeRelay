package relay.speech.vad

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import java.io.File
import java.nio.FloatBuffer

/**
 * ONNX-Runtime-backed voice activity detector using the Silero VAD v6 "unified" model
 * (STFT + Encoder + Decoder bundled, with a stateful LSTM).
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/SileroVoiceActivityDetector.swift`.
 *
 * The model takes a 576-sample input ([CONTEXT_SIZE] = 64 context + [CHUNK_SAMPLES] = 512 new
 * samples) plus LSTM `hidden_state` / `cell_state` [1, 128], and returns a probability plus
 * updated states. This wrapper:
 *   - Buffers variable-size tap chunks into 512-sample inference windows ([residual]).
 *   - Threads LSTM state (`hidden`/`cell`) and the 64-sample audio context across calls.
 *   - Feeds the probability into the energy [VoiceActivityDetector]'s debounce state machine,
 *     reusing its hysteresis + start/continue edge logic.
 *
 * ## ONNX graph I/O (verified against SileroVAD.mlmodelc/metadata.json)
 * - inputs:  `audio_input [1, 576]`, `hidden_state [1, 128]`, `cell_state [1, 128]`
 * - outputs: `vad_output [1, 1, 1]`, `new_hidden_state [1, 128]`, `new_cell_state [1, 128]`
 *
 * ## GATED to M4 — wire in makeDefault only after ml/validate_parity.py passes
 * This class is intentionally NOT referenced by [relay.speech.ContinuousListeningEngine.makeDefault],
 * which keeps the energy [VoiceActivityDetector]. The `silero_vad.onnx` asset is produced by
 * `ml/convert_silero.py` on a Mac in M4 and validated by `ml/validate_parity.py`. Until then
 * [tryLoad] returns null and callers fall back to the energy detector.
 *
 * ## Graceful degradation
 * [tryLoad] returns null when the asset is absent or fails to open an [OrtSession]; the caller
 * substitutes the energy [VoiceActivityDetector] (mirroring the Swift `init?` returning nil). On a
 * per-call inference error, [predict] returns the previous probability so the state machine holds.
 */
class SileroVoiceActivityDetector private constructor(
    private val env: OrtEnvironment,
    private val model: OrtSession,
    config: VoiceActivityDetector.Config,
) : VoiceActivityDetecting, AutoCloseable {

    /** Inner energy-VAD reused purely for its debounce / hysteresis state machine. */
    private val inner: VoiceActivityDetector

    /** Residual samples not yet consumed by a 512-sample inference window. */
    private var residual = FloatArray(0)

    /** Last probability produced by the model — held across calls and on inference error. */
    private var lastProbability: Float = 0f

    // LSTM state threaded across inference calls.
    private var hiddenState = FloatArray(STATE_SIZE)
    private var cellState = FloatArray(STATE_SIZE)

    /** Trailing context from the previous chunk (last 64 samples). */
    private var context = FloatArray(CONTEXT_SIZE)

    init {
        // Silero-specific threshold overrides, matching the Swift init: a probability >= 0.5 is
        // speech, < 0.35 is silence (hysteresis band between), and the audio source delivers
        // ~100 ms chunks so the debounce math uses chunkDurationSeconds = 0.1 (the 30 ms energy
        // default would inflate the 250 ms speech debounce to ~800 ms and miss the wake word).
        inner = VoiceActivityDetector(
            config.copy(
                speechThreshold = SILERO_SPEECH_THRESHOLD,
                silenceThreshold = SILERO_SILENCE_THRESHOLD,
                chunkDurationSeconds = SILERO_CHUNK_DURATION_SECONDS,
            ),
        )
    }

    override fun process(chunk: FloatArray): VadEvent {
        residual += chunk
        while (residual.size >= CHUNK_SAMPLES) {
            val window = residual.copyOfRange(0, CHUNK_SAMPLES)
            residual = residual.copyOfRange(CHUNK_SAMPLES, residual.size)
            lastProbability = predict(window)
        }

        // Feed the model probability into the energy VAD's state machine. The inner detector
        // computes RMS, so a constant-amplitude chunk of value `lastProbability` yields an RMS of
        // exactly `lastProbability` — the probability IS the energy score. Mirrors the Swift
        // `inner.process(chunk: Array(repeating: lastProbability, ...))`.
        val syntheticSize = maxOf(chunk.size, 1)
        return inner.process(FloatArray(syntheticSize) { lastProbability })
    }

    override fun reset() {
        inner.reset()
        residual = FloatArray(0)
        lastProbability = 0f
        hiddenState = FloatArray(STATE_SIZE)
        cellState = FloatArray(STATE_SIZE)
        context = FloatArray(CONTEXT_SIZE)
    }

    override fun close() {
        runCatching { model.close() }
    }

    /**
     * Run one 512-sample window through the model, threading LSTM state + context. Returns the new
     * probability, or [lastProbability] on any error (so the state machine holds rather than
     * spuriously flipping). Faithful port of the Swift `predict(window:)`.
     */
    private fun predict(window: FloatArray): Float {
        if (window.size != CHUNK_SAMPLES) return lastProbability
        return try {
            val audioInput = buildAudioInput(context, window)
            val audioTensor = OnnxTensor.createTensor(
                env, FloatBuffer.wrap(audioInput), longArrayOf(1, MODEL_INPUT_SIZE.toLong()),
            )
            val hTensor = OnnxTensor.createTensor(
                env, FloatBuffer.wrap(hiddenState), longArrayOf(1, STATE_SIZE.toLong()),
            )
            val cTensor = OnnxTensor.createTensor(
                env, FloatBuffer.wrap(cellState), longArrayOf(1, STATE_SIZE.toLong()),
            )

            var prob = lastProbability
            audioTensor.use { ai0 ->
                hTensor.use { h0 ->
                    cTensor.use { c0 ->
                        val inputs = mapOf(
                            AUDIO_INPUT to ai0,
                            HIDDEN_INPUT to h0,
                            CELL_INPUT to c0,
                        )
                        model.run(inputs).use { out ->
                            (out.get(VAD_OUTPUT).orElse(null) as? OnnxTensor)?.floatBuffer?.let { b ->
                                if (b.capacity() > 0) prob = b.get(0)
                            }
                            (out.get(NEW_HIDDEN_OUTPUT).orElse(null) as? OnnxTensor)?.floatBuffer?.let { b ->
                                hiddenState = readState(b)
                            }
                            (out.get(NEW_CELL_OUTPUT).orElse(null) as? OnnxTensor)?.floatBuffer?.let { b ->
                                cellState = readState(b)
                            }
                        }
                    }
                }
            }

            // Update context with the tail of the current window for the next call.
            context = window.copyOfRange(window.size - CONTEXT_SIZE, window.size)
            prob
        } catch (t: Throwable) {
            lastProbability
        }
    }

    private fun readState(buf: FloatBuffer): FloatArray {
        val n = minOf(STATE_SIZE, buf.capacity())
        val out = FloatArray(STATE_SIZE)
        for (i in 0 until n) out[i] = buf.get(i)
        return out
    }

    companion object {
        /** New audio samples per inference window. */
        const val CHUNK_SAMPLES = 512

        /** Context samples prepended to each chunk (tail of the previous window). */
        const val CONTEXT_SIZE = 64

        /** Total model input size: context + chunk. */
        const val MODEL_INPUT_SIZE = CONTEXT_SIZE + CHUNK_SAMPLES // 576

        /** LSTM hidden/cell state dimension. */
        const val STATE_SIZE = 128

        // Silero threshold overrides (verified against the Swift init).
        const val SILERO_SPEECH_THRESHOLD = 0.5f
        const val SILERO_SILENCE_THRESHOLD = 0.35f
        const val SILERO_CHUNK_DURATION_SECONDS = 0.1

        // ── ONNX graph I/O names (verified against SileroVAD.mlmodelc/metadata.json) ──
        const val AUDIO_INPUT = "audio_input"
        const val HIDDEN_INPUT = "hidden_state"
        const val CELL_INPUT = "cell_state"
        const val VAD_OUTPUT = "vad_output"
        const val NEW_HIDDEN_OUTPUT = "new_hidden_state"
        const val NEW_CELL_OUTPUT = "new_cell_state"

        /** Asset file name produced by `ml/convert_silero.py`. */
        const val MODEL_ASSET = "silero_vad.onnx"

        /**
         * Pure helper: build the [MODEL_INPUT_SIZE]-length `audio_input` = context (64) + window
         * (512). Faithful port of the Swift pointer copy into the [1, 576] MLMultiArray.
         * Testable without a model.
         */
        fun buildAudioInput(context: FloatArray, window: FloatArray): FloatArray {
            require(context.size == CONTEXT_SIZE) { "context must be $CONTEXT_SIZE samples" }
            require(window.size == CHUNK_SAMPLES) { "window must be $CHUNK_SAMPLES samples" }
            val out = FloatArray(MODEL_INPUT_SIZE)
            System.arraycopy(context, 0, out, 0, CONTEXT_SIZE)
            System.arraycopy(window, 0, out, CONTEXT_SIZE, CHUNK_SAMPLES)
            return out
        }

        /**
         * Attempt to load the Silero ONNX model from app assets and build a detector.
         *
         * Returns null (→ caller falls back to the energy [VoiceActivityDetector]) when the asset is
         * absent or fails to open — the **current state**, since `silero_vad.onnx` is produced by
         * the M4 conversion run. Mirrors the Swift `init?` returning nil.
         */
        fun tryLoad(
            context: Context,
            config: VoiceActivityDetector.Config = VoiceActivityDetector.Config(),
            env: OrtEnvironment = OrtEnvironment.getEnvironment(),
        ): SileroVoiceActivityDetector? {
            return try {
                val path = copyAssetToCache(context, MODEL_ASSET) ?: return null
                val session = env.createSession(path, OrtSession.SessionOptions())
                SileroVoiceActivityDetector(env, session, config)
            } catch (t: Throwable) {
                null
            }
        }

        /** Copy a bundled asset into cache and return its absolute path, or null if absent. */
        private fun copyAssetToCache(context: Context, assetName: String): String? {
            return try {
                val outFile = File(context.cacheDir, assetName)
                context.assets.open(assetName).use { input ->
                    outFile.outputStream().use { output -> input.copyTo(output) }
                }
                outFile.absolutePath
            } catch (t: Throwable) {
                null
            }
        }
    }
}
