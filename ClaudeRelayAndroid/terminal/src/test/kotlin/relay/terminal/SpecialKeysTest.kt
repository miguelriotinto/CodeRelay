package relay.terminal

import org.junit.jupiter.api.Assertions.assertArrayEquals
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
}
