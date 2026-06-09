package relay.speech

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Mirrors `Tests/ClaudeRelaySpeechTests/ContinuousListeningStateTests.swift`,
 * plus color-bucket coverage required for the Android UI.
 */
class ContinuousListeningStateTest {

    // MARK: - isActive / isCapturing / isArmed (ported from Swift)

    @Test
    fun `isActive is false for idle`() {
        assertFalse(ContinuousListeningState.Idle.isActive)
    }

    @Test
    fun `isActive is true for listening`() {
        assertTrue(ContinuousListeningState.Listening.isActive)
    }

    @Test
    fun `isActive is true for recording`() {
        assertTrue(ContinuousListeningState.Recording.isActive)
    }

    @Test
    fun `isActive is false for error`() {
        assertFalse(ContinuousListeningState.Error("boom").isActive)
    }

    @Test
    fun `isCapturing is true for recording`() {
        assertTrue(ContinuousListeningState.Recording.isCapturing)
    }

    @Test
    fun `isCapturing is true for detectingTurnEnd`() {
        assertTrue(ContinuousListeningState.DetectingTurnEnd.isCapturing)
    }

    @Test
    fun `isCapturing is false for listening`() {
        assertFalse(ContinuousListeningState.Listening.isCapturing)
    }

    @Test
    fun `isArmed buckets`() {
        assertTrue(ContinuousListeningState.Armed.isArmed)
        assertTrue(ContinuousListeningState.Recording.isArmed)
        assertTrue(ContinuousListeningState.DetectingTurnEnd.isArmed)
        assertFalse(ContinuousListeningState.Listening.isArmed)
        assertFalse(ContinuousListeningState.DetectingWakeWord.isArmed)
        assertFalse(ContinuousListeningState.Transcribing.isArmed)
    }

    @Test
    fun `armed is active but not capturing`() {
        assertTrue(ContinuousListeningState.Armed.isActive)
        assertFalse(ContinuousListeningState.Armed.isCapturing)
    }

    @Test
    fun `error equality`() {
        assertEquals(ContinuousListeningState.Error("fail"), ContinuousListeningState.Error("fail"))
        assertNotEquals(ContinuousListeningState.Error("a"), ContinuousListeningState.Error("b"))
    }

    // MARK: - Color buckets

    @Test
    fun `blue bucket for listening and detectingWakeWord`() {
        assertEquals(ListeningColor.BLUE, ContinuousListeningState.Listening.color)
        assertEquals(ListeningColor.BLUE, ContinuousListeningState.DetectingWakeWord.color)
    }

    @Test
    fun `red bucket for armed, recording, detectingTurnEnd`() {
        assertEquals(ListeningColor.RED, ContinuousListeningState.Armed.color)
        assertEquals(ListeningColor.RED, ContinuousListeningState.Recording.color)
        assertEquals(ListeningColor.RED, ContinuousListeningState.DetectingTurnEnd.color)
    }

    @Test
    fun `yellow bucket for transcribing, cleaning, outputting`() {
        assertEquals(ListeningColor.YELLOW, ContinuousListeningState.Transcribing.color)
        assertEquals(ListeningColor.YELLOW, ContinuousListeningState.Cleaning.color)
        assertEquals(ListeningColor.YELLOW, ContinuousListeningState.Outputting.color)
    }

    @Test
    fun `idle and error have no color bucket`() {
        assertNull(ContinuousListeningState.Idle.color)
        assertNull(ContinuousListeningState.Error("x").color)
    }

    @Test
    fun `description is human readable`() {
        assertEquals("Idle", ContinuousListeningState.Idle.description)
        assertEquals("Ready", ContinuousListeningState.Armed.description)
        assertEquals("Recording", ContinuousListeningState.Recording.description)
        assertEquals("Error: nope", ContinuousListeningState.Error("nope").description)
    }
}
