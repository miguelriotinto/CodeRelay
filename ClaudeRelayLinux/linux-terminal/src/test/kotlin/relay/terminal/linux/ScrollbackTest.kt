package relay.terminal.linux

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Local scrollback for the normal screen, through the real libvterm.
 *
 * The server's ring buffer is the authoritative history; this is the copy a
 * plain shell needs so the wheel can move the view at all. The alternate screen
 * has none, and that is asserted rather than assumed — Claude Code lives there.
 */
class ScrollbackTest {

    private fun emulator(rows: Int = 5, cols: Int = 20, scrollback: Int = 100) =
        LinuxTerminalEmulator(initialRows = rows, initialCols = cols, scrollbackLines = scrollback)

    private fun LinuxTerminalEmulator.feedLines(count: Int, from: Int = 1) {
        val text = (from until from + count).joinToString("") { "line$it\r\n" }
        feedOutput(text.toByteArray())
        refreshIfDirty()
    }

    private fun LinuxTerminalEmulator.rowText(row: Int): String =
        grid.value.lines[row].spans.joinToString("") { it.text }.trimEnd()

    @Test
    fun `lines pushed off the top are retained`() {
        emulator().use { e ->
            e.feedLines(8)
            // 8 lines + a trailing prompt row on a 5-row screen: 4 scrolled out.
            assertEquals(4, e.scrollbackSize.value)
        }
    }

    @Test
    fun `scrolling the viewport shows the retained lines above the live screen`() {
        emulator().use { e ->
            e.feedLines(8)
            e.scrollViewport(2)
            e.refreshIfDirty()
            assertEquals(2, e.viewportOffset.value)
            assertEquals("line3", e.rowText(0), "two lines up, the top row is the third line")
            assertEquals("line4", e.rowText(1))
            assertEquals("line5", e.rowText(2), "then the live screen's own top row")
            assertEquals(2, e.grid.value.viewportOffset)
            assertFalse(e.grid.value.cursor.visible, "no cursor while looking at history")
        }
    }

    @Test
    fun `scrolling further than one screen shows only history and keeps rendering`() {
        emulator(rows = 3, cols = 20).use { e ->
            e.feedLines(12) // 12 lines + prompt row on 3 rows: 10 in scrollback
            assertEquals(10, e.scrollbackSize.value)
            e.scrollViewport(8) // more than the 3-row screen
            e.refreshIfDirty() // used to throw: take(rows - offset) with a negative count
            assertEquals(8, e.viewportOffset.value)
            assertEquals(listOf("line3", "line4", "line5"), (0..2).map { e.rowText(it) })
            assertEquals(3, e.grid.value.lines.size)
        }
    }

    @Test
    fun `the viewport is clamped to what exists`() {
        emulator().use { e ->
            e.feedLines(8)
            e.scrollViewport(1_000)
            assertEquals(4, e.viewportOffset.value)
            e.scrollViewport(-1_000)
            assertEquals(0, e.viewportOffset.value)
        }
    }

    @Test
    fun `typing snaps the view back to live`() {
        emulator().use { e ->
            e.feedLines(8)
            e.scrollViewport(3)
            e.dispatchCharacter('x'.code)
            assertEquals(0, e.viewportOffset.value)
            e.scrollViewport(3)
            e.dispatchKey(VTermKey.ENTER)
            assertEquals(0, e.viewportOffset.value)
        }
    }

    @Test
    fun `new output while scrolled keeps the view anchored on the same content`() {
        emulator().use { e ->
            e.feedLines(8)
            e.scrollViewport(2)
            e.refreshIfDirty()
            assertEquals("line3", e.rowText(0))
            e.feedLines(2, from = 9)
            assertEquals(4, e.viewportOffset.value, "two more lines scrolled out, the anchor moved with them")
            assertEquals("line3", e.rowText(0), "same content on screen")
        }
    }

    @Test
    fun `the limit is enforced and can be lowered live`() {
        emulator(scrollback = 3).use { e ->
            e.feedLines(20)
            assertEquals(3, e.scrollbackSize.value)
            e.scrollbackLimit = 1
            assertEquals(1, e.scrollbackSize.value)
        }
    }

    @Test
    fun `a zero limit keeps nothing`() {
        emulator(scrollback = 0).use { e ->
            e.feedLines(20)
            assertEquals(0, e.scrollbackSize.value)
            e.scrollViewport(5)
            assertEquals(0, e.viewportOffset.value)
        }
    }

    @Test
    fun `the alternate screen has no scrollback and ignores viewport scrolling`() {
        emulator().use { e ->
            e.feedLines(8)
            e.scrollViewport(2)
            e.feedOutput("\u001b[?1049h".toByteArray())
            assertTrue(e.altScreen.value)
            assertEquals(0, e.viewportOffset.value, "entering the alt screen snaps to live")
            e.scrollViewport(2)
            assertEquals(0, e.viewportOffset.value, "no local scrolling in the alt screen")
            e.feedOutput("\u001b[?1049l".toByteArray())
            e.scrollViewport(2)
            assertEquals(2, e.viewportOffset.value, "back in the normal screen the history is still there")
        }
    }

    @Test
    fun `growing the screen pulls lines back out of scrollback`() {
        emulator(rows = 5).use { e ->
            e.feedLines(8)
            assertEquals(4, e.scrollbackSize.value)
            e.resize(newRows = 8, newCols = 20)
            e.refreshIfDirty()
            // Three new rows, filled from the three newest scrollback lines.
            assertEquals(1, e.scrollbackSize.value, "libvterm popped lines to fill the new rows")
            assertEquals("line2", e.rowText(0), "the popped lines are back on screen, in order")
            assertEquals("line5", e.rowText(3))
        }
    }

    @Test
    fun `clearing scrollback empties it`() {
        emulator().use { e ->
            e.feedLines(8)
            // CSI 3 J = clear scrollback (xterm extension libvterm honours).
            e.feedOutput("\u001b[3J".toByteArray())
            assertEquals(0, e.scrollbackSize.value)
        }
    }
}
