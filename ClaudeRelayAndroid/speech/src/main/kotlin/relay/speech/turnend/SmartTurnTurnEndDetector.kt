package relay.speech.turnend

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import java.io.File
import java.nio.FloatBuffer

/**
 * ONNX-Runtime-backed turn-end detector wrapping pipecat-ai/smart-turn v3.
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/SmartTurnTurnEndDetector.swift`.
 *
 * Pipeline:
 * ```
 *   audio (≤8 s, 16 kHz mono) → pad/truncate to 128 000 samples
 *       → WhisperLogMel8s   (log-mel features [1, 80, 800])   input "audio"          → output "log_mel"
 *       → SmartTurnV3        (Whisper-Tiny encoder + linear head, sigmoid)
 *                            input "input_features" → output "probability"
 *       → probability in [0, 1]
 * ```
 *
 * Above `threshold` (0.5) the speaker is considered done.
 *
 * ## GATED to M4 — wire in makeDefault only after ml/validate_parity.py passes
 * This class is intentionally NOT referenced by [relay.speech.ContinuousListeningEngine.makeDefault],
 * which keeps the [HeuristicTurnEndDetector]. The `.onnx` assets it loads do not exist yet — they
 * are produced by `ml/convert_logmel.py` + `ml/convert_smartturn.py` on a Mac in M4 and validated
 * by `ml/validate_parity.py`. Until then [tryLoad] returns null and callers fall back to the
 * heuristic. Do NOT trust this detector's output until the M4 parity gate passes.
 *
 * ## Fail-to-done bias
 * Matching the Swift `infer(...)`, ANY inference error (missing output tensor, ORT exception)
 * returns probability `1.0` → [TurnEndResult.SpeakerDone]. Stalling forever on a hung classifier
 * is worse than occasionally cutting a turn short; the engine's [relay.speech.turnend.raceTurnEnd]
 * safety-net timer is the only thing that resumes recording, so a silent failure must not block it.
 *
 * ## Graceful degradation
 * [tryLoad] returns null if either `.onnx` is absent or fails to create an [OrtSession]; the caller
 * substitutes [HeuristicTurnEndDetector] (mirroring the Swift `init?` returning nil).
 */
