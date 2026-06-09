package relay.speech

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Pure-logic tests for [ModelStoreLogic] — the download-progress math,
 * resume-offset calculation, file-completeness check, and `modelsReady` /
 * `canTranscribe` derivations extracted from [SpeechModelStore]. No OkHttp, no
 * filesystem, no `Context` — the real download + cache lifecycle is verified by
 * compile + the APK build (device-deferred runtime).
 */
class SpeechModelStoreLogicTest {

    // MARK: - combinedProgress (50/50 split, Swift parity)

    @Test
    fun `combinedProgress nothing downloaded`() {
        assertEquals(0.0, ModelStoreLogic.combinedProgress(0.0, 0.0, whisperDone = false))
    }

    @Test
    fun `combinedProgress whisper half done occupies first quarter`() {
        // Whisper at 50% of its [0,0.5] half → 0.25.
        assertEquals(0.25, ModelStoreLogic.combinedProgress(0.5, 0.0, whisperDone = false))
    }

    @Test
    fun `combinedProgress whisper done pins first half to 0_5`() {
        assertEquals(0.5, ModelStoreLogic.combinedProgress(0.5, 0.0, whisperDone = true))
    }

    @Test
    fun `combinedProgress whisper done plus llm half`() {
        // Whisper done (0.5) + LLM at 50% of its [0.5,1.0] half (0.25) → 0.75.
        assertEquals(0.75, ModelStoreLogic.combinedProgress(1.0, 0.5, whisperDone = true))
    }

    @Test
    fun `combinedProgress both complete`() {
        assertEquals(1.0, ModelStoreLogic.combinedProgress(1.0, 1.0, whisperDone = true))
    }

    @Test
    fun `combinedProgress clamps out-of-range fractions`() {
        // A malformed Content-Length must not push the bar past a half.
        assertEquals(1.0, ModelStoreLogic.combinedProgress(2.0, 5.0, whisperDone = true))
        assertEquals(0.0, ModelStoreLogic.combinedProgress(-1.0, -1.0, whisperDone = false))
    }

    // MARK: - fileFraction (divide-by-zero guard, Swift `totalBytesExpectedToWrite > 0`)

    @Test
    fun `fileFraction unknown total reports zero`() {
        assertEquals(0.0, ModelStoreLogic.fileFraction(123, 0))
        assertEquals(0.0, ModelStoreLogic.fileFraction(123, -1))
    }

    @Test
    fun `fileFraction normal case`() {
        assertEquals(0.5, ModelStoreLogic.fileFraction(50, 100))
    }

    @Test
    fun `fileFraction clamps overshoot`() {
        assertEquals(1.0, ModelStoreLogic.fileFraction(150, 100))
    }

    // MARK: - resumeOffset

    @Test
    fun `resumeOffset fresh download is zero`() {
        assertEquals(0L, ModelStoreLogic.resumeOffset(partialBytesOnDisk = 0, expectedTotal = 1000))
    }

    @Test
    fun `resumeOffset partial returns bytes on disk`() {
        assertEquals(400L, ModelStoreLogic.resumeOffset(partialBytesOnDisk = 400, expectedTotal = 1000))
    }

    @Test
    fun `resumeOffset complete-or-over returns total`() {
        // A partial >= total must not request a past-the-end range (server 416).
        assertEquals(1000L, ModelStoreLogic.resumeOffset(partialBytesOnDisk = 1000, expectedTotal = 1000))
        assertEquals(1000L, ModelStoreLogic.resumeOffset(partialBytesOnDisk = 1500, expectedTotal = 1000))
    }

    @Test
    fun `resumeOffset unknown total trusts on-disk size`() {
        assertEquals(400L, ModelStoreLogic.resumeOffset(partialBytesOnDisk = 400, expectedTotal = -1))
    }

    @Test
    fun `resumeOffset clamps negative to zero`() {
        assertEquals(0L, ModelStoreLogic.resumeOffset(partialBytesOnDisk = -5, expectedTotal = 1000))
    }

    // MARK: - isFileComplete

    @Test
    fun `isFileComplete missing file`() {
        assertFalse(ModelStoreLogic.isFileComplete(exists = false, sizeOnDisk = 0, expectedTotal = 100))
    }

    @Test
    fun `isFileComplete exact size match`() {
        assertTrue(ModelStoreLogic.isFileComplete(exists = true, sizeOnDisk = 100, expectedTotal = 100))
    }

    @Test
    fun `isFileComplete size mismatch`() {
        assertFalse(ModelStoreLogic.isFileComplete(exists = true, sizeOnDisk = 99, expectedTotal = 100))
    }

    @Test
    fun `isFileComplete unknown total accepts any non-empty content`() {
        assertTrue(ModelStoreLogic.isFileComplete(exists = true, sizeOnDisk = 1, expectedTotal = -1))
        assertFalse(ModelStoreLogic.isFileComplete(exists = true, sizeOnDisk = 0, expectedTotal = -1))
    }

    // MARK: - modelsReady / canTranscribe (Swift parity)

    @Test
    fun `modelsReady requires both`() {
        assertTrue(ModelStoreLogic.modelsReady(whisperReady = true, llmDownloaded = true))
        assertFalse(ModelStoreLogic.modelsReady(whisperReady = true, llmDownloaded = false))
        assertFalse(ModelStoreLogic.modelsReady(whisperReady = false, llmDownloaded = true))
    }

    @Test
    fun `canTranscribe needs only whisper (cloud-only fallback)`() {
        // LLM missing but Whisper present → still usable (transcribe + cloud-enhance).
        assertTrue(ModelStoreLogic.canTranscribe(whisperReady = true))
        assertFalse(ModelStoreLogic.canTranscribe(whisperReady = false))
    }
}
