package relay.terminal

/**
 * Raw byte sequences for the on-screen keyboard accessory's special keys.
 *
 * Ported from `ClaudeRelayApp/Views/Components/KeyboardAccessory.swift`; every
 * byte is verified against that source. Two values are derived rather than
 * being discrete buttons in the Swift bar but share the Swift byte values:
 *  - [BACKSPACE] (`0x7F`): the Swift `delete.backward` button runs
 *    `clearToPrompt()` (16× `0x15` then `0x7F`); `0x7F` is the DEL byte it uses.
 *  - [CTRL_U] (`0x15`): used inside `clearToPrompt()` to kill the line; exposed
 *    here as a discrete key for the Compose keyboard bar (added later).
 */
object SpecialKeys {

    // --- Single control / whitespace bytes ---
    val RETURN: ByteArray get() = byteArrayOf(0x0D)
    val ESC: ByteArray get() = byteArrayOf(0x1B)
    val TAB: ByteArray get() = byteArrayOf(0x09)
    val BACKSPACE: ByteArray get() = byteArrayOf(0x7F)

    // --- Arrow keys (CSI sequences: ESC [ <letter>) ---
    val UP: ByteArray get() = byteArrayOf(0x1B, 0x5B, 0x41)
    val DOWN: ByteArray get() = byteArrayOf(0x1B, 0x5B, 0x42)
    val RIGHT: ByteArray get() = byteArrayOf(0x1B, 0x5B, 0x43)
    val LEFT: ByteArray get() = byteArrayOf(0x1B, 0x5B, 0x44)

    // --- Ctrl combos ---
    val CTRL_C: ByteArray get() = byteArrayOf(0x03) // SIGINT
    val CTRL_R: ByteArray get() = byteArrayOf(0x12) // reverse search
    val CTRL_A: ByteArray get() = byteArrayOf(0x01) // beginning of line
    val CTRL_E: ByteArray get() = byteArrayOf(0x05) // end of line
    val CTRL_D: ByteArray get() = byteArrayOf(0x04) // EOF
    val CTRL_Z: ByteArray get() = byteArrayOf(0x1A) // suspend
    val CTRL_L: ByteArray get() = byteArrayOf(0x0C) // clear
    val CTRL_U: ByteArray get() = byteArrayOf(0x15) // kill line
    val CTRL_V: ByteArray get() = byteArrayOf(0x16) // literal next / verbatim

    /**
     * A single literal character (e.g. the `| / ~ - _` quick keys in the iOS
     * bar). Truncates to a single byte via [Char.code], matching the ASCII
     * symbols those buttons emit.
     */
    fun literal(ch: Char): ByteArray = byteArrayOf(ch.code.toByte())

    /**
     * Sixteen cycles is empirically enough to clear any reasonable multi-line
     * continuation. Extra cycles are harmless — Ctrl-U and Backspace both
     * become no-ops once the cursor is at the prompt start. Mirrors Swift
     * `KeyboardAccessory.maxContinuationClearCycles`.
     */
    const val MAX_CONTINUATION_CLEAR_CYCLES = 16

    /**
     * Clears all input back to the prompt, including across continuation lines.
     *
     * Each cycle emits Ctrl-U (`0x15`, kill line) followed by Backspace
     * (`0x7F`, DEL — removes a continuation newline). Repeated
     * [MAX_CONTINUATION_CLEAR_CYCLES] times for 32 bytes total. The iOS
     * `delete.backward` keyboard-bar button calls this, NOT a bare backspace —
     * verified against `KeyboardAccessory.swift.clearToPrompt()`.
     */
    fun clearToPrompt(): ByteArray {
        val bytes = ByteArray(MAX_CONTINUATION_CLEAR_CYCLES * 2)
        for (cycle in 0 until MAX_CONTINUATION_CLEAR_CYCLES) {
            bytes[cycle * 2] = 0x15     // Ctrl-U kills the line
            bytes[cycle * 2 + 1] = 0x7F // Backspace removes continuation newline
        }
        return bytes
    }
}
