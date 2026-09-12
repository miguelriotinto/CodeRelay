package relay.terminal.linux

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import java.util.Base64

/**
 * OSC 52 is how tmux, vim and kitty push a copy to the device clipboard. The
 * security-relevant half is what we must NOT do: answer a read request.
 */
class Osc52DecodeTest {

    private fun encode(s: String) = Base64.getEncoder().encodeToString(s.toByteArray())

    @Test
    fun `decodes a clipboard write`() {
        val payload = "c;${encode("hello from vim")}"
        assertEquals("hello from vim", LinuxTerminalEmulator.decodeOsc52(payload))
    }

    @Test
    fun `decodes with an empty selection field`() {
        assertEquals("text", LinuxTerminalEmulator.decodeOsc52(";${encode("text")}"))
    }

    @Test
    fun `decodes multi-selection specifiers`() {
        // xterm allows several selection characters, e.g. "pc" for primary+clipboard.
        assertEquals("both", LinuxTerminalEmulator.decodeOsc52("pc;${encode("both")}"))
    }

    @Test
    fun `decodes utf8 content`() {
        val text = "naïve — 日本語 🎉"
        assertEquals(text, LinuxTerminalEmulator.decodeOsc52("c;${encode(text)}"))
    }

    /**
     * `?` is a clipboard READ request. Honouring it would let any program
     * running in the session exfiltrate the local clipboard over the wire. The
     * server's own `OSC52Parser` ignores these for the same reason; the client
     * must not reintroduce the hole from the other end.
     */
    @Test
    fun `ignores a read request`() {
        assertNull(LinuxTerminalEmulator.decodeOsc52("c;?"))
    }

    @Test
    fun `ignores an empty payload`() {
        assertNull(LinuxTerminalEmulator.decodeOsc52("c;"))
    }

    @Test
    fun `rejects a payload with no separator`() {
        assertNull(LinuxTerminalEmulator.decodeOsc52("garbage"))
    }

    @Test
    fun `rejects invalid base64 rather than throwing`() {
        assertNull(LinuxTerminalEmulator.decodeOsc52("c;!!!not-base64!!!"))
    }
}
