package relay.terminal

/** Terminal control sequences used during scrollback replay. */
object ReplayProtocol {
    /**
     * RIS — Reset to Initial State (`ESC c`). Sent to blank the terminal before
     * the server replays ring-buffer scrollback. Returned as a fresh copy via
     * [ris] is NOT done here; callers must not mutate this shared array.
     */
    val RIS: ByteArray = byteArrayOf(0x1B, 0x63)
}
