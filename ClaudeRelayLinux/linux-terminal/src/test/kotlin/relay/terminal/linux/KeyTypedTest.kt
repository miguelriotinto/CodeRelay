package relay.terminal.linux

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * Typed-character events (AWT `KEY_TYPED`), the path dead keys and Compose
 * sequences take. The rule under test: dispatch only when the key-down that
 * preceded it mapped to nothing, so an ordinary key is never typed twice.
 */
class KeyTypedTest {

    @Test
    fun `a composed character after an unhandled key-down is typed`() {
        // `´` (dead key: KeyDown with CHAR_UNDEFINED → Unhandled) then `e` → KEY_TYPED 'é'.
        assertEquals(
            KeyMapping.Action.Character('é'.code, VTermMod.NONE),
            KeyMapping.decideTyped('é'.code, lastKeyDownHandled = false, mods = VTermMod.NONE),
        )
    }

    @Test
    fun `a typed event after a handled key-down is dropped, or 'a' would be typed twice`() {
        assertEquals(
            KeyMapping.Action.Unhandled,
            KeyMapping.decideTyped('a'.code, lastKeyDownHandled = true, mods = VTermMod.NONE),
        )
    }

    @Test
    fun `controls and undefined characters never come through the typed path`() {
        assertEquals(KeyMapping.Action.Unhandled, KeyMapping.decideTyped(0x03, false, VTermMod.NONE))
        assertEquals(KeyMapping.Action.Unhandled, KeyMapping.decideTyped(0x7F, false, VTermMod.NONE))
        assertEquals(KeyMapping.Action.Unhandled, KeyMapping.decideTyped(0xFFFF, false, VTermMod.NONE))
    }

    @Test
    fun `a chord with ctrl or alt is not text`() {
        assertEquals(KeyMapping.Action.Unhandled, KeyMapping.decideTyped('c'.code, false, VTermMod.CTRL))
        assertEquals(KeyMapping.Action.Unhandled, KeyMapping.decideTyped('x'.code, false, VTermMod.ALT))
    }

    @Test
    fun `shift alone is fine, it is how uppercase and AltGr-free symbols arrive`() {
        assertEquals(
            KeyMapping.Action.Character('É'.code, VTermMod.NONE),
            KeyMapping.decideTyped('É'.code, false, VTermMod.SHIFT),
        )
    }

    // The KeyDown side of the same story: the dead key itself maps to nothing.

    @Test
    fun `a dead-key press with CHAR_UNDEFINED maps to nothing on key-down`() {
        assertEquals(
            KeyMapping.Action.Unhandled,
            KeyMapping.decide(androidx.compose.ui.input.key.Key.Unknown, 0xFFFF, VTermMod.NONE),
        )
    }

    @Test
    fun `ctrl space and ctrl bracket reach the terminal as modified characters`() {
        assertEquals(
            KeyMapping.Action.Character(' '.code, VTermMod.CTRL),
            KeyMapping.decide(androidx.compose.ui.input.key.Key.Spacebar, ' '.code, VTermMod.CTRL),
        )
        assertEquals(
            KeyMapping.Action.Character('['.code, VTermMod.CTRL),
            KeyMapping.decide(androidx.compose.ui.input.key.Key.LeftBracket, '['.code, VTermMod.CTRL),
        )
    }

    @Test
    fun `numpad digits are plain characters`() {
        assertEquals(
            KeyMapping.Action.Character('7'.code, VTermMod.NONE),
            KeyMapping.decide(androidx.compose.ui.input.key.Key.NumPad7, '7'.code, VTermMod.NONE),
        )
    }
}
