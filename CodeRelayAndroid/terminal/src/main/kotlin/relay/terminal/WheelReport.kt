package relay.terminal

import kotlin.math.abs

/**
 * Encodes a mouse-wheel report the way xterm (and SwiftTerm on iOS) would, so
 * a swipe on Android reaches the program as the same bytes a swipe on iOS or a
 * scroll wheel on macOS does. Wheel up/down are X11 buttons 4 and 5.
 *
 * termlib 0.1.0 exposes no mouse entry point (libvterm's `vterm_mouse_button`
 * is not even linked into its `.so`), so the client encodes the report itself
 * and sends it down the ordinary keystroke path. [MouseTrackingTracker] says
 * which of the three formats the program asked for.
 */
object WheelReport {

    /** X11 wheel buttons, as the program sees them. */
    private const val BUTTON_WHEEL_UP = 4
    private const val BUTTON_WHEEL_DOWN = 5

    /**
     * Highest coordinate X10 can carry: `32 + 1 + 222 = 255`. xterm prints a
     * control byte for anything larger; clamping keeps the report well-formed.
     */
    private const val X10_MAX_COORDINATE = 222

    /**
     * @param up true for wheel up (earlier content), false for wheel down
     * @param col 0-based column under the finger
     * @param row 0-based row under the finger
     */
    fun encode(up: Boolean, col: Int, row: Int, encoding: MouseEncoding): ByteArray {
        // Wheel buttons are reported with the 64 "extended button" flag added
        // to (button - 4): 64 for up, 65 for down. Same value in every format.
        val code = 64 + (if (up) BUTTON_WHEEL_UP else BUTTON_WHEEL_DOWN) - 4
        val x = maxOf(0, col) + 1
        val y = maxOf(0, row) + 1
        return when (encoding) {
            MouseEncoding.SGR -> "\u001b[<$code;$x;${y}M".toByteArray(Charsets.ISO_8859_1)
            MouseEncoding.URXVT -> "\u001b[${32 + code};$x;${y}M".toByteArray(Charsets.ISO_8859_1)
            MouseEncoding.X10 -> byteArrayOf(
                0x1B, '['.code.toByte(), 'M'.code.toByte(),
                (32 + code).toByte(),
                (32 + minOf(x, X10_MAX_COORDINATE + 1)).toByte(),
                (32 + minOf(y, X10_MAX_COORDINATE + 1)).toByte(),
            )
        }
    }
}

/**
 * Converts finger travel into whole wheel notches, keeping the sub-row remainder
 * so a slow drag scrolls smoothly instead of dropping every movement smaller
 * than a row — the same banking iOS does in `RelayTerminalView.sendWheel`.
 *
 * Sign convention: **positive travel (finger moving down the screen) yields
 * positive notches, meaning wheel UP** — pulling earlier content into view, as
 * a trackpad with natural scrolling does and as macOS `scrollWheel` reports it.
 *
 * [take]'s cap exists because a fling covers dozens of rows between frames and
 * programs commonly throttle a wheel flood, so sending every notch can scroll
 * *less* far than sending a few. While a finger is down the excess is
 * discarded — a backlog would keep scrolling after the finger stopped. During a
 * fling it is carried, so how far a fling travels does not depend on how many
 * frames the device managed to draw.
 */
class WheelTravelBank {

    private var travel = 0f

    /**
     * Banks [deltaY] pixels and returns the whole notches now due, at most
     * [maxNotches] in magnitude. Returns 0 for a non-positive [rowHeight] or a
     * non-finite delta, both of which would otherwise poison the bank.
     *
     * @param carryExcess keep notches beyond the cap for the next call (fling)
     *   rather than discarding them (finger down)
     */
    fun take(deltaY: Float, rowHeight: Float, maxNotches: Int = Int.MAX_VALUE, carryExcess: Boolean = false): Int {
        if (rowHeight <= 0f || !deltaY.isFinite()) return 0
        travel += deltaY
        val due = (travel / rowHeight).toInt()
        if (due == 0) return 0
        val sent = due.coerceIn(-maxNotches, maxNotches)
        if (carryExcess) {
            travel -= sent * rowHeight
        } else {
            // Drop the surplus whole notches but keep the sub-row remainder.
            travel -= due * rowHeight
        }
        return sent
    }

    /** Forgets banked travel; call at the start of each gesture. */
    fun reset() {
        travel = 0f
    }

    /** True when at least one whole notch is banked (used by fling to know when to stop). */
    fun hasWholeNotch(rowHeight: Float): Boolean = rowHeight > 0f && abs(travel) >= rowHeight
}
