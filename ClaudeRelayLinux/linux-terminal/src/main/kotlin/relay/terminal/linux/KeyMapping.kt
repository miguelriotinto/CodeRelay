package relay.terminal.linux

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.utf16CodePoint

/**
 * Translates a Compose Desktop [KeyEvent] into something libvterm understands.
 *
 * The division of labour matters: we decide *which* key was pressed, libvterm
 * decides *what bytes* that means. libvterm knows the terminal's current modes —
 * DECCKM application cursor keys, keypad mode, bracketed paste — and emits the
 * sequence the running program actually asked for. Encoding bytes here instead
 * is how the iOS client ended up sending arrow keys that recalled shell history
 * rather than scrolling the agent's transcript.
 */
object KeyMapping {

    /** What to do with a key event. */
    sealed interface Action {
        /** A special key: dispatch as a `VTermKey`. */
        data class SpecialKey(val key: Int, val modifiers: Int) : Action

        /** A printable character: dispatch as a Unicode codepoint. */
        data class Character(val codepoint: Int, val modifiers: Int) : Action

        /** Not ours — let Compose route it (window shortcuts, focus traversal). */
        data object Unhandled : Action
    }

    /** Packs Compose's modifier flags into libvterm's bitmask. */
    fun modifiersOf(event: KeyEvent): Int {
        var mods = VTermMod.NONE
        if (event.isShiftPressed) mods = mods or VTermMod.SHIFT
        if (event.isAltPressed) mods = mods or VTermMod.ALT
        if (event.isCtrlPressed) mods = mods or VTermMod.CTRL
        return mods
    }

    /**
     * Maps a key-down event.
     *
     * `Ctrl+<letter>` is deliberately routed as a **character** with the CTRL
     * modifier, not as a special key: libvterm turns `Ctrl+C` into 0x03 itself.
     * That is also why the app's own shortcuts all use `Ctrl+Shift` or
     * `Ctrl+Alt` — a bare `Ctrl+<key>` belongs to the terminal, and stealing
     * `Ctrl+C` for "copy" would make the agent uninterruptible.
     */
    fun map(event: KeyEvent): Action {
        val mods = modifiersOf(event)

        specialKeyFor(event.key)?.let { return Action.SpecialKey(it, mods) }

        // utf16CodePoint is 0 for pure modifier presses and other non-text keys.
        val codepoint = event.utf16CodePoint
        if (codepoint == 0) return Action.Unhandled

        // Control characters the platform already folded (some toolkits deliver
        // Ctrl+C as codepoint 3). Passing that through with CTRL still set would
        // double-apply the transform, so hand libvterm the letter instead.
        if (mods and VTermMod.CTRL != 0 && codepoint in 1..26) {
            return Action.Character(codepoint + 'a'.code - 1, mods)
        }

        return Action.Character(codepoint, mods)
    }

    /** The non-printable keys, by Compose [Key]. Null means "not special". */
    private fun specialKeyFor(key: Key): Int? = when (key) {
        Key.Enter, Key.NumPadEnter -> VTermKey.ENTER
        Key.Tab -> VTermKey.TAB
        Key.Backspace -> VTermKey.BACKSPACE
        Key.Escape -> VTermKey.ESCAPE

        Key.DirectionUp -> VTermKey.UP
        Key.DirectionDown -> VTermKey.DOWN
        Key.DirectionLeft -> VTermKey.LEFT
        Key.DirectionRight -> VTermKey.RIGHT

        Key.Insert -> VTermKey.INS
        Key.Delete -> VTermKey.DEL
        Key.MoveHome -> VTermKey.HOME
        Key.MoveEnd -> VTermKey.END
        Key.PageUp -> VTermKey.PAGEUP
        Key.PageDown -> VTermKey.PAGEDOWN

        Key.F1 -> VTermKey.function(1)
        Key.F2 -> VTermKey.function(2)
        Key.F3 -> VTermKey.function(3)
        Key.F4 -> VTermKey.function(4)
        Key.F5 -> VTermKey.function(5)
        Key.F6 -> VTermKey.function(6)
        Key.F7 -> VTermKey.function(7)
        Key.F8 -> VTermKey.function(8)
        Key.F9 -> VTermKey.function(9)
        Key.F10 -> VTermKey.function(10)
        Key.F11 -> VTermKey.function(11)
        Key.F12 -> VTermKey.function(12)

        else -> null
    }

    /**
     * True when this event is an application shortcut the terminal must not
     * swallow.
     *
     * Every CodeRelay accelerator is `Ctrl+Shift+…` or `Ctrl+Alt+…` precisely so
     * this predicate can be simple and never collide with terminal input.
     */
    fun isApplicationShortcut(event: KeyEvent): Boolean =
        event.isCtrlPressed && (event.isShiftPressed || event.isAltPressed)
}
