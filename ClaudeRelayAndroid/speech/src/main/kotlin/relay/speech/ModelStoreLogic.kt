package relay.speech

/**
 * Pure, Android-free helpers for [SpeechModelStore], factored out so the
 * download-progress math, resume-offset calculation, and `modelsReady`
 * derivation are unit-testable without OkHttp, a filesystem, or a `Context`.
 *
 * The Swift [SpeechModelStore] folds these into the store itself (its progress
 * is computed inline with the `* 0.5` / `0.5 + * 0.5` literals; resume is handled
 * by `URLSession`'s background download which retries from zero, not by Range
 * requests). On Android we make resume explicit (OkHttp `Range:` + a partial
 * `.part` file) and so the offset math becomes worth isolating and testing.
 */
object ModelStoreLogic {

    /**
     * Two-phase combined download progress, mirroring the Swift 50/50 split
     * (`SpeechModelStore.swift:73` `* 0.5`, `:107` `0.5 + fraction * 0.5`):
     * Whisper occupies the first half [0.0, 0.5], the Qwen LLM the second half
     * [0.5, 1.0]. Each model's own fraction is clamped to [0, 1] first so a
     * malformed Content-Length can't push the bar past its half.
     *
     * @param whisperFraction this model's own [0,1] download fraction
     * @param llmFraction this model's own [0,1] download fraction
     * @param whisperDone true once Whisper has fully downloaded (pins its half to 0.5)
     */
    fun combinedProgress(
        whisperFraction: Double,
        llmFraction: Double,
        whisperDone: Boolean,
    ): Double {
        val w = if (whisperDone) 1.0 else whisperFraction.coerceIn(0.0, 1.0)
        val l = llmFraction.coerceIn(0.0, 1.0)
        return (w * 0.5 + l * 0.5).coerceIn(0.0, 1.0)
    }

    /**
     * Per-file download fraction. Guards the divide-by-zero / unknown-total case
     * the Swift delegate guards (`SpeechModelStore.swift:198`
     * `guard totalBytesExpectedToWrite > 0`): when the total is unknown
     * (`<= 0`) we report 0.0 rather than NaN/∞, so the UI ring simply stays empty
     * until a real total arrives.
     */
    fun fileFraction(bytesWritten: Long, totalBytes: Long): Double {
        if (totalBytes <= 0L) return 0.0
        return (bytesWritten.toDouble() / totalBytes.toDouble()).coerceIn(0.0, 1.0)
    }

    /**
     * Resume-offset for a partially-downloaded file. Returns the number of bytes
     * already on disk so the caller can issue `Range: bytes=<offset>-`.
     *
     *  - A negative size (defensive — `File.length()` returns 0 for a missing
     *    file, never negative, but a fake might) clamps to 0.
     *  - When the partial is already >= the known total, the file is complete
     *    (or corrupt-long); returns the total so the caller treats it as a no-op
     *    range and falls through to verification rather than requesting a
     *    past-the-end range the server would 416.
     *  - A non-positive [expectedTotal] (unknown) just returns the on-disk size —
     *    we resume from wherever we are and trust the server's response.
     */
    fun resumeOffset(partialBytesOnDisk: Long, expectedTotal: Long): Long {
        val onDisk = partialBytesOnDisk.coerceAtLeast(0L)
        if (expectedTotal > 0L && onDisk >= expectedTotal) return expectedTotal
        return onDisk
    }

    /**
     * Whether a downloaded file passes the cheap size/existence check. Mirrors
     * the Swift `FileManager.fileExists` gate (`SpeechModelStore.swift:57`),
     * tightened with a known-size match when the server told us the expected
     * total. A non-positive [expectedTotal] means "size unknown" → existence +
     * any non-empty content is accepted (the M4 CER/loader gate is the real
     * integrity check; this is just "did the bytes land").
     */
    fun isFileComplete(exists: Boolean, sizeOnDisk: Long, expectedTotal: Long): Boolean {
        if (!exists) return false
        if (expectedTotal > 0L) return sizeOnDisk == expectedTotal
        return sizeOnDisk > 0L
    }

    /**
     * `modelsReady` derivation, mirroring Swift
     * `SpeechModelStore.swift:31` (`whisperReady && llmDownloaded`). The Qwen LLM
     * is allowed to be absent only when the caller has opted into cloud-only
     * fallback — but `modelsReady` (the "fully on-device" flag) still requires
     * both, exactly like iOS. See [canTranscribe] for the relaxed gate.
     */
    fun modelsReady(whisperReady: Boolean, llmDownloaded: Boolean): Boolean =
        whisperReady && llmDownloaded

    /**
     * The relaxed "can we produce ANY output" gate. Whisper is mandatory (no
     * transcription without it); the Qwen LLM is optional because the
     * cloud-only fallback path (prompt enhancement via Bedrock, or raw
     * passthrough) still delivers text when the local cleanup model is missing.
     * Mirrors the Swift behavior where a failed Qwen download still leaves a
     * usable transcribe + cloud-enhance pipeline (the post-processor degrades to
     * passthrough/enhance when local cleanup is unavailable).
     */
    fun canTranscribe(whisperReady: Boolean): Boolean = whisperReady
}
