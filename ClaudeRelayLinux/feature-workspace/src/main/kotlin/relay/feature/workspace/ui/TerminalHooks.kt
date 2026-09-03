package relay.feature.workspace.ui

import androidx.compose.runtime.compositionLocalOf

/**
 * What the desktop terminal host needs from the app that the shared
 * `WorkspaceScreen` cannot pass it.
 *
 * `WorkspaceScreen` is compiled verbatim from the Android sources and calls
 * `TerminalHost(vm, onInput, onResize, redrawToken, modifier)` — nothing else.
 * Everything a desktop terminal does beyond that (clipboard, title, paste,
 * zoom, scrollback size) therefore arrives ambiently, the same way
 * `LocalTerminalTheme` carries the palette. One value, provided once by `:app`.
 *
 * Every member has a no-op default so a preview or a test composes without
 * wiring anything.
 */
data class TerminalHooks(
    /** OSC 52 write from the host — tmux/vim/kitty copied something. */
    val onClipboardCopy: (text: String) -> Unit = {},
    /** OSC 0/2 window title from the host. */
    val onTitleChange: (title: String) -> Unit = {},
    /** BEL. */
    val onBell: () -> Unit = {},
    /** Device → host image paste (PNG bytes), the `paste_image` message. */
    val sendPasteImage: (png: ByteArray) -> Unit = {},
    /** Lines of local scrollback to retain in the normal screen. */
    val scrollbackLines: Int = 5_000,
    /**
     * Font size in points when the user has set one in Settings, else null
     * to follow the desktop's own terminal config.
     */
    val fontPointsOverride: Float? = null,
    /**
     * Paste requests from the app's accelerator, as a monotonic counter: the
     * host reads the clipboard and dispatches the text when it changes.
     */
    val pasteRequest: Int = 0,
    /** Copy requests from the app's accelerator, likewise a counter. */
    val copyRequest: Int = 0,
    /** Reports the terminal's current selection text (null = none) for the copy chord. */
    val onSelectionCopied: (text: String) -> Unit = {},
    /** The system clipboard; one instance shared by the app and every host. */
    val clipboard: relay.platform.DesktopClipboard = relay.platform.DesktopClipboard(),
)

/**
 * Ambient desktop hooks; `:app` provides the real ones.
 *
 * A dynamic (not static) local on purpose: the paste/copy counters change on
 * every chord, and a static local would recompose every reader below the
 * provider — the whole workspace — instead of only the terminal host.
 */
val LocalTerminalHooks = compositionLocalOf { TerminalHooks() }
