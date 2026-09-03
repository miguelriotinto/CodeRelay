package relay.terminal.linux

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * DECSCUSR (`CSI Ps SP q`) through the real libvterm: the shape and blink the
 * program asked for reach the grid snapshot the renderer draws from.
 */
class CursorShapeTest {

    private fun LinuxTerminalEmulator.apply(seq: String): GridCursor {
        feedOutput(seq.toByteArray())
        refreshIfDirty()
        return grid.value.cursor
    }

    @Test
    fun `defaults to a steady block`() {
        LinuxTerminalEmulator(4, 10).use { e ->
            e.refreshIfDirty()
            assertEquals(CursorShape.BLOCK, e.grid.value.cursor.shape)
        }
    }

    @Test
    fun `blinking bar`() {
        LinuxTerminalEmulator(4, 10).use { e ->
            val c = e.apply("\u001b[5 q")
            assertEquals(CursorShape.BAR, c.shape)
            assertTrue(c.blink)
        }
    }

    @Test
    fun `steady underline`() {
        LinuxTerminalEmulator(4, 10).use { e ->
            val c = e.apply("\u001b[4 q")
            assertEquals(CursorShape.UNDERLINE, c.shape)
            assertFalse(c.blink)
        }
    }

    @Test
    fun `steady block after a blinking one`() {
        LinuxTerminalEmulator(4, 10).use { e ->
            e.apply("\u001b[1 q")
            val c = e.apply("\u001b[2 q")
            assertEquals(CursorShape.BLOCK, c.shape)
            assertFalse(c.blink)
        }
    }

    @Test
    fun `hiding the cursor keeps the shape`() {
        LinuxTerminalEmulator(4, 10).use { e ->
            e.apply("\u001b[6 q")
            val c = e.apply("\u001b[?25l")
            assertFalse(c.visible)
            assertEquals(CursorShape.BAR, c.shape)
        }
    }

    @Test
    fun `unknown vterm shape values fall back to block`() {
        assertEquals(CursorShape.BLOCK, CursorShape.fromVTerm(99))
        assertEquals(CursorShape.UNDERLINE, CursorShape.fromVTerm(2))
        assertEquals(CursorShape.BAR, CursorShape.fromVTerm(3))
    }
}
