package relay.feature.workspace

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicNone
import androidx.compose.material.icons.filled.Textsms
import androidx.compose.ui.graphics.Color
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.speech.ContinuousListeningState
import relay.speech.SpeechEngineState

/**
 * Verifies the [MicButton]'s pure state→icon / state→colour / disabled mappings
 * (`effectiveIcon` / `effectiveBackgroundColor` / `isButtonDisabled`) match
 * `MicButton.swift`. The Composable rendering itself is COMPILE-only / device
 * deferred; these functions are pure and assertable on the JVM.
 */
class MicButtonStateTest {

    private val red = Color.Red.copy(alpha = 0.8f)
    private val blue = Color.Blue.copy(alpha = 0.8f)
    private val yellow = Color.Yellow.copy(alpha = 0.8f)
    private val green = Color.Green.copy(alpha = 0.8f)
    private val greyIdle = Color.Gray.copy(alpha = 0.5f)

    // MARK: - Continuous mode colour buckets (blue / red / yellow)

    @Test
    fun `continuous listening is blue`() {
        assertEquals(
            blue,
            effectiveBackgroundColor(true, SpeechEngineState.Idle, ContinuousListeningState.Listening),
        )
        assertEquals(
            blue,
            effectiveBackgroundColor(true, SpeechEngineState.Idle, ContinuousListeningState.DetectingWakeWord),
        )
    }

    @Test
    fun `continuous armed and recording are red`() {
        assertEquals(
            red,
            effectiveBackgroundColor(true, SpeechEngineState.Idle, ContinuousListeningState.Armed),
        )
        assertEquals(
            red,
            effectiveBackgroundColor(true, SpeechEngineState.Idle, ContinuousListeningState.Recording),
        )
        assertEquals(
            red,
            effectiveBackgroundColor(true, SpeechEngineState.Idle, ContinuousListeningState.DetectingTurnEnd),
        )
    }

    @Test
    fun `continuous processing states are yellow`() {
        assertEquals(
            yellow,
            effectiveBackgroundColor(true, SpeechEngineState.Idle, ContinuousListeningState.Transcribing),
        )
        assertEquals(
            yellow,
            effectiveBackgroundColor(true, SpeechEngineState.Idle, ContinuousListeningState.Cleaning),
        )
        assertEquals(
            yellow,
            effectiveBackgroundColor(true, SpeechEngineState.Idle, ContinuousListeningState.Outputting),
        )
    }

    @Test
    fun `continuous idle is grey and error is red`() {
        assertEquals(
            greyIdle,
            effectiveBackgroundColor(true, SpeechEngineState.Idle, ContinuousListeningState.Idle),
        )
        assertEquals(
            red,
            effectiveBackgroundColor(true, SpeechEngineState.Idle, ContinuousListeningState.Error("boom")),
        )
    }

    // MARK: - PTT mode colours (green idle / red recording / yellow processing)

    @Test
    fun `ptt idle is green`() {
        assertEquals(
            green,
            effectiveBackgroundColor(false, SpeechEngineState.Idle, ContinuousListeningState.Idle),
        )
    }

    @Test
    fun `ptt recording is red`() {
        assertEquals(
            red,
            effectiveBackgroundColor(false, SpeechEngineState.Recording, ContinuousListeningState.Idle),
        )
    }

    @Test
    fun `ptt transcribing and cleaning are yellow`() {
        assertEquals(
            yellow,
            effectiveBackgroundColor(false, SpeechEngineState.Transcribing, ContinuousListeningState.Idle),
        )
        assertEquals(
            yellow,
            effectiveBackgroundColor(false, SpeechEngineState.Cleaning, ContinuousListeningState.Idle),
        )
    }

    // MARK: - Icons

    @Test
    fun `ptt icons`() {
        assertEquals(Icons.Filled.MicNone, effectiveIcon(false, SpeechEngineState.Idle, ContinuousListeningState.Idle))
        assertEquals(Icons.Filled.Mic, effectiveIcon(false, SpeechEngineState.Recording, ContinuousListeningState.Idle))
        assertEquals(
            Icons.Filled.GraphicEq,
            effectiveIcon(false, SpeechEngineState.Transcribing, ContinuousListeningState.Idle),
        )
        assertEquals(
            Icons.Filled.AutoAwesome,
            effectiveIcon(false, SpeechEngineState.Cleaning, ContinuousListeningState.Idle),
        )
    }

    @Test
    fun `continuous icons`() {
        assertEquals(
            Icons.Filled.MicNone,
            effectiveIcon(true, SpeechEngineState.Idle, ContinuousListeningState.Idle),
        )
        assertEquals(
            Icons.Filled.GraphicEq,
            effectiveIcon(true, SpeechEngineState.Idle, ContinuousListeningState.Listening),
        )
        assertEquals(
            Icons.Filled.Mic,
            effectiveIcon(true, SpeechEngineState.Idle, ContinuousListeningState.Recording),
        )
        assertEquals(
            Icons.Filled.AutoAwesome,
            effectiveIcon(true, SpeechEngineState.Idle, ContinuousListeningState.Cleaning),
        )
        assertEquals(
            Icons.Filled.Textsms,
            effectiveIcon(true, SpeechEngineState.Idle, ContinuousListeningState.Outputting),
        )
    }

    // MARK: - Disabled gate

    @Test
    fun `disabled while loading transcribing cleaning`() {
        assertTrue(isButtonDisabled(SpeechEngineState.LoadingModel, null))
        assertTrue(isButtonDisabled(SpeechEngineState.Transcribing, null))
        assertTrue(isButtonDisabled(SpeechEngineState.Cleaning, null))
    }

    @Test
    fun `disabled while a download ring is showing`() {
        assertTrue(isButtonDisabled(SpeechEngineState.Idle, 0.4))
    }

    @Test
    fun `enabled when idle and not downloading`() {
        assertFalse(isButtonDisabled(SpeechEngineState.Idle, null))
        assertFalse(isButtonDisabled(SpeechEngineState.Recording, null))
    }
}
