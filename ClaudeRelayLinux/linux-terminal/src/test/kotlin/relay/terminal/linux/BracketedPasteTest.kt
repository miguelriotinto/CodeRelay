package relay.terminal.linux

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Paste through the real libvterm, via the JNI additions in
 * patches/0002-bracketed-paste.md.
 *
 * The contract: the program decides whether a paste is bracketed (DECSET 2004),
 * libvterm remembers, and the emulator never has to know. A shell without the
 * mode gets the bare text; vim with it gets `ESC[200~ … ESC[201~` around it.
 */
class BracketedPasteTest {

    private fun withEmulator(block: (LinuxTerminalEmulator, MutableList<ByteArray>) -> Unit) {
        val out = CopyOnWriteArrayList<ByteArray>()
        LinuxTerminalEmulator(initialRows = 24, initialCols = 80, onKeyboardInput = { out.add(it) })
            .use { block(it, out) }
    }

    private fun List<ByteArray>.text() = joinToString("") { String(it, Charsets.UTF_8) }

    @Test
    fun `without bracketed paste mode the text goes through bare`() {
        withEmulator { e, out ->
            e.pasteText("ab")
            assertEquals("ab", out.text())
        }
    }

    @Test
    fun `with bracketed paste mode the text is wrapped in the DECSET 2004 markers`() {
        withEmulator { e, out ->
            e.feedOutput("\u001b[?2004h".toByteArray())
            out.clear()
            e.pasteText("ab")
            assertEquals("\u001b[200~ab\u001b[201~", out.text())
        }
    }

    @Test
    fun `turning the mode off again drops the brackets`() {
        withEmulator { e, out ->
            e.feedOutput("\u001b[?2004h".toByteArray())
            e.feedOutput("\u001b[?2004l".toByteArray())
            out.clear()
            e.pasteText("ab")
            assertEquals("ab", out.text())
        }
    }

    @Test
    fun `newlines become carriage returns so a shell sees Enter`() {
        withEmulator { e, out ->
            e.pasteText("one\ntwo\r\nthree")
            assertEquals("one\rtwo\rthree", out.text())
        }
    }

    @Test
    fun `an escape sequence on the clipboard cannot drive the terminal`() {
        withEmulator { e, out ->
            e.pasteText("safe\u001b[2Jtext")
            val s = out.text()
            assertFalse(s.contains('\u001b'), "ESC must be stripped, got ${s.map { it.code }}")
            assertEquals("safe[2Jtext", s)
        }
    }

    @Test
    fun `multi-byte text survives the paste path`() {
        withEmulator { e, out ->
            e.pasteText("héllo → 世界")
            assertEquals("héllo → 世界", out.text())
        }
    }

    @Test
    fun `an empty paste emits nothing even in bracketed mode`() {
        withEmulator { e, out ->
            e.feedOutput("\u001b[?2004h".toByteArray())
            out.clear()
            e.pasteText("")
            assertTrue(out.isEmpty(), "nothing to paste after sanitising, so no brackets either")
        }
    }

    // ---- the pure sanitiser ----

    @Test
    fun `sanitizePaste keeps tabs and drops other controls`() {
        assertEquals("a\tb", LinuxTerminalEmulator.sanitizePaste("a\tb"))
    }

    @Test
    fun `sanitizePaste folds CRLF to one CR`() {
        assertEquals("a\rb\rc", LinuxTerminalEmulator.sanitizePaste("a\r\nb\rc"))
    }
}
