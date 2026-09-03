package relay.terminal.linux

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Wheel reporting — the capability Android's engine lacks entirely.
 *
 * Claude Code runs in the alternate screen buffer, which has no scrollback by
 * definition. Its transcript only moves when the program is *told* to move it,
 * via a wheel report. These tests drive the real libvterm through the patched
 * JNI bridge (see patches/0001-mouse-dispatch.md).
 */
class MouseDispatchTest {

    private fun withEmulator(block: (LinuxTerminalEmulator, MutableList<ByteArray>) -> Unit) {
        val out = CopyOnWriteArrayList<ByteArray>()
        LinuxTerminalEmulator(initialRows = 24, initialCols = 80, onKeyboardInput = { out.add(it) })
            .use { block(it, out) }
    }

    private fun List<ByteArray>.text() = joinToString("") { String(it, Charsets.UTF_8) }

    /**
     * The single most important assertion here: with reporting OFF, a wheel
     * event must produce nothing. A plain shell has real local scrollback, and
     * injecting escape bytes at its prompt would corrupt the command line —
     * which is exactly the class of bug the iOS client hit when it sent arrow
     * keys and recalled shell history instead of scrolling.
     */
    @Test
    fun `emits nothing when the program has not enabled mouse reporting`() {
        withEmulator { e, out ->
            e.dispatchWheel(down = true, row = 5, col = 10)
            assertTrue(out.isEmpty(), "unexpected bytes for an unreporting program: ${out.text()}")
        }
    }

    @Test
    fun `emits a report once the program enables mouse tracking`() {
        withEmulator { e, out ->
            // CSI ?1000h = report button events. CSI ?1006h = SGR encoding.
            e.feedOutput("[?1000h[?1006h".toByteArray())
            out.clear()

            e.dispatchWheel(down = true, row = 5, col = 10)
            assertTrue(out.isNotEmpty(), "a tracking program must receive a wheel report")
        }
    }

    /** SGR reports are `CSI < b ; col ; row M|m`. Wheel down is button 65 (64+1). */
    @Test
    fun `wheel down reports SGR button 65`() {
        withEmulator { e, out ->
            e.feedOutput("[?1000h[?1006h".toByteArray())
            out.clear()
            e.dispatchWheel(down = true, row = 5, col = 10)

            val s = out.text()
            assertTrue(s.startsWith("[<"), "expected an SGR report, got: ${s.map { it.code }}")
            assertTrue(s.contains("65;"), "wheel down is button 64+1=65, got: $s")
        }
    }

    /** Wheel up is button 64 (64+0). Getting these swapped inverts scrolling. */
    @Test
    fun `wheel up reports SGR button 64`() {
        withEmulator { e, out ->
            e.feedOutput("[?1000h[?1006h".toByteArray())
            out.clear()
            e.dispatchWheel(down = false, row = 5, col = 10)

            val s = out.text()
            assertTrue(s.contains("64;"), "wheel up is button 64+0=64, got: $s")
        }
    }

    /** Up and down must differ, or scrolling would only ever go one way. */
    @Test
    fun `up and down produce different reports`() {
        withEmulator { e, out ->
            e.feedOutput("[?1000h[?1006h".toByteArray())
            out.clear()
            e.dispatchWheel(down = true, row = 5, col = 10)
            val downReport = out.text()

            out.clear()
            e.dispatchWheel(down = false, row = 5, col = 10)
            val upReport = out.text()

            assertFalse(downReport == upReport, "up and down encoded identically: $downReport")
        }
    }

    /** The cell under the pointer travels in the report; programs use it for hit-testing. */
    @Test
    fun `the report carries the cell position`() {
        withEmulator { e, out ->
            e.feedOutput("[?1000h[?1006h".toByteArray())
            out.clear()
            e.dispatchWheel(down = true, row = 7, col = 12)

            val s = out.text()
            // Cells are passed 0-based; libvterm's encoder adds the +1 the wire
            // wants, so (row 7, col 12) is reported as col 13, row 8.
            assertTrue(s.contains(";13;8"), "expected col 13 / row 8 in the report, got: $s")
        }
    }

    @Test
    fun `a button press and release both report`() {
        withEmulator { e, out ->
            e.feedOutput("[?1000h[?1006h".toByteArray())
            out.clear()
            e.dispatchMouseButton(button = 1, pressed = true, modifiers = 0)
            val afterPress = out.text()
            e.dispatchMouseButton(button = 1, pressed = false, modifiers = 0)
            val afterBoth = out.text()

            assertTrue(afterPress.isNotEmpty(), "press must report")
            assertTrue(afterBoth.length > afterPress.length, "release must report too")
            // SGR distinguishes release with a trailing 'm' rather than 'M'.
            assertTrue(afterBoth.endsWith("m"), "SGR release ends with 'm', got: $afterBoth")
        }
    }

    @Test
    fun `motion reporting stays silent unless the program asks for it`() {
        withEmulator { e, out ->
            // ?1000h is button events only — motion must NOT report.
            e.feedOutput("[?1000h[?1006h".toByteArray())
            out.clear()
            e.dispatchMouseMove(row = 3, col = 4)
            assertTrue(out.isEmpty(), "button-only mode must not report bare motion: ${out.text()}")
        }
    }
}
