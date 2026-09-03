package relay.terminal.linux

import androidx.compose.ui.input.key.Key
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * Key → libvterm mapping.
 *
 * The case that matters most is a **bare modifier press**. Compose Desktop wraps
 * AWT, and AWT reports a key carrying no character as `CHAR_UNDEFINED` — which is
 * `0xFFFF`, not `0`. A `codepoint == 0` guard therefore did not catch it, so
 * reaching for Shift on the way to Shift+D dispatched U+FFFF as printable text
 * and the shell echoed a literal `<ffff>` before the D.
 */
class KeyMappingTest {

    private companion object {
        /** What AWT hands over for a key with no character. */
        const val CHAR_UNDEFINED = 0xFFFF
    }

    @Test
    fun `a bare shift press produces no input`() {
        assertEquals(
            KeyMapping.Action.Unhandled,
            KeyMapping.decide(Key.ShiftLeft, CHAR_UNDEFINED, VTermMod.SHIFT),
        )
        assertEquals(
            KeyMapping.Action.Unhandled,
            KeyMapping.decide(Key.ShiftRight, CHAR_UNDEFINED, VTermMod.SHIFT),
        )
    }

    @Test
    fun `the other bare modifiers produce no input either`() {
        val cases = listOf(
            Key.CtrlLeft to VTermMod.CTRL,
            Key.CtrlRight to VTermMod.CTRL,
            Key.AltLeft to VTermMod.ALT,
            Key.MetaLeft to VTermMod.NONE,
            Key.CapsLock to VTermMod.NONE,
            Key.NumLock to VTermMod.NONE,
        )
        for ((key, mods) in cases) {
            assertEquals(
                KeyMapping.Action.Unhandled,
                KeyMapping.decide(key, CHAR_UNDEFINED, mods),
                "$key must not produce input",
            )
        }
    }

    @Test
    fun `shift plus D sends the capital letter, and nothing else`() {
        assertEquals(
            KeyMapping.Action.Character('D'.code, VTermMod.SHIFT),
            KeyMapping.decide(Key.D, 'D'.code, VTermMod.SHIFT),
        )
    }

    @Test
    fun `an unshifted letter sends the letter with no modifiers`() {
        assertEquals(
            KeyMapping.Action.Character('d'.code, VTermMod.NONE),
            KeyMapping.decide(Key.D, 'd'.code, VTermMod.NONE),
        )
    }

    @Test
    fun `a shifted symbol sends the symbol`() {
        assertEquals(
            KeyMapping.Action.Character('$'.code, VTermMod.SHIFT),
            KeyMapping.decide(Key.Four, '$'.code, VTermMod.SHIFT),
        )
    }

    /**
     * Ctrl+C must reach the agent as an interrupt. Some toolkits deliver it
     * pre-folded as codepoint 3; libvterm does the folding itself, so the letter
     * is handed back with CTRL still set rather than folded twice.
     */
    @Test
    fun `ctrl C is handed to libvterm as the letter plus CTRL`() {
        assertEquals(
            KeyMapping.Action.Character('c'.code, VTermMod.CTRL),
            KeyMapping.decide(Key.C, 3, VTermMod.CTRL),
        )
    }

    @Test
    fun `enter and arrows map to special keys, not characters`() {
        assertEquals(
            KeyMapping.Action.SpecialKey(VTermKey.ENTER, VTermMod.NONE),
            KeyMapping.decide(Key.Enter, '\n'.code, VTermMod.NONE),
        )
        assertEquals(
            KeyMapping.Action.SpecialKey(VTermKey.UP, VTermMod.NONE),
            KeyMapping.decide(Key.DirectionUp, CHAR_UNDEFINED, VTermMod.NONE),
        )
        // Shift+Tab still reaches libvterm as a modified special key.
        assertEquals(
            KeyMapping.Action.SpecialKey(VTermKey.TAB, VTermMod.SHIFT),
            KeyMapping.decide(Key.Tab, '\t'.code, VTermMod.SHIFT),
        )
    }

    /**
     * A key with no character that is not in the modifier list — a media key,
     * PrintScreen, a vendor key. The codepoint guard is what covers these.
     */
    @Test
    fun `a non-text key with no character produces no input`() {
        assertEquals(
            KeyMapping.Action.Unhandled,
            KeyMapping.decide(Key.PrintScreen, CHAR_UNDEFINED, VTermMod.NONE),
        )
        assertEquals(
            KeyMapping.Action.Unhandled,
            KeyMapping.decide(Key.MediaPlayPause, 0, VTermMod.NONE),
        )
    }
}
