package relay.platform

import java.io.File

/**
 * Reads the active Omarchy theme and maps it onto the terminal's 16-colour ANSI
 * palette, so CodeRelay is themed with the rest of the desktop the way Alacritty
 * and Foot are.
 *
 * Omarchy publishes the live palette at a stable path:
 *
 * ```
 * ~/.local/state/omarchy/current/theme/colors.toml   # active palette
 * ~/.local/state/omarchy/current/theme.name          # slug, e.g. "tokyo-night"
 * ```
 *
 * Verified against all 22 stock themes: every one defines the same 24 core keys.
 * `orange` and `brown` appear in 19 of 22 and are therefore treated as optional.
 *
 * **Nothing here is required.** On a plain Arch box, another distro, or a
 * Hyprland setup without Omarchy, the paths simply do not exist and every entry
 * point returns null so the caller keeps `TerminalPalette`'s built-in defaults.
 * A missing or malformed theme must never be fatal — the app's job is terminal
 * sessions, not theming.
 */
object OmarchyTheme {

    /** Where Omarchy records the active theme. Overridable for tests. */
    internal var stateDir: File =
        File(System.getProperty("user.home"), ".local/state/omarchy/current")

    /** Whether the theme is meant to be read on a light or dark ground. */
    enum class Mode { LIGHT, DARK }

    /**
     * A resolved Omarchy palette.
     *
     * [ansi] is 16 packed ARGB ints in xterm order (0–7 basic, 8–15 bright),
     * directly installable via termlib's `nativeSetPaletteColors`. [background]
     * and [foreground] feed `nativeSetDefaultColors`. [accent] and [selection]
     * theme the app chrome around the terminal.
     */
    data class Palette(
        val name: String,
        val mode: Mode,
        val ansi: IntArray,
        val background: Int,
        val foreground: Int,
        val accent: Int,
        val selection: Int,
    ) {
        // IntArray gives reference equality from the data class, which would make
        // "did the theme change?" always answer yes and repaint on every poll.
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Palette) return false
            return name == other.name && mode == other.mode &&
                ansi.contentEquals(other.ansi) && background == other.background &&
                foreground == other.foreground && accent == other.accent &&
                selection == other.selection
        }

        override fun hashCode(): Int {
            var result = name.hashCode()
            result = 31 * result + mode.hashCode()
            result = 31 * result + ansi.contentHashCode()
            result = 31 * result + background
            result = 31 * result + foreground
            result = 31 * result + accent
            result = 31 * result + selection
            return result
        }
    }

    /** The file whose mtime changes when the user switches theme. */
    val colorsFile: File get() = File(stateDir, "theme/colors.toml")

    private val nameFile: File get() = File(stateDir, "theme.name")

    /** True when this looks like an Omarchy (or Omarchy-like) desktop. */
    fun isAvailable(): Boolean = colorsFile.isFile

    /**
     * Loads the active palette, or null when Omarchy is absent or the file
     * cannot be understood.
     *
     * A theme missing colours we need is rejected wholesale rather than
     * part-filled: a palette with three real colours and thirteen defaults looks
     * far more broken than the honest built-in palette does.
     */
    fun load(): Palette? {
        val file = colorsFile
        if (!file.isFile) return null
        val raw = runCatching { file.readText() }.getOrNull() ?: return null
        val values = parse(raw)

        fun color(key: String): Int? = values[key]?.let(::parseHexColor)

        val background = color("background") ?: return null
        val foreground = color("foreground") ?: return null

        // Omarchy defines no bright_black or bright_white. `muted` is the
        // dimmed-text colour every theme carries, which is exactly what ANSI 8
        // is used for; `bright_foreground` is the emphasised text colour, which
        // is ANSI 15. Substituting these keeps dim/bold text legible instead of
        // collapsing it into the background.
        val black = color("dark_background") ?: background
        val brightBlack = color("muted") ?: return null
        val white = foreground
        val brightWhite = color("bright_foreground") ?: foreground

        val ansi = intArrayOf(
            black,
            color("red") ?: return null,
            color("green") ?: return null,
            color("yellow") ?: return null,
            color("blue") ?: return null,
            color("magenta") ?: return null,
            color("cyan") ?: return null,
            white,
            brightBlack,
            color("bright_red") ?: return null,
            color("bright_green") ?: return null,
            color("bright_yellow") ?: return null,
            color("bright_blue") ?: return null,
            color("bright_magenta") ?: return null,
            color("bright_cyan") ?: return null,
            brightWhite,
        )

        return Palette(
            name = runCatching { nameFile.readText().trim() }.getOrNull()
                ?.takeIf { it.isNotEmpty() } ?: "omarchy",
            mode = if (values["mode"]?.equals("light", ignoreCase = true) == true) Mode.LIGHT else Mode.DARK,
            ansi = ansi,
            background = background,
            foreground = foreground,
            accent = color("accent") ?: foreground,
            selection = color("selection") ?: brightBlack,
        )
    }

    /**
     * Minimal reader for the flat `key = "value"` subset Omarchy's `colors.toml`
     * uses. No TOML library: the format here has no tables, arrays, multi-line
     * strings, or nesting, and taking a parser dependency to read 24 key-value
     * pairs would be the larger risk.
     *
     * Unknown keys are kept (harmless); anything unparseable is skipped rather
     * than aborting, so a theme that adds a new exotic line still loads.
     */
    internal fun parse(text: String): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for (line in text.lineSequence()) {
            val trimmed = line.trim()
            if (trimmed.isEmpty() || trimmed.startsWith("#")) continue
            val eq = trimmed.indexOf('=')
            if (eq <= 0) continue
            val key = trimmed.substring(0, eq).trim()
            if (key.isEmpty()) continue
            var value = trimmed.substring(eq + 1).trim()
            // Strip a trailing comment only when the value is not quoted, so a
            // '#' inside "#7aa2f7" survives.
            if (!value.startsWith("\"") && !value.startsWith("'")) {
                val hash = value.indexOf('#')
                if (hash >= 0) value = value.substring(0, hash).trim()
            }
            value = value.removeSurrounding("\"").removeSurrounding("'")
            out[key] = value
        }
        return out
    }

    /**
     * Parses `#rrggbb` (and tolerates `#rgb` and `#aarrggbb`) into a packed
     * opaque ARGB int, matching `TerminalPalette`'s representation.
     */
    internal fun parseHexColor(value: String): Int? {
        val hex = value.trim().removePrefix("#")
        val rgb = when (hex.length) {
            3 -> hex.map { "$it$it" }.joinToString("")
            6 -> hex
            // Some themes may carry alpha; the terminal palette is always opaque,
            // so drop it rather than reject the theme.
            8 -> hex.substring(2)
            else -> return null
        }
        val parsed = runCatching { rgb.toLong(16) }.getOrNull() ?: return null
        return (0xFF shl 24) or (parsed.toInt() and 0xFFFFFF)
    }
}
