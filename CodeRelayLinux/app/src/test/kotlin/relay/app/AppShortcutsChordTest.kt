package relay.app

import androidx.compose.ui.input.key.Key
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

/** The chords added for settings, zoom, copy, paste and the prompt-optimizer wand. */
class AppShortcutsChordTest {

    private fun ctrlShift(key: Key) = AppShortcut.resolve(key, ctrl = true, shift = true, alt = false)

    @Test
    fun `ctrl shift comma opens settings`() {
        assertEquals(AppShortcut.OPEN_SETTINGS, ctrlShift(Key.Comma))
    }

    @Test
    fun `zoom chords`() {
        assertEquals(AppShortcut.ZOOM_IN, ctrlShift(Key.Equals))
        assertEquals(AppShortcut.ZOOM_IN, ctrlShift(Key.Plus))
        assertEquals(AppShortcut.ZOOM_OUT, ctrlShift(Key.Minus))
        assertEquals(AppShortcut.ZOOM_RESET, ctrlShift(Key.Zero))
    }

    @Test
    fun `copy and paste are the terminal-world chords`() {
        assertEquals(AppShortcut.COPY, ctrlShift(Key.C))
        assertEquals(AppShortcut.PASTE, ctrlShift(Key.V))
    }

    @Test
    fun `bare ctrl C and ctrl V still belong to the terminal`() {
        assertNull(AppShortcut.resolve(Key.C, ctrl = true, shift = false, alt = false))
        assertNull(AppShortcut.resolve(Key.V, ctrl = true, shift = false, alt = false))
    }

    @Test
    fun `ctrl shift zero is zoom reset, not session switching`() {
        assertNull(AppShortcut.sessionIndex(Key.Zero, ctrl = true, alt = true))
        assertEquals(AppShortcut.ZOOM_RESET, ctrlShift(Key.Zero))
    }

    @Test
    fun `ctrl shift O triggers the prompt optimizer wand`() {
        assertEquals(AppShortcut.OPTIMIZE_PROMPT, ctrlShift(Key.O))
    }

    /**
     * Bare Ctrl+O is terminal input (nano's write-out, readline's operate-and-
     * get-next); it must never resolve to an app command. See the class doc on
     * [AppShortcut] for the rule.
     */
    @Test
    fun `bare ctrl O still belongs to the terminal`() {
        assertNull(AppShortcut.resolve(Key.O, ctrl = true, shift = false, alt = false))
    }

    /** Ctrl+Alt is the session-switching family; O is not bound there. */
    @Test
    fun `ctrl alt O is not a shortcut`() {
        assertNull(AppShortcut.resolve(Key.O, ctrl = true, shift = false, alt = true))
    }
}
