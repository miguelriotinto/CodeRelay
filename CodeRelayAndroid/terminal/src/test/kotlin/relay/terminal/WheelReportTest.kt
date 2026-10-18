package relay.terminal

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * Wire formats checked against xterm's ctlseqs and against what SwiftTerm emits
 * for the same events on iOS (`CodeRelayAppTests/TerminalSwipeScrollTests`), so
 * the two mobile clients produce byte-identical reports. Wheel up/down are
 * X11 buttons 4/5; coordinates on the wire are 1-based.
 */
class WheelReportTest {

    private fun bytes(s: String) = s.toByteArray(Charsets.ISO_8859_1)

    @Test
    fun `SGR wheel up at the origin`() {
        assertArrayEquals(bytes("\u001b[<64;1;1M"), WheelReport.encode(up = true, col = 0, row = 0, MouseEncoding.SGR))
    }

    @Test
    fun `SGR wheel down carries the cell under the finger`() {
        assertArrayEquals(bytes("\u001b[<65;10;5M"), WheelReport.encode(up = false, col = 9, row = 4, MouseEncoding.SGR))
    }

    @Test
    fun `X10 encodes button and coordinates as single offset bytes`() {
        // 32 + 64 + 0 = 96 ('`'), 32 + 10 = 42 ('*'), 32 + 5 = 37 ('%')
        assertArrayEquals(bytes("\u001b[M`*%"), WheelReport.encode(up = true, col = 9, row = 4, MouseEncoding.X10))
        // 32 + 64 + 1 = 97 ('a')
        assertArrayEquals(bytes("\u001b[Ma!!"), WheelReport.encode(up = false, col = 0, row = 0, MouseEncoding.X10))
    }

    @Test
    fun `X10 clamps coordinates so a byte never overflows`() {
        val report = WheelReport.encode(up = true, col = 500, row = 500, MouseEncoding.X10)
        assertEquals(6, report.size)
        assertEquals(0xFF.toByte(), report[4])
        assertEquals(0xFF.toByte(), report[5])
    }

    @Test
    fun `urxvt is the X10 button value in decimal`() {
        assertArrayEquals(bytes("\u001b[96;10;5M"), WheelReport.encode(up = true, col = 9, row = 4, MouseEncoding.URXVT))
        assertArrayEquals(bytes("\u001b[97;1;1M"), WheelReport.encode(up = false, col = 0, row = 0, MouseEncoding.URXVT))
    }

    @Test
    fun `negative coordinates are clamped to the origin`() {
        assertArrayEquals(bytes("\u001b[<64;1;1M"), WheelReport.encode(up = true, col = -3, row = -1, MouseEncoding.SGR))
    }
}

/**
 * The finger-travel bank mirrors iOS `RelayTerminalView.sendWheel(travel:at:)`:
 * sub-row movement is kept, not dropped, so a slow drag still scrolls, and
 * dragging DOWN (positive travel) is a wheel-UP report, as on a trackpad with
 * natural scrolling.
 */
class WheelTravelBankTest {

    @Test
    fun `one row of downward travel is one wheel-up notch`() {
        val bank = WheelTravelBank()
        assertEquals(1, bank.take(deltaY = 40f, rowHeight = 40f))
    }

    @Test
    fun `upward travel is negative, meaning wheel down`() {
        val bank = WheelTravelBank()
        assertEquals(-2, bank.take(deltaY = -80f, rowHeight = 40f))
    }

    @Test
    fun `sub-row travel accumulates instead of being dropped`() {
        val bank = WheelTravelBank()
        assertEquals(0, bank.take(15f, 40f))
        assertEquals(0, bank.take(15f, 40f))
        assertEquals(1, bank.take(15f, 40f), "45 px of travel is one 40 px row, with 5 px kept")
        assertEquals(1, bank.take(35f, 40f), "the kept 5 px plus 35 px is exactly another row")
    }

    @Test
    fun `reversing direction cancels banked travel first`() {
        val bank = WheelTravelBank()
        assertEquals(0, bank.take(30f, 40f))
        assertEquals(0, bank.take(-30f, 40f))
        assertEquals(-1, bank.take(-40f, 40f))
    }

    @Test
    fun `a burst is capped and the excess is discarded while the finger is down`() {
        val bank = WheelTravelBank()
        assertEquals(8, bank.take(deltaY = 40f * 20, rowHeight = 40f, maxNotches = 8, carryExcess = false))
        assertEquals(0, bank.take(0f, 40f), "nothing was carried")
    }

    @Test
    fun `a burst is capped and the excess is carried during a fling`() {
        val bank = WheelTravelBank()
        assertEquals(8, bank.take(deltaY = 40f * 20, rowHeight = 40f, maxNotches = 8, carryExcess = true))
        assertEquals(8, bank.take(0f, 40f, maxNotches = 8, carryExcess = true))
        assertEquals(4, bank.take(0f, 40f, maxNotches = 8, carryExcess = true))
        assertEquals(0, bank.take(0f, 40f, maxNotches = 8, carryExcess = true))
    }

    @Test
    fun `a non-positive row height cannot divide by zero`() {
        val bank = WheelTravelBank()
        assertEquals(0, bank.take(100f, 0f))
        assertEquals(0, bank.take(100f, -1f))
    }

    @Test
    fun `non-finite travel is ignored`() {
        val bank = WheelTravelBank()
        assertEquals(0, bank.take(Float.NaN, 40f))
        assertEquals(0, bank.take(Float.POSITIVE_INFINITY, 40f))
        assertEquals(1, bank.take(40f, 40f))
    }

    @Test
    fun `reset forgets banked travel`() {
        val bank = WheelTravelBank()
        bank.take(39f, 40f)
        bank.reset()
        assertEquals(0, bank.take(1f, 40f))
    }
}
