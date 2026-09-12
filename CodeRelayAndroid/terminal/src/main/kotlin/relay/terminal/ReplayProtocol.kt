package relay.terminal

/** Terminal control sequences used during scrollback replay. */
object ReplayProtocol {
    /**
     * RIS — Reset to Initial State (`ESC c`). Sent to blank the terminal before
     * the server replays ring-buffer scrollback.
     *
     * This is a shared, read-only [ByteArray]; it is NOT defensively copied on
     * read, so callers must treat it as immutable and must not mutate it.
     */
    val RIS: ByteArray = byteArrayOf(0x1B, 0x63)
}
