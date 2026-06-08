package relay.feature.settings

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.dp

/**
 * A focusable, zero-size capture control that records a hardware-keyboard
 * modifier + character chord and reports it via [onKeysChanged] / [onCommit].
 *
 * Port of `KeyCaptureView.swift` (UIViewRepresentable). Where iOS overrides
 * `pressesBegan` / `pressesEnded` on a first-responder `UIView`, Compose surfaces
 * the same hardware-key stream through [onPreviewKeyEvent] on a focusable node.
 * When [isCapturing] is true the node requests focus (the `becomeFirstResponder`
 * analog) and intercepts every key event.
 *
 * Capture semantics, faithful to the Swift original:
 *  - On key **down** we union in the pressed [ShortcutFlags] modifiers and, for a
 *    non-modifier character key, record its lowercased label; we report the live
 *    chord via [onKeysChanged] (KeyCaptureView.swift:91-92).
 *  - On key **up**, if no modifier remains held we **commit** — but only if at
 *    least one modifier was actually held, exactly the
 *    `guard !lastFlags.isEmpty` rule (KeyCaptureView.swift:48-54): we call
 *    [onCommit] with the captured flags + key, then end capture. A bare letter
 *    with no modifier never commits.
 *
 * Pure UI glue — compile-verified only; on-device key capture is DEVICE-DEFERRED.
 *
 * @param isCapturing whether to grab focus and intercept keys
 * @param onKeysChanged live chord preview (flags, key) as the user presses
 * @param onCommit fired once with the final (flags, key) when the chord releases
 * @param onCancel fired when capture ends without a committable chord
 */
@Composable
fun KeyCapture(
    isCapturing: Boolean,
    onKeysChanged: (flags: Int, key: String) -> Unit,
    onCommit: (flags: Int, key: String) -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val focusRequester = remember { FocusRequester() }
    // Mutable capture state held across key events for this capture session.
    val state = remember { CaptureState() }

    LaunchedEffect(isCapturing) {
        if (isCapturing) {
            state.reset()
            focusRequester.requestFocus()
        }
    }

    androidx.compose.foundation.layout.Box(
        modifier = modifier
            .size(1.dp)
            .focusRequester(focusRequester)
            .focusable()
            .onPreviewKeyEvent { event ->
                if (!isCapturing) return@onPreviewKeyEvent false
                handleKeyEvent(event, state, onKeysChanged, onCommit, onCancel)
            },
    )
}

/**
 * Per-capture-session mutable state (the iOS `heldModifiers` / `heldKey`). The
 * `last…` fields snapshot the most recent non-empty chord on each key-down so a
 * key-up that zeroes the live held state can still commit the chord that was
 * pressed (the iOS `lastFlags` / `lastKey` the coordinator stashes).
 */
private class CaptureState {
    var heldFlags: Int = 0
    var heldKey: String = ""
    var sawModifier: Boolean = false
    var lastFlags: Int = 0
    var lastKey: String = ""

    fun reset() {
        heldFlags = 0
        heldKey = ""
        sawModifier = false
        lastFlags = 0
        lastKey = ""
    }
}

/**
 * Translates one Compose [KeyEvent] into the capture state transitions described
 * on [KeyCapture]. Returns true when the event was consumed.
 *
 * Extracted as a plain function (not a lambda) for clarity; it touches only the
 * passed-in mutable [state] and the callbacks.
 */
private fun handleKeyEvent(
    event: KeyEvent,
    state: CaptureState,
    onKeysChanged: (Int, String) -> Unit,
    onCommit: (Int, String) -> Unit,
    onCancel: () -> Unit,
): Boolean {
    val native = event.nativeKeyEvent
    val keyCode = native.keyCode

    when (event.type) {
        KeyEventType.KeyDown -> {
            // Current modifier flags from the device meta state.
            val mods = native.metaState and ShortcutFlags.MASK
            if (mods != 0) {
                state.heldFlags = state.heldFlags or mods
                state.sawModifier = true
            }
            if (!isModifierOnlyKey(keyCode)) {
                val label = labelFor(keyCode)
                if (label.isNotEmpty()) state.heldKey = label
            }
            // Snapshot the live chord so a later key-up can commit it after the
            // held state is zeroed (the iOS lastFlags/lastKey stash).
            if (state.heldFlags != 0) {
                state.lastFlags = state.heldFlags
                state.lastKey = state.heldKey
            }
            onKeysChanged(state.heldFlags, state.heldKey)
            return true
        }
        KeyEventType.KeyUp -> {
            // Remaining modifiers still held after this release (the iOS
            // `event.modifierFlags` re-read at KeyCaptureView.swift:113).
            val remaining = native.metaState and ShortcutFlags.MASK
            if (!isModifierOnlyKey(keyCode)) state.heldKey = ""
            state.heldFlags = remaining
            if (remaining == 0 && state.heldKey.isEmpty()) {
                // All keys released. Commit only if a modifier was held at some
                // point (KeyCaptureView.swift:48-54), using the snapshotted chord.
                if (state.sawModifier && state.lastFlags != 0) {
                    onCommit(state.lastFlags, state.lastKey)
                } else {
                    onCancel()
                }
                state.reset()
            } else {
                onKeysChanged(state.heldFlags, state.heldKey)
            }
            return true
        }
        else -> return false
    }
}

/**
 * Whether [keyCode] is a bare modifier key (Shift/Ctrl/Alt/Meta), which produces
 * no character. Mirrors `isModifierOnlyKey` (KeyCaptureView.swift:134-144).
 */
private fun isModifierOnlyKey(keyCode: Int): Boolean = when (keyCode) {
    AndroidKeyEvent.KEYCODE_SHIFT_LEFT, AndroidKeyEvent.KEYCODE_SHIFT_RIGHT,
    AndroidKeyEvent.KEYCODE_CTRL_LEFT, AndroidKeyEvent.KEYCODE_CTRL_RIGHT,
    AndroidKeyEvent.KEYCODE_ALT_LEFT, AndroidKeyEvent.KEYCODE_ALT_RIGHT,
    AndroidKeyEvent.KEYCODE_META_LEFT, AndroidKeyEvent.KEYCODE_META_RIGHT,
    -> true
    else -> false
}

/**
 * Lowercased single-character label for [keyCode], the
 * `charactersIgnoringModifiers.lowercased()` analog. Returns "" for keys with no
 * printable label so the capture ignores them (matching the Swift
 * `!chars.isEmpty` guard).
 */
private fun labelFor(keyCode: Int): String {
    val label = AndroidKeyEvent.keyCodeToString(keyCode)
        .removePrefix("KEYCODE_")
        .lowercase()
    // Single-letter/digit labels (a..z, 0..9) are the useful chord keys; anything
    // longer is a named key we don't surface as a one-char shortcut.
    return if (label.length == 1) label else ""
}
