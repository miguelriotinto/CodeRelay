package relay.speech.wakeword

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Mirrors the pure-matching cases of
 * `Tests/ClaudeRelaySpeechTests/WakeWordDetectorTests.swift`. The transcription
 * (Whisper) half of the Swift detector is a later task; only the match cascade,
 * Levenshtein, and Metaphone are ported here.
 */
class WakeWordTest {

    // MARK: - Generic wake word detection (any keyword)

    @Test
    fun `exact match with custom keyword`() {
        val result = WakeWordDetector.match(transcript = "jarvis", keyword = "jarvis")
        assertEquals(WakeWordResult.Detected(residueText = ""), result)
    }

    @Test
    fun `fuzzy match within levenshtein 2 with custom keyword`() {
        // 'jarvas' is 1 edit from 'jarvis'.
        val result = WakeWordDetector.match(transcript = "jarvas", keyword = "jarvis")
        assertTrue(result is WakeWordResult.Detected, "Expected fuzzy match (distance 1)")
    }

    @Test
    fun `levenshtein within 2 matches 'clawd' against 'claude'`() {
        // levenshtein("clawd", "claude") = 2 (substitute w->u, insert e... actually
        // 'clawd' vs 'claude': aligns cla, then w/u sub + insert d/e... <= 2).
        val result = WakeWordDetector.match(transcript = "clawd", keyword = "claude")
        assertTrue(result is WakeWordResult.Detected, "Expected 'clawd' to match 'claude' within distance 2")
    }

    @Test
    fun `no match with custom keyword`() {
        val result = WakeWordDetector.match(transcript = "hello run diagnostics", keyword = "jarvis")
        assertEquals(WakeWordResult.NotDetected, result)
    }

    @Test
    fun `scan window limits to first three words`() {
        val result = WakeWordDetector.match(
            transcript = "I was just telling somebody about computer the other day",
            keyword = "computer",
        )
        assertEquals(WakeWordResult.NotDetected, result, "Keyword beyond first 3 words should not trigger")
    }

    @Test
    fun `keyword within scan window with residue`() {
        val result = WakeWordDetector.match(transcript = "hey computer play some music", keyword = "computer")
        assertEquals(WakeWordResult.Detected(residueText = "play some music"), result)
    }

    @Test
    fun `case insensitive match`() {
        val result = WakeWordDetector.match(transcript = "ALEXA", keyword = "alexa")
        assertEquals(WakeWordResult.Detected(residueText = ""), result)
    }

    @Test
    fun `short words are skipped`() {
        // minLen = keyword.count - 2 = 3, so "oh"/"hi" are skipped; "there" is
        // levenshtein 4 from "hello" > 2.
        val result = WakeWordDetector.match(transcript = "oh hi there hello world", keyword = "hello")
        assertEquals(WakeWordResult.NotDetected, result)
    }

    @Test
    fun `empty transcript returns notDetected`() {
        assertEquals(WakeWordResult.NotDetected, WakeWordDetector.match(transcript = "", keyword = "anything"))
    }

    // MARK: - Levenshtein

    @Test
    fun `levenshtein exact match`() {
        assertEquals(0, WakeWordDetector.levenshtein("siri", "siri"))
        assertEquals(0, WakeWordDetector.levenshtein("computer", "computer"))
    }

    @Test
    fun `levenshtein one edit`() {
        assertEquals(1, WakeWordDetector.levenshtein("siri", "sir"))
        assertEquals(1, WakeWordDetector.levenshtein("alexa", "alex"))
        assertEquals(1, WakeWordDetector.levenshtein("claude", "claud"))
    }

    @Test
    fun `levenshtein two edits`() {
        assertEquals(2, WakeWordDetector.levenshtein("claude", "cloud"))
        assertEquals(1, WakeWordDetector.levenshtein("jarvis", "jarvas"))
        assertEquals(1, WakeWordDetector.levenshtein("computer", "compuper"))
    }

    @Test
    fun `levenshtein empty strings`() {
        assertEquals(3, WakeWordDetector.levenshtein("", "abc"))
        assertEquals(3, WakeWordDetector.levenshtein("abc", ""))
        assertEquals(0, WakeWordDetector.levenshtein("", ""))
    }

    // MARK: - Metaphone

    @Test
    fun `metaphone primitives for common words`() {
        assertEquals("KLT", Metaphone.encode("claude"))
        assertEquals("KLT", Metaphone.encode("cloud"))
        assertEquals("KLT", Metaphone.encode("clod"))
        assertEquals("KLT", Metaphone.encode("clawed"))
    }

    @Test
    fun `metaphone keeps distinct words distinct`() {
        assertNotEquals(Metaphone.encode("claude"), Metaphone.encode("hello"))
        assertNotEquals(Metaphone.encode("jarvis"), Metaphone.encode("service"))
    }

    @Test
    fun `metaphone handles empty`() {
        assertEquals("", Metaphone.encode(""))
    }

    @Test
    fun `metaphone match accepts phonetically similar word`() {
        // 'klaude' sounds like 'claude' (KLT) and shares first letter region via
        // the guard — but note 'k' != 'c', so this exercises a same-letter case.
        // Use 'clod' which is phonetically KLT and starts with the same letter 'c'.
        val result = WakeWordDetector.match(transcript = "clod", keyword = "claude")
        assertTrue(result is WakeWordResult.Detected, "Phonetic match should accept 'clod'")
    }

    @Test
    fun `metaphone first-letter guard rejects acoustically distant word`() {
        val result = WakeWordDetector.match(transcript = "gold", keyword = "claude")
        assertEquals(WakeWordResult.NotDetected, result)
    }

    @Test
    fun `first-letter guard rejects frog against claude`() {
        val result = WakeWordDetector.match(transcript = "frog", keyword = "claude")
        assertEquals(WakeWordResult.NotDetected, result)
    }

    // MARK: - Known aliases

    @Test
    fun `alias match for default keyword`() {
        // 'lord' is a known Whisper mishearing of 'claude'.
        val result = WakeWordDetector.match(transcript = "Lord", keyword = "claude")
        assertEquals(WakeWordResult.Detected(residueText = ""), result)
    }

    @Test
    fun `alias 'cloud' matches default keyword`() {
        val result = WakeWordDetector.match(transcript = "cloud", keyword = "claude")
        assertTrue(result is WakeWordResult.Detected)
    }

    @Test
    fun `aliases do not apply to other keywords`() {
        val result = WakeWordDetector.match(transcript = "Lord", keyword = "jarvis")
        assertEquals(WakeWordResult.NotDetected, result)
    }

    @Test
    fun `default keyword is claude`() {
        assertEquals("claude", WakeWordDetector.DEFAULT_KEYWORD)
    }
}
