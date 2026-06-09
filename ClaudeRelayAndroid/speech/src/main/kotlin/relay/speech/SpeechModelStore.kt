package relay.speech

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException

/**
 * Manages model downloads, caching, and disk lifecycle for the speech pipeline.
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/SpeechModelStore.swift`, adapted to
 * Android's filesystem + OkHttp and the **download-vs-bundle split** from
 * corrections §A6:
 *
 *  - **Downloads exactly TWO artifacts** (same identity as iOS):
 *      1. Whisper **ggml** `small.en` (`ggml-small.en.bin`). iOS gets a
 *         WhisperKit-managed **CoreML** `small.en` via `WhisperKit.download`;
 *         Android's whisper.cpp needs the **ggml** flavour of the *same OpenAI
 *         checkpoint* (format-distinct, parity validated by the M4 CER gate —
 *         A6). The contract: fetch ggml `small.en` from the canonical
 *         `ggerganov/whisper.cpp` HF repo. Verbatim Qwen URL/filename are carried
 *         from the Swift source.
 *      2. Qwen `qwen35-0.8b-q4km.gguf` from
 *         `https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf`
 *         (≈0.5 GB / 532,517,120 bytes — NOT 2.4 GB; A6). URL + filename are
 *         copied verbatim from `SpeechModelStore.swift:24-29`.
 *  - **Bundles THREE ONNX models** (Silero VAD / SmartTurn v3 / Whisper LogMel)
 *    as app **assets** — NOT downloaded. iOS bundles the CoreML originals
 *    (`SileroVAD.mlmodelc` / `SmartTurnV3.mlpackage` / `WhisperLogMel8s.mlpackage`);
 *    Android cannot bundle `.mlmodelc/.mlpackage`, so it bundles the ONNX
 *    conversions (produced in M3-E / M4). They are small (904K / 15M / 364K
 *    originals) and already in the APK via the gated detectors — this store does
 *    not touch them. See [bundledOnnxAssets].
 *
 * ## What is real vs deferred
 *  - **Real here:** OkHttp download with **resumable** `Range:` requests against a
 *    `.part` sidecar, a [StateFlow] progress per model + a combined
 *    [downloadProgress], on-disk cache under `filesDir/Models`, and
 *    size/existence verification. The pure math/derivations live in
 *    [ModelStoreLogic] and are unit-tested.
 *  - **Device-deferred (JNI, no CMake in this env):** the actual whisper.cpp /
 *    llama.cpp model *loading*. This store only fetches + caches the files; the
 *    transcriber/cleaner bridges load them in M4.
 *
 * ## Cloud-only fallback
 * [modelsReady] (`whisperReady && llmDownloaded`) mirrors iOS exactly. If the
 * Qwen download fails, [downloadAllModels] still leaves Whisper in place and
 * surfaces the failure as a non-fatal "[canTranscribe] is true but cleanup is
 * cloud-only" state: callers can still transcribe and cloud-enhance (the
 * post-processor degrades to passthrough/enhance when local cleanup is absent).
 *
 * Not thread-safe by design beyond the [StateFlow]s — call [downloadAllModels]
 * from a single scope (the app does so from a best-effort background task).
 */
