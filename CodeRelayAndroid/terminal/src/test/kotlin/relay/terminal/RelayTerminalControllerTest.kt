package relay.terminal

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Verifies the engine ↔ VM ↔ relay wiring in [RelayTerminalController] against a
 * [FakeTerminalEngine]. This is the device-free half of the iOS
 * `IOSTerminalCoordinator` integration: byte-fidelity output feed, ready-on-
 * first-size, input forwarding, and resize fan-out.
 */
@OptIn(ExperimentalCoroutinesApi::class)
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
        // Inject a test-dispatcher scope so the VM's input-prompt debounce
        // `scope.launch` doesn't hit the missing JVM `Dispatchers.Main`. These
        // tests don't advance virtual time, so the debounce never fires and
        // can't affect the wiring assertions.
        val vm = TerminalSessionVm(scope = CoroutineScope(UnconfinedTestDispatcher()))
        val sentInput = mutableListOf<ByteArray>()
        val resizes = mutableListOf<Pair<Int, Int>>()
        val controller = bind(engine)

        /**
         * Binds an ADDITIONAL controller to the same [vm] — the shape a view
         * rebuild takes, since the vm is owned by the coordinator's terminal
         * cache and outlives any single composition.
         */
        fun bind(engine: FakeTerminalEngine) = RelayTerminalController(
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

    // MARK: - Rebind ordering (Android foldable unfold)
    //
    // A fold/unfold destroys and rebuilds the Activity, so the COMPOSITION is
    // rebuilt while the coordinator-cached `TerminalSessionVm` survives. Android
    // overlaps the two Activity instances — the new one's `onCreate`/composition
    // runs BEFORE the old one's `onDestroy` — so the old controller's `detach()`
    // can land AFTER the new controller has already bound to the shared vm.
    // A controller that is no longer the vm's owner must not tear down the
    // wiring that replaced it.

    @Test
    fun detachFromASupersededControllerDoesNotWipeTheNewWiring() {
        val h = Harness()
        h.controller.reportSize(40, 20)

        // The new composition binds first (the overlap).
        val newEngine = FakeTerminalEngine()
        val newController = h.bind(newEngine)
        newController.reportSize(80, 40)

        // ...then the OLD composition's dispose lands on the SAME shared vm.
        h.controller.detach()

        assertNotNull(h.vm.onTerminalOutput, "a superseded detach must not null the new binding")
        assertNotNull(newEngine.onInput, "a superseded detach must not clear the new engine's input sink")

        // Live output must still reach the new emulator: no black screen.
        h.vm.receiveOutput("output after the unfold".toByteArray())
        assertEquals(1, newEngine.fedOutput.size, "live output must reach the new emulator")
        assertArrayEquals("output after the unfold".toByteArray(), newEngine.fedOutput[0])
    }

    // The superseded controller must still release its OWN engine, or termlib's
    // stale emulator keeps a live keystroke path into the connection.
    @Test
    fun detachFromASupersededControllerStillReleasesItsOwnEngine() {
        val h = Harness()
        h.controller.reportSize(40, 20)
        val newEngine = FakeTerminalEngine()
        h.bind(newEngine).reportSize(80, 40)

        h.controller.detach()

        assertNull(h.engine.onInput, "the superseded controller must release its own engine")

        // And that stale engine's keystrokes must no longer reach the relay.
        h.engine.onInput?.invoke("x".toByteArray())
        assertTrue(h.sentInput.isEmpty(), "a superseded engine must not send input")
    }

    // Typing must work after the rebind — the other half of "cannot see any text
    // nor can i input any text".
    @Test
    fun inputStillFlowsFromTheNewEngineAfterASupersededDetach() {
        val h = Harness()
        h.controller.reportSize(40, 20)
        val newEngine = FakeTerminalEngine()
        h.bind(newEngine).reportSize(80, 40)

        h.controller.detach()

        val keystroke = "ls\r".toByteArray(Charsets.US_ASCII)
        newEngine.onInput?.invoke(keystroke)

        assertEquals(1, h.sentInput.size, "the new engine's keystrokes must still reach the relay")
        assertArrayEquals(keystroke, h.sentInput[0])
    }

    // The normal (non-overlapping) dispose-then-init order must keep working:
    // the LAST binder still owns the vm, so its detach is a real teardown.
    @Test
    fun detachFromTheCurrentControllerStillTearsDown() {
        val h = Harness()
        h.controller.reportSize(40, 20)

        val newEngine = FakeTerminalEngine()
        val newController = h.bind(newEngine)
        newController.reportSize(80, 40)

        // Dispose in order this time: the current owner detaches.
        newController.detach()

        assertNull(h.vm.onTerminalOutput, "the current owner's detach must clear the vm wiring")
        assertNull(newEngine.onInput, "the current owner's detach must clear its engine sink")
    }
}
