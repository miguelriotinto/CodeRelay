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
    fun map(event: KeyEvent): Action =
        decide(event.key, event.utf16CodePoint, modifiersOf(event))

    /**
     * The mapping decision, as pure data.
     *
     * Split from [map] so it can be tested directly: Compose Desktop's
     * `KeyEvent` wraps an internal skiko type that a unit test cannot
     * construct, and the interesting behaviour here is all in these three
     * values.
     */
    internal fun decide(key: Key, codepoint: Int, mods: Int): Action {
        specialKeyFor(key)?.let { return Action.SpecialKey(it, mods) }

        // A modifier is not text. Compose Desktop wraps AWT, and AWT reports a
        // key with no character as CHAR_UNDEFINED — which is `0xFFFF`, NOT 0.
        // So pressing Shift on its way to Shift+D dispatched U+FFFF as a
        // printable character and zsh echoed a literal `<ffff>` before the D.
        // Both guards stay: the key list says what we mean, and the codepoint
        // check catches every other key AWT hands us with no character (media
        // keys, Super, PrintScreen).
        if (key in MODIFIER_KEYS) return Action.Unhandled
        if (codepoint == 0 || codepoint == CHAR_UNDEFINED) return Action.Unhandled

        // Control characters the platform already folded (some toolkits deliver
        // Ctrl+C as codepoint 3). Passing that through with CTRL still set would
        // double-apply the transform, so hand libvterm the letter instead.
        if (mods and VTermMod.CTRL != 0 && codepoint in 1..26) {
            return Action.Character(codepoint + 'a'.code - 1, mods)
        }

        return Action.Character(codepoint, mods)
    }

    /**
     * A *typed* character event (AWT `KEY_TYPED`, which Compose Desktop surfaces
     * with [KeyEventType.Unknown]) — the only way a dead-key or Compose-key
     * sequence (`´` then `e` → `é`, Compose+`o`+`c` → `©`) ever produces text:
     * the presses themselves arrive with `CHAR_UNDEFINED` and map to nothing.
     *
     * The guard against double input: an ordinary key already dispatched on
     * its KeyDown, and its KEY_TYPED must be dropped. So a typed character is
     * dispatched only when the key-down that preceded it was [Action.Unhandled]
     * — which is exactly the dead-key case. Controls and modified chords never
     * come this way (they were handled on KeyDown or belong to the app).
     */
    fun typed(event: KeyEvent, lastKeyDownHandled: Boolean): Action =
        decideTyped(event.utf16CodePoint, lastKeyDownHandled, modifiersOf(event))

    /** Pure form of [typed]; see [decide]. */
    internal fun decideTyped(codepoint: Int, lastKeyDownHandled: Boolean, mods: Int): Action {
        if (lastKeyDownHandled) return Action.Unhandled
        if (mods and (VTermMod.CTRL or VTermMod.ALT) != 0) return Action.Unhandled
        if (codepoint < 0x20 || codepoint == 0x7F || codepoint == CHAR_UNDEFINED) return Action.Unhandled
        return Action.Character(codepoint, VTermMod.NONE)
    }

    /**
     * AWT's `KeyEvent.CHAR_UNDEFINED`, which Compose Desktop passes straight
     * through as [KeyEvent.utf16CodePoint] for any key that carries no
     * character. It is `0xFFFF`, not `0`, which is exactly why the old
     * `codepoint == 0` guard let modifier presses through.
     */
    private const val CHAR_UNDEFINED = 0xFFFF

    /** Keys that are modifiers in their own right and never produce text. */
    private val MODIFIER_KEYS = setOf(
        Key.ShiftLeft, Key.ShiftRight,
        Key.CtrlLeft, Key.CtrlRight,
        Key.AltLeft, Key.AltRight,
        Key.MetaLeft, Key.MetaRight,
        Key.CapsLock, Key.NumLock, Key.ScrollLock,
        Key.Function,
    )

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
