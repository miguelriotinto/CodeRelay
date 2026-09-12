package relay.platform

import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class OmarchyThemeTest {

    @AfterEach
    fun restore() {
        OmarchyTheme.stateDir = File(System.getProperty("user.home"), ".local/state/omarchy/current")
    }

    /** The real tokyo-night theme, verbatim, as shipped by Omarchy. */
    private val tokyoNight = """
        mode = "dark"

        accent = "#7aa2f7"
        selection = "#292e42"
        muted = "#414868"

        background = "#1a1b26"
        dark_background = "#13141c"
        darker_background = "#0e0e14"
        lighter_background = "#24283b"

        foreground = "#a9b1d6"
        dark_foreground = "#565f89"
        light_foreground = "#b4bee6"
        bright_foreground = "#c0caf5"

        red = "#f7768e"
        yellow = "#e0af68"
        orange = "#eb927b"
        green = "#9ece6a"
        cyan = "#449dab"
        blue = "#7aa2f7"
        magenta = "#ad8ee6"
        brown = "#75493d"

        bright_red = "#ff7a93"
        bright_yellow = "#ff9e64"
        bright_green = "#b9f27c"
        bright_cyan = "#0db9d7"
        bright_blue = "#7da6ff"
        bright_magenta = "#bb9af7"
    """.trimIndent()

    private fun install(tmp: File, colors: String, name: String = "tokyo-night") {
        val themeDir = File(tmp, "theme").apply { mkdirs() }
        File(themeDir, "colors.toml").writeText(colors)
        File(tmp, "theme.name").writeText(name)
        OmarchyTheme.stateDir = tmp
    }

    // ---- parsing ----

    @Test
    fun `parses flat key-value pairs`() {
        val parsed = OmarchyTheme.parse(tokyoNight)
        assertEquals("#7aa2f7", parsed["accent"])
        assertEquals("dark", parsed["mode"])
        assertEquals("#bb9af7", parsed["bright_magenta"])
    }

    /**
     * The values ARE '#'-prefixed hex, so a naive "strip everything after #"
     * comment rule would erase every colour in the file.
     */
    @Test
    fun `does not treat a quoted hex value as a comment`() {
        val parsed = OmarchyTheme.parse("""red = "#f7768e"""")
        assertEquals("#f7768e", parsed["red"])
    }

    @Test
    fun `skips comments and blank lines`() {
        val parsed = OmarchyTheme.parse("# a comment\n\nred = \"#ff0000\"\n")
        assertEquals(1, parsed.size)
        assertEquals("#ff0000", parsed["red"])
    }

    @Test
    fun `tolerates unknown keys`() {
        val parsed = OmarchyTheme.parse("hyprland_active_border = \"#123456\"\nred = \"#ff0000\"")
        assertEquals("#123456", parsed["hyprland_active_border"])
    }

    // ---- colour conversion ----

    @Test
    fun `parses six-digit hex to opaque argb`() {
        assertEquals(0xFF7AA2F7.toInt(), OmarchyTheme.parseHexColor("#7aa2f7"))
    }

    @Test
    fun `parses three-digit shorthand`() {
        assertEquals(0xFFFF0000.toInt(), OmarchyTheme.parseHexColor("#f00"))
    }

    @Test
    fun `drops alpha from eight-digit hex`() {
        // The terminal palette is always opaque; a themed alpha must not make
        // the grid transparent.
        assertEquals(0xFF7AA2F7.toInt(), OmarchyTheme.parseHexColor("#807aa2f7"))
    }

    @Test
    fun `rejects malformed colour`() {
        assertNull(OmarchyTheme.parseHexColor("not-a-colour"))
        assertNull(OmarchyTheme.parseHexColor("#12345"))
        assertNull(OmarchyTheme.parseHexColor("#gggggg"))
    }

    // ---- full load ----

    @Test
    fun `loads the real tokyo-night theme`(@TempDir tmp: File) {
        install(tmp, tokyoNight)
        val p = requireNotNull(OmarchyTheme.load())

        assertEquals("tokyo-night", p.name)
        assertEquals(OmarchyTheme.Mode.DARK, p.mode)
        assertEquals(16, p.ansi.size)
        assertEquals(0xFF1A1B26.toInt(), p.background)
        assertEquals(0xFFA9B1D6.toInt(), p.foreground)
        assertEquals(0xFF7AA2F7.toInt(), p.accent)
    }

    @Test
    fun `maps ansi slots in xterm order`(@TempDir tmp: File) {
        install(tmp, tokyoNight)
        val a = requireNotNull(OmarchyTheme.load()).ansi

        assertEquals(0xFFF7768E.toInt(), a[1], "1 = red")
        assertEquals(0xFF9ECE6A.toInt(), a[2], "2 = green")
        assertEquals(0xFFE0AF68.toInt(), a[3], "3 = yellow")
        assertEquals(0xFF7AA2F7.toInt(), a[4], "4 = blue")
        assertEquals(0xFFAD8EE6.toInt(), a[5], "5 = magenta")
        assertEquals(0xFF449DAB.toInt(), a[6], "6 = cyan")
        assertEquals(0xFFFF7A93.toInt(), a[9], "9 = bright red")
    }

    /**
     * Omarchy defines no `bright_black` or `bright_white`. Substituting `muted`
     * and `bright_foreground` is what keeps dim and bold text legible instead of
     * collapsing either into the background.
     */
    @Test
    fun `substitutes muted and bright_foreground for the missing greys`(@TempDir tmp: File) {
        install(tmp, tokyoNight)
        val a = requireNotNull(OmarchyTheme.load()).ansi

        assertEquals(0xFF414868.toInt(), a[8], "8 = bright black ← muted")
        assertEquals(0xFFC0CAF5.toInt(), a[15], "15 = bright white ← bright_foreground")
        assertEquals(0xFF13141C.toInt(), a[0], "0 = black ← dark_background")
        assertEquals(0xFFA9B1D6.toInt(), a[7], "7 = white ← foreground")
    }

    @Test
    fun `reads light mode`(@TempDir tmp: File) {
        install(tmp, tokyoNight.replace("""mode = "dark"""", """mode = "light""""))
        assertEquals(OmarchyTheme.Mode.LIGHT, requireNotNull(OmarchyTheme.load()).mode)
    }

    // ---- graceful degradation: none of this may ever be fatal ----

    @Test
    fun `absent omarchy returns null rather than throwing`(@TempDir tmp: File) {
        OmarchyTheme.stateDir = File(tmp, "does-not-exist")
        assertNull(OmarchyTheme.load())
        assertFalse(OmarchyTheme.isAvailable())
    }

    @Test
    fun `malformed toml returns null`(@TempDir tmp: File) {
        install(tmp, "this is not remotely a toml file")
        assertNull(OmarchyTheme.load())
    }

    /**
     * Rejected wholesale rather than part-filled: a palette with three real
     * colours and thirteen defaults looks far more broken than the honest
     * built-in palette does.
     */
    @Test
    fun `a theme missing a required colour is rejected entirely`(@TempDir tmp: File) {
        install(tmp, tokyoNight.lineSequence().filterNot { it.startsWith("green") }.joinToString("\n"))
        assertNull(OmarchyTheme.load())
    }

    @Test
    fun `missing theme_name falls back to a placeholder`(@TempDir tmp: File) {
        install(tmp, tokyoNight)
        File(tmp, "theme.name").delete()
        assertEquals("omarchy", requireNotNull(OmarchyTheme.load()).name)
    }

    @Test
    fun `isAvailable is true when colors exist`(@TempDir tmp: File) {
        install(tmp, tokyoNight)
        assertTrue(OmarchyTheme.isAvailable())
    }

    /**
     * The palette is compared to decide whether to repaint. A data class holding
     * an IntArray gets reference equality for that field, which would make every
     * comparison report a change and repaint the grid on every poll.
     */
    @Test
    fun `equal palettes compare equal despite the IntArray field`(@TempDir tmp: File) {
        install(tmp, tokyoNight)
        val first = requireNotNull(OmarchyTheme.load())
        val second = requireNotNull(OmarchyTheme.load())
        assertEquals(first, second)
        assertEquals(first.hashCode(), second.hashCode())
    }

    @Test
    fun `different themes compare unequal`(@TempDir tmp: File) {
        install(tmp, tokyoNight)
        val dark = requireNotNull(OmarchyTheme.load())
        install(tmp, tokyoNight.replace("#f7768e", "#00ff00"))
        assertTrue(dark != requireNotNull(OmarchyTheme.load()))
    }
}
