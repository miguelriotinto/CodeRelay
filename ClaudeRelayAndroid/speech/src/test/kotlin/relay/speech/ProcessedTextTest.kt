package relay.speech

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

/** Mirrors `Tests/ClaudeRelaySpeechTests/ProcessedTextTests.swift`. */
class ProcessedTextTest {

    @Test
    fun `deliverableText returns string for deliverable cases`() {
        assertEquals("hi", ProcessedText.Passthrough("hi").deliverableText)
        assertEquals("clean", ProcessedText.Cleaned("clean").deliverableText)
        assertEquals("enhanced", ProcessedText.Enhanced("enhanced").deliverableText)
    }

    @Test
    fun `deliverableText falls back to original on refusal`() {
        assertEquals("hi", ProcessedText.Refused(original = "hi").deliverableText)
    }

    @Test
    fun `deliverableText returns null for empty`() {
        assertNull(ProcessedText.Empty.deliverableText)
    }

    @Test
    fun `equatable`() {
        assertEquals(ProcessedText.Cleaned("a"), ProcessedText.Cleaned("a"))
        assertNotEquals(
            ProcessedText.Cleaned("a") as ProcessedText,
            ProcessedText.Passthrough("a") as ProcessedText,
        )
    }
}