class SpeechModelStore(
    private val filesDir: File,
    private val httpClient: OkHttpClient = OkHttpClient(),
    private val whisperModelUrl: String = WHISPER_GGML_SMALL_EN_URL,
    private val llmModelUrl: String = LLM_MODEL_URL,
) {

    private val _whisperReady = MutableStateFlow(false)
    val whisperReady: StateFlow<Boolean> = _whisperReady.asStateFlow()

    private val _llmDownloaded = MutableStateFlow(false)
    val llmDownloaded: StateFlow<Boolean> = _llmDownloaded.asStateFlow()

    /** Combined 0.0–1.0 progress (50/50 split), or null when not downloading. */
    private val _downloadProgress = MutableStateFlow<Double?>(null)
    val downloadProgress: StateFlow<Double?> = _downloadProgress.asStateFlow()

    // Per-model fractions, kept so the combined bar can be recomputed when either
    // phase advances (the Swift store does this inline; we keep the latest values).
    private var whisperFraction = 0.0
    private var llmFraction = 0.0

    private val modelsDirectory: File get() = File(filesDir, "Models")
    val whisperModelPath: File get() = File(modelsDirectory, WHISPER_FILE_NAME)
    val llmModelPath: File get() = File(modelsDirectory, LLM_FILE_NAME)

    init {
        // Seed flags from disk, mirroring Swift `init` (`SpeechModelStore.swift:56-59`):
        // existence is the on-launch source of truth (whisperReady is a flag in iOS
        // because WhisperKit owns its own cache; on Android we own the ggml file, so
        // we derive it from the file directly — single source of truth, no UserDefaults
        // key needed).
        _whisperReady.value = whisperModelPath.exists() && whisperModelPath.length() > 0L
        _llmDownloaded.value = llmModelPath.exists() && llmModelPath.length() > 0L
    }

    /** `whisperReady && llmDownloaded` — the fully-on-device gate (Swift parity). */
    val modelsReady: Boolean
        get() = ModelStoreLogic.modelsReady(_whisperReady.value, _llmDownloaded.value)

    /** Relaxed gate: Whisper present → transcription + cloud-enhance is possible. */
    val canTranscribe: Boolean
        get() = ModelStoreLogic.canTranscribe(_whisperReady.value)

    /** The three ONNX assets bundled in the APK (NOT downloaded). For documentation/UX. */
    val bundledOnnxAssets: List<String> get() = BUNDLED_ONNX_ASSETS

    /**
     * Download both models, mirroring Swift `downloadAllModels`
     * (`SpeechModelStore.swift:65-97`): Whisper first (progress → first half),
     * then Qwen (progress → second half). 50/50 split.
     *
     * Cloud-only fallback: a Qwen failure is swallowed (logged via [onLlmFailure])
     * so a partial install still leaves [canTranscribe] true. A Whisper failure is
     * fatal — without it there is no transcription — and rethrows.
     */
    suspend fun downloadAllModels(onLlmFailure: (Throwable) -> Unit = {}) {
        modelsDirectory.mkdirs()
        _downloadProgress.value = 0.0

        // Phase 1: Whisper ggml small.en (mandatory).
        if (!_whisperReady.value) {
            downloadResumable(
                url = whisperModelUrl,
                destination = whisperModelPath,
                onFraction = { f ->
                    whisperFraction = f
                    publishCombined()
                },
            )
        }
        whisperFraction = 1.0
        _whisperReady.value = true
        publishCombined()

        // Phase 2: Qwen GGUF (optional — cloud-only fallback on failure).
        if (!_llmDownloaded.value) {
            try {
                downloadResumable(
                    url = llmModelUrl,
                    destination = llmModelPath,
                    onFraction = { f ->
                        llmFraction = f
                        publishCombined()
                    },
                )
                llmFraction = 1.0
                _llmDownloaded.value = true
            } catch (e: Throwable) {
                // Cloud-only fallback: keep Whisper, surface the failure, leave
                // llmDownloaded=false so the post-processor degrades gracefully.
                onLlmFailure(e)
            }
        } else {
            llmFraction = 1.0
        }

        publishCombined()
        _downloadProgress.value = null
    }

    /**
     * Best-effort, non-blocking "is everything already on disk?" check used by the
     * splash preload hook. Re-derives the flags from the filesystem (a download
     * from a previous launch may have completed) WITHOUT kicking off a download.
     * Returns [modelsReady]. The splash calls this; the actual download is
     * user-gated behind the mic button's download prompt (Swift parity — the
     * iOS preload only loads ALREADY-downloaded models into memory).
     */
    fun refreshFromDisk(): Boolean {
        _whisperReady.value = whisperModelPath.exists() && whisperModelPath.length() > 0L
        _llmDownloaded.value = llmModelPath.exists() && llmModelPath.length() > 0L
        return modelsReady
    }

    /** Delete all downloaded models to free disk space (Swift `deleteModels`). */
    fun deleteModels() {
        modelsDirectory.deleteRecursively()
        _whisperReady.value = false
        _llmDownloaded.value = false
        whisperFraction = 0.0
        llmFraction = 0.0
        _downloadProgress.value = null
    }

    /** Total bytes used by downloaded models on disk (Swift `totalModelSize`). */
    fun totalModelSize(): Long {
        if (!modelsDirectory.exists()) return 0L
        return modelsDirectory.walkTopDown()
            .filter { it.isFile }
            .fold(0L) { acc, f -> acc + f.length() }
    }

    // MARK: - Resumable download

    /**
     * Downloads [url] to [destination] resumably: appends to a `.part` sidecar,
     * sending `Range: bytes=<offset>-` when a partial already exists, then
     * atomically renames to [destination] on success. Verifies the final size
     * against the server's reported total ([ModelStoreLogic.isFileComplete]).
     *
     * Runs the blocking OkHttp call on [Dispatchers.IO]. The progress callback is
     * invoked on that IO thread; the StateFlow it writes is safe to update from
     * any thread.
     */
    private suspend fun downloadResumable(
        url: String,
        destination: File,
        onFraction: (Double) -> Unit,
    ) = withContext(Dispatchers.IO) {
        destination.parentFile?.mkdirs()
        val partFile = File(destination.parentFile, destination.name + PART_SUFFIX)
        val existing = if (partFile.exists()) partFile.length() else 0L

        val requestBuilder = Request.Builder().url(url)
        if (existing > 0L) {
            // Resume from where we left off (Range request).
            requestBuilder.header("Range", "bytes=$existing-")
        }

        httpClient.newCall(requestBuilder.build()).execute().use { response ->
            if (!response.isSuccessful) {
                throw ModelStoreError.DownloadFailed("HTTP ${response.code} for $url")
            }
            val body = response.body ?: throw ModelStoreError.DownloadFailed("Empty body for $url")

            // A 200 (not 206) means the server ignored Range and is sending the
            // whole file — discard the stale partial and start fresh.
            val isPartialResponse = response.code == 206
            val startOffset = ModelStoreLogic.resumeOffset(
                partialBytesOnDisk = if (isPartialResponse) existing else 0L,
                expectedTotal = -1L,
            )
            if (!isPartialResponse && existing > 0L) {
                partFile.delete()
            }

            // Total = bytes already on disk + bytes this response will deliver.
            val contentLength = body.contentLength()
            val expectedTotal = if (contentLength >= 0L) startOffset + contentLength else -1L

            body.byteStream().use { input ->
                java.io.RandomAccessFile(partFile, "rw").use { raf ->
                    raf.seek(startOffset)
                    val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
                    var written = startOffset
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        raf.write(buffer, 0, read)
                        written += read
                        onFraction(ModelStoreLogic.fileFraction(written, expectedTotal))
                    }
                }
            }

            // Verify, then atomically promote the .part to the final path.
            val complete = ModelStoreLogic.isFileComplete(
                exists = partFile.exists(),
                sizeOnDisk = partFile.length(),
                expectedTotal = expectedTotal,
            )
            if (!complete) {
                throw ModelStoreError.DownloadFailed(
                    "Size mismatch for $url (got ${partFile.length()}, expected $expectedTotal)",
                )
            }
            if (destination.exists()) destination.delete()
            if (!partFile.renameTo(destination)) {
                // Fallback to copy if rename across boundaries fails (same volume
                // here, so rename should succeed; copy is defensive).
                partFile.copyTo(destination, overwrite = true)
                partFile.delete()
            }
        }
    }

    private fun publishCombined() {
        _downloadProgress.value = ModelStoreLogic.combinedProgress(
            whisperFraction = whisperFraction,
            llmFraction = llmFraction,
            whisperDone = _whisperReady.value,
        )
    }

    companion object {
        /**
         * Qwen GGUF URL — VERBATIM from `SpeechModelStore.swift:25-27`. ≈0.5 GB.
         */
        const val LLM_MODEL_URL =
            "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf"

        /** Qwen on-disk filename — VERBATIM from `SpeechModelStore.swift:29`. */
        const val LLM_FILE_NAME = "qwen35-0.8b-q4km.gguf"

        /**
         * Whisper **ggml** `small.en` URL. iOS gets CoreML `small.en` via
         * WhisperKit's own downloader (no explicit URL in the Swift source);
         * Android's whisper.cpp consumes the ggml flavour of the same OpenAI
         * checkpoint, fetched from the canonical `ggerganov/whisper.cpp` HF repo
         * (A6: same checkpoint, format-distinct, M4 CER-gated).
         */
        const val WHISPER_GGML_SMALL_EN_URL =
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"

        const val WHISPER_FILE_NAME = "ggml-small.en.bin"

        /** Suffix for the in-flight partial download sidecar. */
        private const val PART_SUFFIX = ".part"

        private const val DOWNLOAD_BUFFER_BYTES = 64 * 1024

        /**
         * The three ONNX models bundled as APK assets (NOT downloaded). Produced
         * by the M3-E / M4 CoreML→ONNX conversion; consumed by the gated
         * Silero/SmartTurn/LogMel detectors. Listed for documentation + a UX
         * "what's bundled" surface.
         */
        val BUNDLED_ONNX_ASSETS: List<String> = listOf(
            "silero_vad.onnx",
            "smart_turn_v3.onnx",
            "whisper_logmel_8s.onnx",
        )

        /**
         * Builds the production store rooted at the app's files dir
         * (`context.filesDir`), the Android analog of iOS's
         * `<AppSupport>/Models/`.
         */
        fun create(context: Context): SpeechModelStore =
            SpeechModelStore(filesDir = context.applicationContext.filesDir)
    }
}

/** Errors surfaced by [SpeechModelStore]. Ported from Swift `ModelStoreError`. */
sealed class ModelStoreError(message: String) : IOException(message) {
    class DownloadFailed(detail: String) : ModelStoreError("Failed to download speech model: $detail")
    object InsufficientDiskSpace :
        ModelStoreError("Not enough storage for speech models (~1 GB required)") {
        private fun readResolve(): Any = InsufficientDiskSpace
    }
}