class SmartTurnTurnEndDetector private constructor(
    private val env: OrtEnvironment,
    private val preprocessor: OrtSession,
    private val classifier: OrtSession,
    private val threshold: Float,
) : TurnEndDetecting, AutoCloseable {

    override suspend fun predict(utteranceAudio: FloatArray): TurnEndResult {
        val padded = padOrTruncate(utteranceAudio, REQUIRED_SAMPLE_COUNT)
        val probability = infer(padded)
        return thresholdToResult(probability, threshold)
    }

    /**
     * Two-stage ONNX inference. Returns the raw sigmoid probability, or [FAIL_TO_DONE_PROBABILITY]
     * (1.0) on ANY error — see the fail-to-done bias note in the class doc.
     */
    private fun infer(audio: FloatArray): Float {
        return try {
            // Stage 1: audio [1, 128000] → log-mel features [1, 80, 800].
            val logMel = OnnxTensor.createTensor(
                env,
                FloatBuffer.wrap(audio),
                longArrayOf(1, REQUIRED_SAMPLE_COUNT.toLong()),
            ).use { audioTensor ->
                preprocessor.run(mapOf(LOGMEL_INPUT to audioTensor)).use { out ->
                    val value = out.get(LOGMEL_OUTPUT).orElse(null)
                        ?: return FAIL_TO_DONE_PROBABILITY
                    // Re-wrap into a fresh tensor owned by us so it survives `out` being closed.
                    val mel = value as? OnnxTensor ?: return FAIL_TO_DONE_PROBABILITY
                    OnnxTensor.createTensor(env, mel.floatBuffer.duplicate(), mel.info.shape)
                }
            }

            // Stage 2: log-mel → probability [1, 1].
            logMel.use { features ->
                classifier.run(mapOf(CLASSIFIER_INPUT to features)).use { out ->
                    val value = out.get(CLASSIFIER_OUTPUT).orElse(null)
                        ?: return FAIL_TO_DONE_PROBABILITY
                    firstFloat(value) ?: FAIL_TO_DONE_PROBABILITY
                }
            }
        } catch (t: Throwable) {
            FAIL_TO_DONE_PROBABILITY
        }
    }

    /** Flatten the first scalar out of a probability tensor of shape [1], [1, 1], etc. */
    private fun firstFloat(value: ai.onnxruntime.OnnxValue): Float? {
        val tensor = value as? OnnxTensor ?: return null
        val buf = tensor.floatBuffer ?: return null
        if (buf.capacity() == 0) return null
        return buf.get(0)
    }

    override fun close() {
        runCatching { preprocessor.close() }
        runCatching { classifier.close() }
    }

    companion object {
        /** 8 s at 16 kHz — the model's fixed input length. */
        const val REQUIRED_SAMPLE_COUNT = 128_000

        /** Default sigmoid threshold above which the speaker is "done". */
        const val DEFAULT_THRESHOLD = 0.5f

        /**
         * Probability returned on ANY inference error → mapped to [TurnEndResult.SpeakerDone].
         * Mirrors the Swift `return 1.0` fail paths.
         */
        const val FAIL_TO_DONE_PROBABILITY = 1.0f

        // ── ONNX graph I/O names (verified against the CoreML source models) ──
        // WhisperLogMel8s.mlpackage: input "audio"  → output "log_mel"
        // SmartTurnV3.mlpackage:     input "input_features" → output "probability"
        const val LOGMEL_INPUT = "audio"
        const val LOGMEL_OUTPUT = "log_mel"
        const val CLASSIFIER_INPUT = "input_features"
        const val CLASSIFIER_OUTPUT = "probability"

        /** Asset file names produced by `ml/convert_logmel.py` / `ml/convert_smartturn.py`. */
        const val LOGMEL_ASSET = "whisper_logmel8s.onnx"
        const val CLASSIFIER_ASSET = "smartturn_v3.onnx"

        /**
         * Pure helper: take the last [n] samples; zero-pad **at the start** if shorter.
         * Smart-Turn expects the newest audio at the END of the window, so a short clip is
         * left-padded with silence. Faithful port of Swift `padOrTruncate`.
         *
         * Testable without a model.
         */
        fun padOrTruncate(samples: FloatArray, n: Int): FloatArray {
            if (samples.size == n) return samples
            if (samples.size > n) return samples.copyOfRange(samples.size - n, samples.size)
            val out = FloatArray(n) // zero-initialized
            System.arraycopy(samples, 0, out, n - samples.size, samples.size)
            return out
        }

        /**
         * Pure helper: map a sigmoid probability to a [TurnEndResult] given [threshold].
         * `>= threshold` → done (confidence = probability); else continuing (confidence = 1 - probability).
         * Faithful port of the Swift `predict` tail. Testable without a model.
         */
        fun thresholdToResult(probability: Float, threshold: Float = DEFAULT_THRESHOLD): TurnEndResult =
            if (probability >= threshold) {
                TurnEndResult.SpeakerDone(confidence = probability)
            } else {
                TurnEndResult.SpeakerContinuing(confidence = 1.0f - probability)
            }

        /**
         * Attempt to load both ONNX models from app assets and build a detector.
         *
         * Returns null (→ caller falls back to [HeuristicTurnEndDetector]) when either asset is
         * absent or fails to open — the **current state**, since the `.onnx` files are produced by
         * the M4 conversion run. Mirrors the Swift `init?` returning nil.
         *
         * ONNX Runtime needs a real file path (it mmaps the model), so assets are copied to the app
         * cache on first load.
         */
        fun tryLoad(
            context: Context,
            threshold: Float = DEFAULT_THRESHOLD,
            env: OrtEnvironment = OrtEnvironment.getEnvironment(),
        ): SmartTurnTurnEndDetector? {
            return try {
                val logMelPath = copyAssetToCache(context, LOGMEL_ASSET) ?: return null
                val classifierPath = copyAssetToCache(context, CLASSIFIER_ASSET) ?: return null
                val opts = OrtSession.SessionOptions()
                val pre = env.createSession(logMelPath, opts)
                val cls = env.createSession(classifierPath, opts)
                SmartTurnTurnEndDetector(env, pre, cls, threshold)
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
