package relay.terminal.linux

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Drives the REAL libvterm emulator through the JNI bridge built from termlib's
 * upstream CMake. Nothing here is mocked — if these pass, the native path works.
 */
class LinuxTerminalEmulatorTest {

    private fun emulator(
        rows: Int = 24,
        cols: Int = 80,
        sink: ((ByteArray) -> Unit)? = null,
    ) = LinuxTerminalEmulator(initialRows = rows, initialCols = cols, onKeyboardInput = sink)

    /** All text on a row, spans concatenated. */
    private fun rowText(e: LinuxTerminalEmulator, row: Int): String {
        e.refreshIfDirty()
        return e.grid.value.lines.getOrNull(row)?.spans?.joinToString("") { it.text }?.trimEnd() ?: ""
    }

    @Test
    fun `loads the native library and starts`() {
        emulator().use { e ->
            assertEquals(24, e.grid.value.rows)
            assertEquals(80, e.grid.value.cols)
        }
    }

    @Test
    fun `renders plain text into the grid`() {
        emulator().use { e ->
            e.feedOutput("hello world".toByteArray())
            assertEquals("hello world", rowText(e, 0))
        }
    }

    @Test
    fun `handles newlines and carriage returns`() {
        emulator().use { e ->
            e.feedOutput("first\r\nsecond".toByteArray())
            assertEquals("first", rowText(e, 0))
            assertEquals("second", rowText(e, 1))
        }
    }

    /**
     * The whole reason for a real emulator: the Android text-fallback engine
     * rendered these as literal glyphs.
     */
    @Test
    fun `parses ANSI colour escapes instead of printing them`() {
        emulator().use { e ->
            e.feedOutput("[31mRED[0m".toByteArray())
            val text = rowText(e, 0)
            assertEquals("RED", text, "escape codes must be consumed, not rendered")
            assertFalse(text.contains("["), "no raw escape bytes may reach the grid")
        }
    }

    @Test
    fun `applies the ANSI palette to span colours`() {
        emulator().use { e ->
            // Bright red foreground on blue background.
            e.feedOutput("[91;44mX[0m".toByteArray())
            e.refreshIfDirty()
            val span = e.grid.value.lines[0].spans.first { it.text.contains("X") }
            assertTrue(span.fg != span.bg, "foreground and background must differ")
        }
    }

    @Test
    fun `reports bold and underline attributes`() {
        emulator().use { e ->
            e.feedOutput("[1mB[0m[4mU[0m".toByteArray())
            e.refreshIfDirty()
            val spans = e.grid.value.lines[0].spans
            assertTrue(spans.any { it.text.contains("B") && it.bold }, "bold must be reported")
            assertTrue(spans.any { it.text.contains("U") && it.underline > 0 }, "underline must be reported")
        }
    }

    @Test
    fun `honours cursor addressing`() {
        emulator().use { e ->
            // CUP: row 5, column 10 (1-based in the sequence).
            e.feedOutput("[5;10Hmarker".toByteArray())
            assertTrue(rowText(e, 4).contains("marker"), "text must land on the addressed row")
        }
    }

    @Test
    fun `tracks cursor position`() {
        emulator().use { e ->
            e.feedOutput("[3;7H".toByteArray())
            e.refreshIfDirty()
            assertEquals(2, e.grid.value.cursor.row)
            assertEquals(6, e.grid.value.cursor.col)
        }
    }

    /** Claude Code runs in the alternate buffer, so detecting it is load-bearing. */
    @Test
    fun `detects entering and leaving the alternate screen buffer`() {
        emulator().use { e ->
            assertFalse(e.altScreen.value, "starts on the normal buffer")
            e.feedOutput("[?1049h".toByteArray())
            assertTrue(e.altScreen.value, "CSI ?1049h enters the alt buffer")
            e.feedOutput("[?1049l".toByteArray())
            assertFalse(e.altScreen.value, "CSI ?1049l leaves it")
        }
    }

    /**
     * Android's engine has no mouse path at all. libvterm reports the mode the
     * program requested, which is what makes wheel scrolling possible here.
     */
    @Test
    fun `reports the mouse tracking mode a program requests`() {
        emulator().use { e ->
            assertEquals(0, e.mouseMode.value, "no tracking by default")
            e.feedOutput("[?1000h".toByteArray())
            assertTrue(e.mouseMode.value != 0, "CSI ?1000h must enable mouse reporting")
        }
    }

    @Test
    fun `clears the screen`() {
        emulator().use { e ->
            e.feedOutput("dirty".toByteArray())
            e.feedOutput("[2J[H".toByteArray())
            assertEquals("", rowText(e, 0))
        }
    }

    @Test
    fun `survives a resize and re-renders`() {
        emulator().use { e ->
            e.feedOutput("resize me".toByteArray())
            e.resize(40, 100)
            e.refreshIfDirty()
            assertEquals(40, e.grid.value.rows)
            assertEquals(100, e.grid.value.cols)
        }
    }

    // ---- input: emulator → relay ----

    @Test
    fun `emits bytes for a typed character`() {
        val out = CopyOnWriteArrayList<ByteArray>()
        emulator(sink = { out.add(it) }).use { e ->
            e.dispatchCharacter('a'.code)
            assertEquals("a", out.joinToString("") { String(it) })
        }
    }

    /** libvterm applies the control transform, which is why we pass the letter. */
    @Test
    fun `emits 0x03 for ctrl-C`() {
        val out = CopyOnWriteArrayList<ByteArray>()
        emulator(sink = { out.add(it) }).use { e ->
            e.dispatchCharacter('c'.code, VTermMod.CTRL)
            val bytes = out.flatMap { it.toList() }
            assertTrue(bytes.contains(0x03.toByte()), "Ctrl+C must produce ETX (0x03), got $bytes")
        }
    }

    @Test
    fun `emits an escape sequence for the up arrow`() {
        val out = CopyOnWriteArrayList<ByteArray>()
        emulator(sink = { out.add(it) }).use { e ->
            e.dispatchKey(VTermKey.UP)
            val s = out.joinToString("") { String(it) }
            assertTrue(s.startsWith(""), "arrow keys must emit an escape sequence, got: ${s.map { it.code }}")
        }
    }

    @Test
    fun `emits carriage return for enter`() {
        val out = CopyOnWriteArrayList<ByteArray>()
        emulator(sink = { out.add(it) }).use { e ->
            e.dispatchKey(VTermKey.ENTER)
            val bytes = out.flatMap { it.toList() }
            assertTrue(bytes.contains(0x0D.toByte()) || bytes.contains(0x0A.toByte()))
        }
    }

    @Test
    fun `utf8 multi-byte runes survive the byte path`() {
        emulator().use { e ->
            e.feedOutput("héllo → 日本".toByteArray(Charsets.UTF_8))
            val text = rowText(e, 0)
            assertTrue(text.contains("héllo"), "got: $text")
            assertTrue(text.contains("→"), "got: $text")
        }
    }

    /**
     * Escape sequences split across WebSocket frames must still parse — libvterm
     * is a streaming parser and holds partial state between feeds.
     */
    @Test
    fun `an escape sequence split across two feeds still parses`() {
        emulator().use { e ->
            e.feedOutput("[3".toByteArray())
            e.feedOutput("1mSPLIT[0m".toByteArray())
            assertEquals("SPLIT", rowText(e, 0), "a split escape must not leak into the grid")
        }
    }
}
