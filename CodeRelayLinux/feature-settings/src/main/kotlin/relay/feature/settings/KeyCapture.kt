package relay.feature.settings

import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.utf16CodePoint
import androidx.compose.ui.unit.dp

/**
 * A zero-size focusable control that records a modifier+key chord while
 * [isCapturing], for the recording-shortcut setting.
 *
 * Linux counterpart of the Android `KeyCapture`, which reads
 * `android.view.KeyEvent` meta bits. Same signature, so the shared
 * `SettingsScreen` composes it unchanged.
 *
 * The flags produced here use [ShortcutFlags]' constants — Android's `META_*`
 * values, not AWT's — because the result is *persisted* and must mean the same
 * chord when read by any client.
 *
 * @param onKeysChanged live preview as the user holds modifiers down
 * @param onCommit fired when a non-modifier key completes the chord
 * @param onCancel fired on Escape, or when capture is abandoned
 */
@Composable
fun KeyCapture(
    isCapturing: Boolean,
    onKeysChanged: (Int, String) -> Unit,
    onCommit: (Int, String) -> Unit,
    onCancel: () -> Unit,
) {
    val focusRequester = remember { FocusRequester() }

    // Grab focus when capture starts so the next keypress lands here rather
    // than in whatever field the user was last editing.
    LaunchedEffect(isCapturing) {
        if (isCapturing) {
            runCatching { focusRequester.requestFocus() }
        }
    }

    Box(
        Modifier
            .size(0.dp)
            .focusRequester(focusRequester)
            .focusable()
            .onKeyEvent { event ->
                if (!isCapturing) return@onKeyEvent false

                val flags = flagsOf(event.isCtrlPressed, event.isAltPressed, event.isShiftPressed, event.isMetaPressed)

                if (event.type == KeyEventType.KeyUp) {
                    // A modifier release while still capturing just updates the
                    // preview; the chord is not complete until a real key lands.
                    onKeysChanged(flags, "")
                    return@onKeyEvent true
                }
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false

                if (event.key == Key.Escape) {
                    onCancel()
                    return@onKeyEvent true
                }

                if (isModifier(event.key)) {
                    // Modifiers alone are a partial chord — show them, wait.
                    onKeysChanged(flags, "")
                    return@onKeyEvent true
                }

                val label = labelFor(event.key, event.utf16CodePoint)
                if (label.isEmpty()) return@onKeyEvent true

                onCommit(flags, label)
                true
            },
    )
}

/** Packs Compose's modifier state into the persisted [ShortcutFlags] bitmask. */
private fun flagsOf(ctrl: Boolean, alt: Boolean, shift: Boolean, meta: Boolean): Int {
    var flags = 0
    if (ctrl) flags = flags or ShortcutFlags.CTRL
    if (alt) flags = flags or ShortcutFlags.ALT
    if (shift) flags = flags or ShortcutFlags.SHIFT
    if (meta) flags = flags or ShortcutFlags.META
    return flags
}

/**
 * Modifier keys never complete a chord on their own.
 *
 * Compose reports left and right variants as distinct [Key]s, so both must be
 * listed — omitting the right-hand ones would let a user "commit" a shortcut of
 * Right-Shift alone, which no key handler could ever match.
 */
private fun isModifier(key: Key): Boolean = key in setOf(
    Key.CtrlLeft, Key.CtrlRight,
    Key.AltLeft, Key.AltRight,
    Key.ShiftLeft, Key.ShiftRight,
    Key.MetaLeft, Key.MetaRight,
)

/**
 * Display label for the committed key, matching Android's uppercase single
 * character where possible and falling back to the key's own name.
 */
private fun labelFor(key: Key, codePoint: Int): String {
    if (codePoint != 0) {
        val ch = codePoint.toChar()
        if (ch.isLetterOrDigit()) return ch.uppercaseChar().toString()
    }
    return when (key) {
        Key.Spacebar -> "Space"
        Key.Enter -> "Return"
        Key.Tab -> "Tab"
        Key.Backspace -> "Delete"
        Key.DirectionUp -> "Up"
        Key.DirectionDown -> "Down"
        Key.DirectionLeft -> "Left"
        Key.DirectionRight -> "Right"
        else -> ""
    }
}
