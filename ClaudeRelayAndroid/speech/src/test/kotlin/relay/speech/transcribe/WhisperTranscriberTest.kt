package relay.speech.transcribe

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Mirrors `Tests/ClaudeRelaySpeechTests/WhisperTranscriberTests.swift` plus the
 * silence-hallucination filter (`TranscriberError.isSilenceHallucination`).
 *
 * Only the pure heuristics are tested — `transcribe()` is whisper.cpp JNI and is
 * a deferred EXECUTION NOTE (no CMake / no device in this env).
 */
class WhisperTranscriberTest {

    // MARK: - collapseRepetitions: no false positives

    @Test
    fun `no repetition`() {
        val input = "What is the current working directory?"
        assertEquals(input, WhisperTranscriber.collapseRepetitions(input))
    }

    @Test
    fun `single sentence no collapse`() {
        val input = "Please list the files in this project"
        assertEquals(input, WhisperTranscriber.collapseRepetitions(input))
    }

    @Test
    fun `short text unchanged`() {
        assertEquals("hi", WhisperTranscriber.collapseRepetitions("hi"))
        assertEquals("check the logs", WhisperTranscriber.collapseRepetitions("check the logs"))
    }

    @Test
    fun `legitimate repeated words not collapsed`() {
        val input = "I said go go go and then stopped"
        assertEquals(input, WhisperTranscriber.collapseRepetitions(input))
    }

    @Test
    fun `two distinct sentences not collapsed`() {
        val input = "First run the tests. Then check the coverage."
        assertEquals(input, WhisperTranscriber.collapseRepetitions(input))
    }

    // MARK: - Sentence-level repetition (punctuation-delimited)

    @Test
    fun `sentence repetition with question marks`() {
        val input = "What is the current working directory?What is the current working directory?What is the current working directory?"
        assertEquals(
            "What is the current working directory?",
            WhisperTranscriber.collapseRepetitions(input),
        )
    }

    @Test
    fun `sentence repetition with spaces and punctuation`() {
        val input = "Check the current directory. Check the current directory. Check the current directory."
        assertEquals(
            "Check the current directory.",
            WhisperTranscriber.collapseRepetitions(input),
        )
    }

    @Test
    fun `double repetition with period`() {
        val input = "List all files. List all files."
        assertEquals(
            "List all files.",
            WhisperTranscriber.collapseRepetitions(input),
        )
    }

    @Test
    fun `sentence repetition with minor variation`() {
        // Whisper sometimes capitalizes differently between loops
        val input = "What time is it? what time is it?"
        assertEquals(
            "What time is it?",
            WhisperTranscriber.collapseRepetitions(input),
        )
    }

    // MARK: - Character-level repetition (no delimiter)

    @Test
    fun `direct concatenation double`() {
        val input = "check the current directorycheck the current directory"
        assertEquals(
            "check the current directory",
            WhisperTranscriber.collapseRepetitions(input),
        )
    }

    @Test
    fun `direct concatenation triple`() {
        val input = "run the build nowrun the build nowrun the build now"
        assertEquals(
            "run the build now",
            WhisperTranscriber.collapseRepetitions(input),
        )
    }

    @Test
    fun `repetition with partial trailing`() {
        val input = "show me the logsshow me the logsshow me the"
        assertEquals(
            "show me the logs",
            WhisperTranscriber.collapseRepetitions(input),
        )
    }

    // MARK: - Edge cases

    @Test
    fun `exactly twenty chars not crash`() {
        val input = "12345678901234567890"
        // 20 chars, no repetition — should pass through
        assertEquals(input, WhisperTranscriber.collapseRepetitions(input))
    }

    @Test
    fun `empty and very short`() {
        assertEquals("", WhisperTranscriber.collapseRepetitions(""))
        assertEquals("a", WhisperTranscriber.collapseRepetitions("a"))
    }

    // MARK: - Silence hallucination filter

    @Test
    fun `silence hallucinations recognized case insensitively`() {
        assertTrue(WhisperTranscriber.isSilenceHallucination("Thank you"))
        assertTrue(WhisperTranscriber.isSilenceHallucination("thanks for watching"))
        assertTrue(WhisperTranscriber.isSilenceHallucination("Bye."))
        assertTrue(WhisperTranscriber.isSilenceHallucination("you"))
        assertTrue(WhisperTranscriber.isSilenceHallucination("Subscribe!"))
        assertTrue(WhisperTranscriber.isSilenceHallucination("the end"))
    }

    @Test
    fun `real text is not a silence hallucination`() {
        assertFalse(WhisperTranscriber.isSilenceHallucination("list the files"))
        assertFalse(WhisperTranscriber.isSilenceHallucination("thank you for the detailed review"))
        assertFalse(WhisperTranscriber.isSilenceHallucination("run the build"))
    }
}
