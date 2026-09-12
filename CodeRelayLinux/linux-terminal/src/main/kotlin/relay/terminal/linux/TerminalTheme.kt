package relay.terminal.linux

import androidx.compose.runtime.staticCompositionLocalOf
import relay.terminal.TerminalPalette

/**
 * The colours the terminal grid renders with: the 16-entry ANSI palette plus the
 * default foreground and background, all as opaque packed ARGB.
 *
 * ### Why this is a CompositionLocal
 *
 * `WorkspaceScreen` is shared verbatim with Android and calls `TerminalHost`
 * with no colour arguments at all, so there is no parameter to thread a palette
 * through without forking ~800 lines of shared UI. An ambient value lets `:app`
 * — which already loads the Omarchy theme once into `AppEnvironment` — publish it
 * for the terminal to pick up, with a single source of truth and no duplicate
 * read of `colors.toml`.
 *
 * The default is [TerminalPalette]'s built-in scheme, which is what a plain Arch
 * box or another distro gets: Omarchy's state directory simply isn't there, and
 * the terminal still renders in sensible colours.
 */
data class TerminalTheme(
    /** 16 packed ARGB ints in xterm order: 0–7 basic, 8–15 bright. */
    val ansi: IntArray,
    val foreground: Int,
    val background: Int,
    /**
     * Selection highlight, packed ARGB. Omarchy themes carry one (`selection`);
     * null means "derive from the foreground", which the renderer does with a
     * translucent fill so it reads on any background.
     */
    val selection: Int? = null,
) {
    // IntArray has identity equals; a data class holding one needs both written
    // out or `remember(theme)` would re-fire on every recomposition.
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TerminalTheme) return false
        return foreground == other.foreground &&
            background == other.background &&
            selection == other.selection &&
            ansi.contentEquals(other.ansi)
    }

    override fun hashCode(): Int =
        ((ansi.contentHashCode() * 31 + foreground) * 31 + background) * 31 + (selection ?: 0)

    companion object {
        /** The built-in scheme, used wherever no desktop theme is published. */
        val Default = TerminalTheme(
            ansi = TerminalPalette.colors,
            foreground = TerminalPalette.foreground,
            background = TerminalPalette.background,
        )
    }
}

/** Ambient terminal colours; `:app` provides the live Omarchy palette. */
val LocalTerminalTheme = staticCompositionLocalOf { TerminalTheme.Default }
