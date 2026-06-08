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

    /**
     * A single literal character (e.g. the `| / ~ - _` quick keys in the iOS
     * bar). Truncates to a single byte via [Char.code], matching the ASCII
     * symbols those buttons emit.
     */
    fun literal(ch: Char): ByteArray = byteArrayOf(ch.code.toByte())
}
