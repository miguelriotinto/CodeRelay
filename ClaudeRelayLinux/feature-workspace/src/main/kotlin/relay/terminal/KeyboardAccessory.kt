package relay.terminal

import androidx.compose.runtime.Composable

/**
 * Desktop no-op stand-in for the mobile on-screen key bar.
 *
 * On phones this renders Esc / Ctrl / Tab / arrows above the soft keyboard,
 * because a touch keyboard has none of them. A desktop keyboard has all of them
 * as real keys, and `KeyMapping` already routes them to libvterm — so rendering
 * a row of buttons here would be redundant chrome stealing vertical space from
 * the terminal.
 *
 * Declared in `relay.terminal` so the shared `WorkspaceScreen` composes it
 * unchanged rather than being forked over one call site.
 */
@Composable
@Suppress("UNUSED_PARAMETER")
fun KeyboardAccessory(onKey: (ByteArray) -> Unit) {
    // Intentionally empty — see the KDoc.
}
