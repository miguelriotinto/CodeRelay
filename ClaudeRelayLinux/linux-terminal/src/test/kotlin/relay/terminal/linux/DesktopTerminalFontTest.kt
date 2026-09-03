package relay.terminal.linux

import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class DesktopTerminalFontTest {

    @TempDir
    lateinit var tempDir: File

    private val original = DesktopTerminalFont.configDir

    @AfterEach
    fun restore() {
        DesktopTerminalFont.configDir = original
    }

    private fun write(relativePath: String, content: String) {
        val file = File(tempDir, relativePath)
        file.parentFile.mkdirs()
        file.writeText(content)
    }

    @Test
    fun `parses the Omarchy stock foot font line`() {
        val spec = DesktopTerminalFont.parseFoot(
            """
            [main]
            include=~/.local/state/omarchy/current/theme/foot.ini
            term=xterm-256color
            font=JetBrainsMono Nerd Font:size=9
            pad=14x14
            """.trimIndent(),
        )
        assertEquals("JetBrainsMono Nerd Font", spec!!.family)
        assertEquals(9f, spec.points)
    }

    @Test
    fun `a foot fallback list keeps only the primary face`() {
        val spec = DesktopTerminalFont.parseFoot("font=Iosevka:size=11, Noto Color Emoji:size=11")
        assertEquals("Iosevka", spec!!.family)
        assertEquals(11f, spec.points)
    }

    @Test
    fun `a foot font line without a size falls back to the stock size`() {
        val spec = DesktopTerminalFont.parseFoot("font=Fira Code")
        assertEquals("Fira Code", spec!!.family)
        assertEquals(DesktopTerminalFont.DEFAULT.points, spec.points)
    }

    @Test
    fun `fractional foot sizes survive`() {
        assertEquals(10.5f, DesktopTerminalFont.parseFoot("font=Hack:size=10.5")!!.points)
    }

    @Test
    fun `a config with no font line parses to null`() {
        assertNull(DesktopTerminalFont.parseFoot("[main]\npad=14x14\n"))
    }

    @Test
    fun `parses the Omarchy stock alacritty font table`() {
        val spec = DesktopTerminalFont.parseAlacritty(
            """
            [window]
            opacity = 1.0

            [font]
            normal = { family = "JetBrainsMono Nerd Font", style = "Regular" }
            bold = { family = "JetBrainsMono Nerd Font", style = "Bold" }
            size = 9
            """.trimIndent(),
        )
        assertEquals("JetBrainsMono Nerd Font", spec!!.family)
        assertEquals(9f, spec.points)
    }

    @Test
    fun `a size outside the font table is ignored`() {
        // `size` under [window] is a window dimension, not a font size.
        val spec = DesktopTerminalFont.parseAlacritty(
            """
            [window]
            size = 40

            [font]
            normal = { family = "Hack", style = "Regular" }
            """.trimIndent(),
        )
        assertEquals("Hack", spec!!.family)
        assertEquals(DesktopTerminalFont.DEFAULT.points, spec.points)
    }

    @Test
    fun `foot wins over alacritty when both exist`() {
        DesktopTerminalFont.configDir = tempDir
        write("foot/foot.ini", "font=Iosevka:size=11\n")
        write("alacritty/alacritty.toml", "[font]\nsize = 9\n")

        val spec = DesktopTerminalFont.load()
        assertEquals("Iosevka", spec.family)
        assertEquals(11f, spec.points)
    }

    @Test
    fun `alacritty is read when foot is absent`() {
        DesktopTerminalFont.configDir = tempDir
        write("alacritty/alacritty.toml", "[font]\nnormal = { family = \"Hack\" }\nsize = 13\n")

        val spec = DesktopTerminalFont.load()
        assertEquals("Hack", spec.family)
        assertEquals(13f, spec.points)
    }

    @Test
    fun `no terminal config at all falls back to the stock size`() {
        DesktopTerminalFont.configDir = File(tempDir, "empty")
        assertEquals(DesktopTerminalFont.DEFAULT, DesktopTerminalFont.load())
    }

    /**
     * The conversion that makes this comparable to Foot at all: points are
     * 1/72 inch, a logical inch is 96 dp, and Compose multiplies by the window's
     * density. 9 pt therefore has to come out as 12 dp — 24 device pixels on a
     * 2x panel, which is exactly what Foot renders for `size=9`.
     */
    @Test
    fun `points convert to dp at 96 over 72`() {
        assertEquals(12f, DesktopTerminalFont.Spec(null, 9f).sizeDp)
        assertEquals(16f, DesktopTerminalFont.Spec(null, 12f).sizeDp)
    }

    @Test
    fun `reads foot's window padding`() {
        val spec = DesktopTerminalFont.parseFoot(
            """
            [main]
            font=JetBrainsMono Nerd Font:size=9
            pad=14x14
            """.trimIndent(),
        )
        assertEquals(14f, spec!!.padDp)
    }

    @Test
    fun `foot's centered padding keeps the number, not the keyword`() {
        assertEquals(20f, DesktopTerminalFont.padOf("pad=20x20 center"))
    }

    @Test
    fun `a config with no pad line falls back to foot's own default`() {
        assertEquals(DesktopTerminalFont.DEFAULT_PAD, DesktopTerminalFont.padOf("[main]\nfont=Hack\n"))
    }

    @Test
    fun `reads alacritty's window padding`() {
        val spec = DesktopTerminalFont.parseAlacritty(
            """
            [window]
            padding = { x = 14, y = 14 }

            [font]
            size = 9
            """.trimIndent(),
        )
        assertEquals(14f, spec!!.padDp)
    }
}
