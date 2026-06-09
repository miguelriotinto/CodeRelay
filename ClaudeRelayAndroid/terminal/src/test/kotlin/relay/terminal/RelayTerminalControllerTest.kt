package relay.terminal

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Verifies the engine ↔ VM ↔ relay wiring in [RelayTerminalController] against a
 * [FakeTerminalEngine]. This is the device-free half of the iOS
 * `IOSTerminalCoordinator` integration: byte-fidelity output feed, ready-on-
 * first-size, input forwarding, and resize fan-out.
 */
class RelayTerminalControllerTest {

    /** Records every interaction so the wiring can be asserted in isolation. */
    private class FakeTerminalEngine : TerminalEngine {
        val fedOutput = mutableListOf<ByteArray>()
        override var cols: Int = 0
        override var rows: Int = 0
        override var onInput: ((ByteArray) -> Unit)? = null

        override fun feedOutput(bytes: ByteArray) {
            fedOutput.add(bytes)
        }

        override fun resize(cols: Int, rows: Int) {
            this.cols = cols
            this.rows = rows
        }
    }

    private class Harness {
        val engine = FakeTerminalEngine()
        val vm = TerminalSessionVm()
        val sentInput = mutableListOf<ByteArray>()
        val resizes = mutableListOf<Pair<Int, Int>>()
        val controller = RelayTerminalController(
            engine = engine,
            vm = vm,
            onInput = { sentInput.add(it) },
            onResize = { cols, rows -> resizes.add(cols to rows) }
        )
    }

    // (a) Bytes from vm.onTerminalOutput reach engine.feedOutput verbatim.
    @Test
    fun outputBytesReachEngineVerbatim() {
        val h = Harness()
        // Size the terminal so live output flows straight through (not buffered).
        h.controller.reportSize(cols = 80, rows = 24)

        val frame = byteArrayOf(0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x68, 0x69) // ESC[31mhi
        h.vm.receiveOutput(frame)

        assertEquals(1, h.engine.fedOutput.size)
        assertArrayEquals(frame, h.engine.fedOutput[0], "bytes must reach the engine unchanged")
    }

    // (a2) Multi-byte / non-UTF-8 bytes survive the feed without String decoding.
    @Test
    fun outputBytesArePassedThroughWithoutDecoding() {
        val h = Harness()
        h.controller.reportSize(80, 24)

        // A lone continuation byte (0x80) + a high byte (0xFF) — invalid UTF-8 in
        // isolation. A String round-trip would corrupt these; a verbatim feed
        // must not.
        val raw = byteArrayOf(0x80.toByte(), 0xFF.toByte(), 0x00, 0x7F)
        h.vm.receiveOutput(raw)

        assertEquals(1, h.engine.fedOutput.size)
        assertArrayEquals(raw, h.engine.fedOutput[0])
    }

    // (b) First size report calls vm.terminalReady exactly once; second does not re-trigger.
    @Test
    fun firstSizeReportTriggersTerminalReadyExactlyOnce() {
        val h = Harness()

        // Buffer output BEFORE the terminal is ready — it must stay buffered.
        h.vm.receiveOutput(byteArrayOf(0x41))
        assertTrue(h.engine.fedOutput.isEmpty(), "output buffered until terminalReady")

        // First report flushes the buffer (terminalReady fired).
        h.controller.reportSize(80, 24)
        assertEquals(1, h.engine.fedOutput.size, "first size report flushes buffered output")
        assertArrayEquals(byteArrayOf(0x41), h.engine.fedOutput[0])

        // Second report must NOT re-trigger terminalReady: nothing extra flushes.
        h.controller.reportSize(100, 30)
        assertEquals(1, h.engine.fedOutput.size, "second size report must not re-flush")
    }

    // (c) Engine onInput is forwarded to the controller's onInput sink.
    @Test
    fun engineInputIsForwardedToOnInput() {
        val h = Harness()
        val keystroke = "ls -la\r".toByteArray(Charsets.US_ASCII)

        h.engine.onInput?.invoke(keystroke)

        assertEquals(1, h.sentInput.size)
        assertArrayEquals(keystroke, h.sentInput[0])
    }

    // (d) reportSize fires onResize with the right cols/rows AND resizes the engine.
    @Test
    fun reportSizeFiresOnResizeAndResizesEngine() {
        val h = Harness()

        h.controller.reportSize(cols = 120, rows = 40)

        assertEquals(listOf(120 to 40), h.resizes)
        assertEquals(120, h.engine.cols)
        assertEquals(40, h.engine.rows)
    }

    // Non-positive dimensions are ignored (parity with iOS guard) and do NOT
    // count as the first size report.
    @Test
    fun nonPositiveSizeIsIgnoredAndDoesNotMarkReady() {
        val h = Harness()
        h.vm.receiveOutput(byteArrayOf(0x42))

        h.controller.reportSize(0, 24)
        h.controller.reportSize(80, 0)
        h.controller.reportSize(-1, -1)

        assertTrue(h.resizes.isEmpty(), "invalid sizes must not be forwarded")
        assertTrue(h.engine.fedOutput.isEmpty(), "invalid sizes must not trigger terminalReady")

        // A valid report afterwards still works as the first one.
        h.controller.reportSize(80, 24)
        assertEquals(1, h.engine.fedOutput.size)
        assertArrayEquals(byteArrayOf(0x42), h.engine.fedOutput[0])
    }

    // detach() clears the VM callbacks and the engine input sink.
    @Test
    fun detachClearsVmAndEngineWiring() {
        val h = Harness()
        h.controller.reportSize(80, 24)

        h.controller.detach()

        assertNull(h.vm.onTerminalOutput, "prepareForSwitch clears the output handler")
        assertNull(h.engine.onInput, "detach clears the engine input sink")
    }
}
