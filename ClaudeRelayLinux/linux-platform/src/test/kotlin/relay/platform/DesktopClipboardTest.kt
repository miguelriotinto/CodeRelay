package relay.platform

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

/**
 * The wl-clipboard path, with the process runner faked. The AWT fallback is
 * exercised by hand on an X11 session; it needs a display.
 */
class DesktopClipboardTest {

    private class FakeRunner(
        private val responses: Map<List<String>, ByteArray?> = emptyMap(),
        private val installed: Set<String> = setOf("wl-copy", "wl-paste"),
    ) : DesktopClipboard.CommandRunner {
        val calls = mutableListOf<Pair<List<String>, ByteArray?>>()
        override fun run(command: List<String>, stdin: ByteArray?): ByteArray? {
            calls += command to stdin
            return responses[command]
        }
        override fun exists(binary: String): Boolean = binary in installed
    }

    @Test
    fun `setText passes the text on stdin, never argv`() {
        val r = FakeRunner()
        DesktopClipboard(r, wayland = true).setText("secret")
        val (cmd, stdin) = r.calls.single()
        assertEquals("wl-copy", cmd.first())
        assertEquals("secret", stdin?.toString(Charsets.UTF_8))
        assertEquals(false, cmd.any { it.contains("secret") })
    }

    @Test
    fun `setPrimary targets the primary selection`() {
        val r = FakeRunner()
        DesktopClipboard(r, wayland = true).setPrimary("x")
        assertEquals(true, "--primary" in r.calls.single().first)
    }

    @Test
    fun `getText reads without a trailing newline`() {
        val cmd = listOf("wl-paste", "--no-newline", "--type", "text")
        val r = FakeRunner(mapOf(cmd to "hello".toByteArray()))
        assertEquals("hello", DesktopClipboard(r, wayland = true).getText())
    }

    @Test
    fun `getText from primary adds the flag`() {
        val cmd = listOf("wl-paste", "--no-newline", "--type", "text", "--primary")
        val r = FakeRunner(mapOf(cmd to "p".toByteArray()))
        assertEquals("p", DesktopClipboard(r, wayland = true).getText(primary = true))
    }

    @Test
    fun `an empty clipboard is null, not an empty string`() {
        val cmd = listOf("wl-paste", "--no-newline", "--type", "text")
        val r = FakeRunner(mapOf(cmd to ByteArray(0)))
        assertNull(DesktopClipboard(r, wayland = true).getText())
    }

    @Test
    fun `getImagePng returns png bytes when the clipboard offers an image`() {
        val png = byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte())
        val r = FakeRunner(
            mapOf(
                listOf("wl-paste", "--list-types") to "text/plain\nimage/png\n".toByteArray(),
                listOf("wl-paste", "--type", "image/png") to png,
            ),
        )
        assertEquals(png.toList(), DesktopClipboard(r, wayland = true).getImagePng()?.toList())
    }

    @Test
    fun `getImagePng is null for a text-only clipboard`() {
        val r = FakeRunner(mapOf(listOf("wl-paste", "--list-types") to "text/plain\n".toByteArray()))
        assertNull(DesktopClipboard(r, wayland = true).getImagePng())
    }

    @Test
    fun `without wl-clipboard nothing is spawned`() {
        val r = FakeRunner(installed = emptySet())
        // Falls back to AWT, which is not exercised here; the assertion is that
        // no process was attempted.
        runCatching { DesktopClipboard(r, wayland = true).setPrimary("x") }
        assertEquals(0, r.calls.size)
    }
}
