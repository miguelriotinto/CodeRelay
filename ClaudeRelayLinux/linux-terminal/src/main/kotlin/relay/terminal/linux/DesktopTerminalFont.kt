package relay.terminal.linux

import androidx.compose.ui.text.font.FontFamily
import java.io.File

/**
 * The terminal font the rest of this desktop is already using.
 *
 * CodeRelay's grid sits next to the user's Foot / Alacritty windows, and a
 * relayed session that renders two points larger than the local shell reads as
 * a different application rather than another terminal. So the size and family
 * are read from the same config files those terminals read, in the same spirit
 * as [OmarchyTheme][relay.platform.OmarchyTheme] reading the live palette.
 *
 * Foot is consulted first (Omarchy's own default terminal), then Alacritty. On a
 * machine with neither, [DEFAULT] is Omarchy's stock 9 pt — and if that is wrong
 * for the box, it is wrong by a point, not by a factor.
 *
 * ### Points, not pixels
 *
 * Both terminals express size in **typographic points**, which is what makes
 * this comparable at all: a point is 1/72 inch, and a desktop's logical inch is
 * 96 px, so `points * 96 / 72` is the size in density-independent pixels. Compose
 * then multiplies by the window's density (2.0 on this HiDPI panel), landing on
 * exactly the device pixels Foot computes for the same value. Hard-coding the
 * pixel size instead would break the moment the window moved to a 1x display.
 */
object DesktopTerminalFont {

    /**
     * A resolved terminal look: family (null = whatever fontconfig calls
     * monospace), size in points, and the window padding those terminals leave
     * between the frame and the first cell.
     */
    data class Spec(val family: String?, val points: Float, val padDp: Float = DEFAULT_PAD) {
        /** Size in density-independent pixels, for `TextUnit`. */
        val sizeDp: Float get() = points * 96f / 72f
    }

    /** Foot's own default padding, in dp — used when no config names one. */
    const val DEFAULT_PAD = 2f

    /** Omarchy's stock terminal size, used when no config names one. */
    val DEFAULT = Spec(family = null, points = 9f)

    /** `~/.config`. Overridable for tests. */
    internal var configDir: File = File(System.getProperty("user.home"), ".config")

    /** Reads Foot's config, then Alacritty's, then falls back to [DEFAULT]. */
    fun load(): Spec =
        readConfig("foot/foot.ini", ::parseFoot)
            ?: readConfig("alacritty/alacritty.toml", ::parseAlacritty)
            ?: DEFAULT

    private fun readConfig(relativePath: String, parse: (String) -> Spec?): Spec? {
        val file = File(configDir, relativePath)
        if (!file.isFile) return null
        return runCatching { parse(file.readText()) }.getOrNull()
    }

    /**
     * Parses Foot's `font=JetBrainsMono Nerd Font:size=9` (the family is
     * everything before the first `:`, options follow as `key=value`).
     *
     * Foot accepts a comma-separated fallback list; only the first entry is the
     * primary face, and that is the one whose metrics set the cell.
     */
    internal fun parseFoot(text: String): Spec? {
        val line = text.lineSequence()
            .map { it.trim() }
            .firstOrNull { it.startsWith("font=") && !it.startsWith("#") }
            ?: return null
        val value = line.removePrefix("font=").substringBefore(",").trim()
        if (value.isEmpty()) return null
        val parts = value.split(":")
        val family = parts.first().trim().takeIf { it.isNotEmpty() }
        val points = parts.drop(1)
            .firstNotNullOfOrNull { option ->
                option.trim().removePrefix("size=").takeIf { it != option.trim() }?.toFloatOrNull()
            }
            ?: DEFAULT.points
        return Spec(family, points, padOf(text))
    }

    /**
     * Parses Alacritty's `[font]` table: `size = 9` plus
     * `normal = { family = "JetBrainsMono Nerd Font", ... }`.
     *
     * Deliberately a line scan rather than a TOML parser — two keys are needed,
     * and a dependency to read them would outweigh the feature.
     */
    internal fun parseAlacritty(text: String): Spec? {
        var inFontTable = false
        var inWindowTable = false
        var family: String? = null
        var points: Float? = null
        var padding: Float? = null
        for (raw in text.lineSequence()) {
            val line = raw.trim()
            if (line.startsWith("#")) continue
            if (line.startsWith("[")) {
                inFontTable = line.startsWith("[font")
                inWindowTable = line.startsWith("[window")
                continue
            }
            if (inWindowTable && padding == null && line.startsWith("padding")) {
                padding = Regex("""x\s*=\s*(\d+(?:\.\d+)?)""").find(line)?.groupValues?.get(1)?.toFloatOrNull()
            }
            if (!inFontTable) continue
            if (family == null && line.startsWith("normal")) {
                family = Regex("""family\s*=\s*"([^"]+)"""").find(line)?.groupValues?.get(1)
            }
            if (points == null && line.startsWith("size")) {
                points = line.substringAfter("=").trim().toFloatOrNull()
            }
        }
        if (family == null && points == null) return null
        return Spec(family, points ?: DEFAULT.points, padding ?: DEFAULT_PAD)
    }

    /**
     * Foot's `pad=14x14 [center]`, in dp.
     *
     * Foot scales its padding by the display scale exactly as it scales the
     * font, so the configured number is density-independent — the same thing dp
     * means — and needs no conversion. Only the horizontal value is kept: the
     * grid is inset equally on all four sides, which is what Foot does when x
     * and y match, and they do in every stock config.
     */
    internal fun padOf(text: String): Float {
        val line = text.lineSequence()
            .map { it.trim() }
            .firstOrNull { it.startsWith("pad=") && !it.startsWith("#") }
            ?: return DEFAULT_PAD
        val value = line.removePrefix("pad=").trim().substringBefore(" ")
        return value.substringBefore("x").trim().toFloatOrNull() ?: DEFAULT_PAD
    }

    /**
     * Resolves a family name to a Compose [FontFamily] through Skia's font
     * manager — the same fontconfig database Foot and Alacritty resolve against,
     * so a name that works there works here.
     *
     * Falls back to [FontFamily.Monospace] when the face is missing, which on a
     * stock Arch box fontconfig already answers with JetBrainsMono Nerd Font.
     */
    fun resolveFamily(name: String?): FontFamily {
        if (name.isNullOrBlank()) return FontFamily.Monospace
        val typeface = runCatching {
            org.jetbrains.skia.FontMgr.default.matchFamilyStyle(
                name,
                org.jetbrains.skia.FontStyle.NORMAL,
            )
        }.getOrNull() ?: return FontFamily.Monospace
        return runCatching {
            FontFamily(androidx.compose.ui.text.platform.Typeface(typeface))
        }.getOrDefault(FontFamily.Monospace)
    }
}
