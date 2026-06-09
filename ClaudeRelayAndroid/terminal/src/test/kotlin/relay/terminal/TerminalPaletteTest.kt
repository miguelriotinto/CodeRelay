package relay.terminal

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * Spot-checks the ANSI palette against
 * `ClaudeRelayApp/Views/Components/TerminalPalette.swift`.
 */
class TerminalPaletteTest {

    @Test
    fun paletteHasSixteenEntries() {
        assertEquals(16, TerminalPalette.colors.size)
    }

    @Test
    fun allEntriesAreOpaque() {
        for ((index, argb) in TerminalPalette.colors.withIndex()) {
            val alpha = (argb ushr 24) and 0xFF
            assertEquals(0xFF, alpha, "palette[$index] must be fully opaque")
        }
    }

    @Test
    fun spotCheckedValuesMatchSwift() {
        // 0 black = 0x000000
        assertEquals(0xFF000000.toInt(), TerminalPalette.colors[0])
        // 1 red = 0xCC0000
        assertEquals(0xFFCC0000.toInt(), TerminalPalette.colors[1])
        // 7 white = 0xE5E5E5
        assertEquals(0xFFE5E5E5.toInt(), TerminalPalette.colors[7])
        // 12 bright blue = 0x5C5CFF
        assertEquals(0xFF5C5CFF.toInt(), TerminalPalette.colors[12])
        // 15 bright white = 0xFFFFFF
        assertEquals(0xFFFFFFFF.toInt(), TerminalPalette.colors[15])
    }

    @Test
    fun backgroundIsBlackAndForegroundIsWhite() {
        assertEquals(0xFF000000.toInt(), TerminalPalette.background)
        assertEquals(0xFFFFFFFF.toInt(), TerminalPalette.foreground)
    }
}
