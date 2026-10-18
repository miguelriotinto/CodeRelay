package relay.terminal

/**
 * The wire format a program selected for mouse reports. xterm's default is the
 * three-byte X10 form; most modern full-screen programs (Claude Code, tmux, vim)
 * ask for SGR (`DECSET 1006`) because X10 cannot address columns past 223.
 */
enum class MouseEncoding { X10, SGR, URXVT }

/**
 * Mirrors the mouse-tracking modes a program sets on the terminal, by watching
 * the output byte stream for `CSI ? Pm h` / `CSI ? Pm l` (DECSET / DECRST).
 *
 * This exists because termlib 0.1.0 does not surface libvterm's
 * `VTERM_PROP_MOUSE` to Kotlin (its `setTermProp` handles cursor, title and
 * alt-screen only), yet the Android client needs the answer to one question —
 * **does the program want the wheel?** — to decide whether a swipe is a wheel
 * report to the program or a scroll of the local scrollback. SwiftTerm answers
 * the same question on iOS through its `mouseMode`; this is the Android stand-in.
 *
 * Numbering follows libvterm's `state.c`: 1000 (click), 1002 (drag) and 1003
 * (any-motion) each select tracking on `h`, and **any** of them on `l` clears it
 * (libvterm sets the property to `MOUSE_NONE` for each reset, not "whichever
 * mode was set"). 1006 selects SGR encoding, 1015 urxvt; SGR wins when both are
 * on, matching xterm. `ESC c` (RIS) clears everything — the client itself feeds
 * a RIS before a scrollback replay (`ReplayProtocol.RIS`), so replaying a
 * session re-derives the state from the replayed bytes instead of inheriting it.
 *
 * The parser is a small state machine so a sequence split across two frames is
 * still recognised, and OSC / DCS / APC / PM / SOS string payloads are skipped
 * so `[?1000h` inside a window title cannot flip the state. A CSI longer than
 * [MAX_CSI_BYTES] is discarded (nothing legitimate is that long) rather than
 * buffered without bound — the stream is remote input.
 *
 * Not thread-safe: fed from the same main-thread path as `TerminalEngine.feedOutput`.
 */
class MouseTrackingTracker {

    /** True while the program has any of DECSET 1000/1002/1003 enabled. */
    var isTracking: Boolean = false
        private set

    /** The format wheel reports must use; see [MouseEncoding]. */
    val encoding: MouseEncoding
        get() = when {
            sgr -> MouseEncoding.SGR
            urxvt -> MouseEncoding.URXVT
            else -> MouseEncoding.X10
        }

    private var sgr = false
    private var urxvt = false

    private enum class State { GROUND, ESC, CSI, STRING }

    private var state = State.GROUND
    private val csi = ByteArray(MAX_CSI_BYTES)
    private var csiLength = 0

    /** Feeds raw output bytes; may be called with any chunking, including mid-sequence. */
    fun feed(bytes: ByteArray) {
        for (b in bytes) {
            val c = b.toInt() and 0xFF
            // C0 controls that abort any sequence in progress, in every state.
            if (c == CAN || c == SUB) {
                state = State.GROUND
                continue
            }
            when (state) {
                State.GROUND -> if (c == ESC) state = State.ESC

                State.ESC -> state = when (c) {
                    '['.code -> {
                        csiLength = 0
                        State.CSI
                    }
                    // OSC, DCS, APC, PM, SOS: a string that ends at BEL or ST.
                    ']'.code, 'P'.code, '_'.code, '^'.code, 'X'.code -> State.STRING
                    'c'.code -> {
                        reset()
                        State.GROUND
                    }
                    // Another ESC restarts; anything else is a two-byte sequence we ignore.
                    ESC -> State.ESC
                    else -> State.GROUND
                }

                State.CSI -> when {
                    // Final byte: the sequence is complete.
                    c in 0x40..0x7E -> {
                        if (c == 'h'.code || c == 'l'.code) applyPrivateMode(set = c == 'h'.code)
                        state = State.GROUND
                    }
                    // Parameter and intermediate bytes.
                    c in 0x20..0x3F -> {
                        if (csiLength < MAX_CSI_BYTES) {
                            csi[csiLength++] = b
                        } else {
                            // Overlong: drop the sequence, resync on its final byte
                            // by treating the rest as ground-state text.
                            state = State.GROUND
                        }
                    }
                    c == ESC -> state = State.ESC
                    // Anything else (C0 inside a CSI, 8-bit) aborts the sequence.
                    else -> state = State.GROUND
                }

                State.STRING -> when (c) {
                    BEL -> state = State.GROUND
                    // ESC either begins ST (`ESC \`) or aborts the string; the ESC
                    // state handles both — `\` falls to the "ignore" branch.
                    ESC -> state = State.ESC
                    else -> {}
                }
            }
        }
    }

    /** Forgets modes and any partial sequence, as if the terminal were fresh. */
    fun reset() {
        isTracking = false
        sgr = false
        urxvt = false
        state = State.GROUND
        csiLength = 0
    }

    /** Applies a complete `CSI ? Pm h|l` held in [csi]; a CSI without `?` is not DECSET. */
    private fun applyPrivateMode(set: Boolean) {
        if (csiLength == 0 || csi[0] != '?'.code.toByte()) return
        var value = 0
        var hasDigit = false
        for (i in 1 until csiLength) {
            val c = csi[i].toInt() and 0xFF
            when {
                c in '0'.code..'9'.code -> {
                    hasDigit = true
                    // 65535 is far above any mode number; saturating avoids overflow.
                    if (value < 100_000) value = value * 10 + (c - '0'.code)
                }
                c == ';'.code -> {
                    if (hasDigit) applyMode(value, set)
                    value = 0
                    hasDigit = false
                }
                // Any other byte makes this something other than a plain DECSET.
                else -> return
            }
        }
        if (hasDigit) applyMode(value, set)
    }

    private fun applyMode(mode: Int, set: Boolean) {
        when (mode) {
            1000, 1002, 1003 -> isTracking = set
            1006 -> sgr = set
            1015 -> urxvt = set
        }
    }

    private companion object {
        const val ESC = 0x1B
        const val BEL = 0x07
        const val CAN = 0x18
        const val SUB = 0x1A

        /** Longest CSI parameter string accepted; DECSET lists are a few dozen bytes at most. */
        const val MAX_CSI_BYTES = 64
    }
}
