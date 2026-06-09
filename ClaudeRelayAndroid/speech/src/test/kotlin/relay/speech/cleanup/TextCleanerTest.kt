package relay.speech.cleanup

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Tests the pure [TextCleaner] helpers ([TextCleaner.sanitizeResponse],
 * [TextCleaner.looksHallucinated]) and the short-input bypass. The llama.cpp
 * native inference is a deferred EXECUTION NOTE and is not exercised here.
 *
 * Mirrors the cleanup-engine helper behaviour from
 * `Sources/ClaudeRelaySpeech/TextCleaner.swift`.
 */
class TextCleanerTest {

    @Test
    fun `minimum word count and timeout constants match swift`() {
        assertEquals(3, TextCleaner.MINIMUM_WORD_COUNT)
        assertEquals(8L, TextCleaner.CLEANUP_TIMEOUT_SECONDS)
        assertEquals(30L, TextCleaner.IDLE_TIMEOUT_SECONDS)
    }

    @Test
    fun `sanitizeResponse strips think blocks`() {
        assertEquals(
            "list the files",
            TextCleaner.sanitizeResponse("<think>I should clean this</think>list the files"),
        )
        assertEquals(
            "run the build",
            TextCleaner.sanitizeResponse("<think>a</think>run<think>b</think> the build"),
        )
    }

    @Test
    fun `sanitizeResponse trims and passes clean text`() {
        assertEquals("hello world", TextCleaner.sanitizeResponse("  hello world  "))
    }

    @Test
    fun `looksHallucinated flags markdown fences and html`() {
        assertTrue(TextCleaner.looksHallucinated("hi", "```kotlin\ncode\n```"))
        assertTrue(TextCleaner.looksHallucinated("hi", "<div>oops</div>"))
        assertTrue(TextCleaner.looksHallucinated("hi", "<script>x</script>"))
    }

    @Test
    fun `looksHallucinated flags wildly inflated output`() {
        // Requires BOTH output.length > input.length * 3 AND output.length > 100.
        val input = "list the files in the project directory please"
        val output = "x".repeat(input.length * 3 + 1)
        assertTrue(output.length > 100, "test precondition: output must exceed 100 chars")
        assertTrue(TextCleaner.looksHallucinated(input, output))
    }

    @Test
    fun `looksHallucinated does not flag modestly longer short output`() {
        // 3x longer but under the 100-char floor -> not flagged (matches Swift guard).
        val input = "go"
        val output = "x".repeat(input.length * 3 + 1)
        assertFalse(TextCleaner.looksHallucinated(input, output))
    }

    @Test
    fun `looksHallucinated passes normal cleanup`() {
        assertFalse(TextCleaner.looksHallucinated("um list the files", "List the files."))
    }

    @Test
    fun `short input bypasses model and returns unchanged`() = runTest {
        // Two words < minimumWordCount(3): returned verbatim without touching the
        // (deferred) native model, so no ModelNotLoaded is thrown.
        assertEquals("hi there", TextCleaner().clean("hi there"))
    }
}
