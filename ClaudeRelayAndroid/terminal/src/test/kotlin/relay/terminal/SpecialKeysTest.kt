package relay.terminal

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * Byte sequences verified against
 * `ClaudeRelayApp/Views/Components/KeyboardAccessory.swift`.
 */
class SpecialKeysTest {

    @Test
    fun controlAndEscapeBytes() {
        assertArrayEquals(byteArrayOf(0x0D), SpecialKeys.RETURN)
        assertArrayEquals(byteArrayOf(0x1B), SpecialKeys.ESC)
        assertArrayEquals(byteArrayOf(0x09), SpecialKeys.TAB)
        assertArrayEquals(byteArrayOf(0x7F), SpecialKeys.BACKSPACE)
    }

    @Test
    fun ctrlComboBytes() {
        assertArrayEquals(byteArrayOf(0x03), SpecialKeys.CTRL_C)
        assertArrayEquals(byteArrayOf(0x12), SpecialKeys.CTRL_R)
        assertArrayEquals(byteArrayOf(0x01), SpecialKeys.CTRL_A)
        assertArrayEquals(byteArrayOf(0x05), SpecialKeys.CTRL_E)
        assertArrayEquals(byteArrayOf(0x04), SpecialKeys.CTRL_D)
        assertArrayEquals(byteArrayOf(0x1A), SpecialKeys.CTRL_Z)
        assertArrayEquals(byteArrayOf(0x0C), SpecialKeys.CTRL_L)
        assertArrayEquals(byteArrayOf(0x15), SpecialKeys.CTRL_U)
    }

    @Test
    fun arrowSequences() {
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x41), SpecialKeys.UP)
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x42), SpecialKeys.DOWN)
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x43), SpecialKeys.RIGHT)
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x44), SpecialKeys.LEFT)
    }

    @Test
    fun literalEncodesAsciiChar() {
        assertArrayEquals(byteArrayOf(0x41), SpecialKeys.literal('A'))
        assertArrayEquals(byteArrayOf(0x7C), SpecialKeys.literal('|'))
        assertArrayEquals(byteArrayOf(0x2F), SpecialKeys.literal('/'))
        assertArrayEquals(byteArrayOf(0x7E), SpecialKeys.literal('~'))
        assertArrayEquals(byteArrayOf(0x2D), SpecialKeys.literal('-'))
        assertArrayEquals(byteArrayOf(0x5F), SpecialKeys.literal('_'))
    }

    // Verifies the iOS `delete.backward` button's clearToPrompt() — 16x
    // (Ctrl-U, DEL) = 32 bytes — against KeyboardAccessory.swift.
    @Test
    fun `clearToPrompt is 16x ctrl-u + del`() {
        val bytes = SpecialKeys.clearToPrompt()
        assertEquals(16, SpecialKeys.MAX_CONTINUATION_CLEAR_CYCLES)
        assertEquals(32, bytes.size, "16 cycles of (Ctrl-U, DEL) = 32 bytes")

        // The whole buffer is the (0x15, 0x7F) pattern repeated 16 times.
        for (cycle in 0 until 16) {
            assertEquals(
                0x15.toByte(), bytes[cycle * 2],
                "byte ${cycle * 2} must be Ctrl-U (0x15)"
            )
            assertEquals(
                0x7F.toByte(), bytes[cycle * 2 + 1],
                "byte ${cycle * 2 + 1} must be DEL (0x7F)"
            )
        }

        val expected = ByteArray(32)
        for (cycle in 0 until 16) {
            expected[cycle * 2] = 0x15
            expected[cycle * 2 + 1] = 0x7F
        }
        assertArrayEquals(expected, bytes)
    }
}
