package relay.terminal

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The DECSET/DECRST sequences here are the ones Claude Code emits on launch and
 * exit (`CSI ?1000h ?1002h ?1003h ?1006h`), verified against libvterm's
 * `state.c` numbering: 1000/1002/1003 select a tracking mode, 1006 selects SGR
 * encoding, 1015 selects urxvt encoding, and `ESC c` (RIS) clears everything.
 */
class MouseTrackingTrackerTest {

    private fun bytes(s: String) = s.toByteArray(Charsets.ISO_8859_1)

    @Test
    fun `tracking is off until a program asks for it`() {
        val t = MouseTrackingTracker()
        assertFalse(t.isTracking)
        assertEquals(MouseEncoding.X10, t.encoding)
    }

    @Test
    fun `claude code's launch sequence turns tracking on with SGR encoding`() {
        val t = MouseTrackingTracker()
        t.feed(bytes("\u001b[?1049h\u001b[?1000h\u001b[?1002h\u001b[?1003h\u001b[?1006h"))
        assertTrue(t.isTracking)
        assertEquals(MouseEncoding.SGR, t.encoding)
    }

    @Test
    fun `resetting any tracking mode turns tracking off`() {
        val t = MouseTrackingTracker()
        t.feed(bytes("\u001b[?1002h"))
        assertTrue(t.isTracking)
        t.feed(bytes("\u001b[?1000l"))
        assertFalse(t.isTracking, "libvterm clears the mode on DECRST of any of 1000/1002/1003")
    }

    @Test
    fun `semicolon separated parameters are all honoured`() {
        val t = MouseTrackingTracker()
        t.feed(bytes("\u001b[?1000;1006h"))
        assertTrue(t.isTracking)
        assertEquals(MouseEncoding.SGR, t.encoding)
        t.feed(bytes("\u001b[?1006;1000l"))
        assertFalse(t.isTracking)
        assertEquals(MouseEncoding.X10, t.encoding)
    }

    @Test
    fun `a sequence split across two frames is still recognised`() {
        val t = MouseTrackingTracker()
        t.feed(bytes("\u001b[?10"))
        assertFalse(t.isTracking)
        t.feed(bytes("00h"))
        assertTrue(t.isTracking)
    }

    @Test
    fun `urxvt encoding is reported and SGR wins when both are set`() {
        val t = MouseTrackingTracker()
        t.feed(bytes("\u001b[?1000h\u001b[?1015h"))
        assertEquals(MouseEncoding.URXVT, t.encoding)
        t.feed(bytes("\u001b[?1006h"))
        assertEquals(MouseEncoding.SGR, t.encoding)
        t.feed(bytes("\u001b[?1006l"))
        assertEquals(MouseEncoding.URXVT, t.encoding)
    }

    @Test
    fun `RIS clears tracking and encoding`() {
        val t = MouseTrackingTracker()
        t.feed(bytes("\u001b[?1000h\u001b[?1006h"))
        t.feed(bytes("\u001bc"))
        assertFalse(t.isTracking)
        assertEquals(MouseEncoding.X10, t.encoding)
    }

    @Test
    fun `unrelated CSI and the same numbers without the private marker are ignored`() {
        val t = MouseTrackingTracker()
        // 1000h without '?' is not DECSET; CSI 31m is SGR colour; CSI 2J is a clear.
        t.feed(bytes("\u001b[1000h\u001b[31m\u001b[2J\u001b[?25h"))
        assertFalse(t.isTracking)
        assertEquals(MouseEncoding.X10, t.encoding)
    }

    @Test
    fun `an OSC payload cannot fake a mode change`() {
        val t = MouseTrackingTracker()
        // The text "[?1000h" inside an OSC title string is payload, not CSI.
        t.feed(bytes("\u001b]0;title [?1000h\u0007"))
        assertFalse(t.isTracking)
        // ...and the parser is back in ground state afterwards.
        t.feed(bytes("\u001b[?1000h"))
        assertTrue(t.isTracking)
    }

    @Test
    fun `an OSC terminated by ST hands the following CSI through`() {
        val t = MouseTrackingTracker()
        t.feed(bytes("\u001b]52;c;aGVsbG8=\u001b\\\u001b[?1000h"))
        assertTrue(t.isTracking)
    }

    @Test
    fun `an overlong CSI is dropped without wedging the parser`() {
        val t = MouseTrackingTracker()
        t.feed(bytes("\u001b[" + "9".repeat(200) + "h"))
        assertFalse(t.isTracking)
        t.feed(bytes("\u001b[?1000h"))
        assertTrue(t.isTracking)
    }

    @Test
    fun `CAN aborts a sequence in progress`() {
        val t = MouseTrackingTracker()
        t.feed(bytes("\u001b[?10\u0018" + "00h"))
        assertFalse(t.isTracking)
    }

    @Test
    fun `plain text never changes state`() {
        val t = MouseTrackingTracker()
        t.feed(bytes("hello ?1000h world"))
        assertFalse(t.isTracking)
    }

    @Test
    fun `reset returns to the initial state`() {
        val t = MouseTrackingTracker()
        t.feed(bytes("\u001b[?1000h\u001b[?1006h\u001b[?10"))
        t.reset()
        assertFalse(t.isTracking)
        assertEquals(MouseEncoding.X10, t.encoding)
        // The partial "\u001b[?10" was discarded by reset, so "00h" is plain text.
        t.feed(bytes("00h"))
        assertFalse(t.isTracking)
    }
}
