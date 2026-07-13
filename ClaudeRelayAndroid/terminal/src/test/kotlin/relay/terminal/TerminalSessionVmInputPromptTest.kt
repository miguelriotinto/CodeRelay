package relay.terminal

import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Input-prompt silence detector — port of the Swift `detectInputPrompt(_:)`
 * path (TerminalViewModel.swift:245-263), exercised under virtual time.
 *
 * Each test runs in [runTest]; the VM is constructed with `scope = backgroundScope`
 * so its debounce coroutine launches on the test scheduler. `advanceTimeBy`
 * fires the `delay(threshold)` deterministically without any wall-clock wait,
 * and `backgroundScope` auto-cancels the never-firing debounce at test end so a
 * pending timer doesn't keep `runTest` from completing.
 *
 * Production thresholds match Swift exactly: 1000 ms normal, 2000 ms while a
 * coding agent is active.
 */
class TerminalSessionVmInputPromptTest {

    private val ascii = Charsets.US_ASCII

    // Plan case: marks awaiting-input after the silence threshold.
    @Test
    fun marksAwaitingInputAfterSilenceThreshold() = runTest {
        val vm = TerminalSessionVm(scope = backgroundScope)
        vm.onTerminalOutput = { }
        vm.terminalReady()

        vm.receiveOutput("$ ".toByteArray(ascii))
        assertFalse(vm.awaitingInput, "Not awaiting until the silence window elapses")

        advanceTimeBy(1001)
        runCurrent()
        assertTrue(vm.awaitingInput, "1 s of silence should mark the session awaiting input")
    }

    // Plan case: silence just under the threshold does NOT mark awaiting.
    @Test
    fun doesNotMarkAwaitingBeforeThreshold() = runTest {
        val vm = TerminalSessionVm(scope = backgroundScope)
        vm.onTerminalOutput = { }
        vm.terminalReady()

        vm.receiveOutput("x".toByteArray(ascii))
        advanceTimeBy(999)
        runCurrent()

        assertFalse(vm.awaitingInput, "999 ms < 1 s threshold — must not be awaiting yet")
    }

    // Plan case: new output cancels the pending debounce and clears awaiting,
    // then arms a fresh timer.
    @Test
    fun newOutputCancelsPendingAndClearsAwaiting() = runTest {
        val vm = TerminalSessionVm(scope = backgroundScope)
        vm.onTerminalOutput = { }
        vm.terminalReady()

        vm.receiveOutput("x".toByteArray(ascii))
        advanceTimeBy(1001)
        runCurrent()
        assertTrue(vm.awaitingInput, "first chunk + silence → awaiting")

        // Fresh output: clears awaiting IMMEDIATELY (synchronously) and arms a new timer.
        vm.receiveOutput("y".toByteArray(ascii))
        assertFalse(vm.awaitingInput, "new output must clear awaiting at once")

        // The replacement timer still has to elapse before awaiting flips again.
        advanceTimeBy(999)
        runCurrent()
        assertFalse(vm.awaitingInput, "replacement timer not yet elapsed")

        advanceTimeBy(2)
        runCurrent()
        assertTrue(vm.awaitingInput, "fresh timer fires after its own full threshold")
    }

    // Plan case: agent-active uses the 2 s threshold.
    @Test
    fun agentActiveUsesTwoSecondThreshold() = runTest {
        val vm = TerminalSessionVm(scope = backgroundScope)
        vm.onTerminalOutput = { }
        vm.terminalReady()
        vm.isAgentActive = true

        vm.receiveOutput("thinking...".toByteArray(ascii))

        advanceTimeBy(1500)
        runCurrent()
        assertFalse(vm.awaitingInput, "1.5 s < 2 s agent threshold — not awaiting")

        advanceTimeBy(600) // total 2100 ms
        runCurrent()
        assertTrue(vm.awaitingInput, "past 2 s agent threshold → awaiting")
    }

    // Plan case: prepareForSwitch cancels the pending debounce (no spurious awaiting).
    @Test
    fun prepareForSwitchCancelsPendingDebounce() = runTest {
        val vm = TerminalSessionVm(scope = backgroundScope)
        vm.onTerminalOutput = { }
        vm.terminalReady()

        vm.receiveOutput("x".toByteArray(ascii))
        vm.prepareForSwitch()

        advanceTimeBy(5000)
        runCurrent()
        assertFalse(vm.awaitingInput, "switching away must cancel the silence timer")
    }

    // Plan case: prepareForReplay cancels the pending debounce too.
    @Test
    fun prepareForReplayCancelsPendingDebounce() = runTest {
        val vm = TerminalSessionVm(scope = backgroundScope)
        vm.onTerminalOutput = { }
        vm.terminalReady()

        vm.receiveOutput("x".toByteArray(ascii))
        vm.prepareForReplay()

        advanceTimeBy(5000)
        runCurrent()
        assertFalse(vm.awaitingInput, "re-arming for replay must cancel the silence timer")
    }

    // Refresh flicker: the server's width-wiggle repaint emits two frames
    // ~150 ms apart. beginRefreshCoalesce() holds output and flushes the whole
    // burst as ONE delivery so the intermediate narrow frame never renders.
    @Test
    fun refreshCoalescesRepaintBurstIntoSingleDelivery() = runTest {
        val vm = TerminalSessionVm(scope = backgroundScope)
        val received = mutableListOf<ByteArray>()
        vm.onTerminalOutput = { received.add(it) }
        vm.terminalReady()

        vm.beginRefreshCoalesce()
        vm.receiveOutput(byteArrayOf(0x41))   // narrow-width frame
        advanceTimeBy(80); runCurrent()
        vm.receiveOutput(byteArrayOf(0x42))   // full-width frame
        assertTrue(received.isEmpty(), "output must be held while coalescing")

        // Quiet window (220 ms) elapses after the last chunk → single flush.
        advanceTimeBy(230); runCurrent()
        assertEquals(1, received.size, "coalesced refresh delivers exactly once")
        assertEquals("AB", received[0].toString(ascii))

        // Live output resumes immediately after the flush.
        vm.receiveOutput(byteArrayOf(0x43))
        assertEquals(2, received.size)
        assertEquals("C", received[1].toString(ascii))
    }

    // Plan case: onAwaitingInputChanged fires on transitions only (deduped),
    // not repeatedly.
    @Test
    fun onAwaitingInputChangedFiresOnTransitionsOnly() = runTest {
        val vm = TerminalSessionVm(scope = backgroundScope)
        vm.onTerminalOutput = { }
        val events = mutableListOf<Boolean>()
        vm.onAwaitingInputChanged = { events.add(it) }
        vm.terminalReady()

        // First chunk + silence → one `true` transition.
        vm.receiveOutput("a".toByteArray(ascii))
        advanceTimeBy(1001)
        runCurrent()
        assertEquals(listOf(true), events, "exactly one true on first awaiting transition")

        // New output while awaiting → one `false` transition (clear), no extra true.
        vm.receiveOutput("b".toByteArray(ascii))
        runCurrent()
        assertEquals(listOf(true, false), events, "clearing fires exactly one false")

        // Silence again → one more `true`.
        advanceTimeBy(1001)
        runCurrent()
        assertEquals(listOf(true, false, true), events, "re-arming fires one more true")
    }

    // Detector parity: a SECOND chunk before the threshold resets the window —
    // the callback should never fire twice in a row for the same true edge.
    @Test
    fun repeatedOutputBeforeThresholdNeverDoubleFires() = runTest {
        val vm = TerminalSessionVm(scope = backgroundScope)
        vm.onTerminalOutput = { }
        val events = mutableListOf<Boolean>()
        vm.onAwaitingInputChanged = { events.add(it) }
        vm.terminalReady()

        repeat(3) {
            vm.receiveOutput("tick".toByteArray(ascii))
            advanceTimeBy(500) // each < 1 s threshold; resets the window
            runCurrent()
        }
        assertTrue(events.isEmpty(), "no awaiting transition while output keeps arriving")

        advanceTimeBy(1001)
        runCurrent()
        assertEquals(listOf(true), events, "awaiting fires once after the final silence")
    }

    // Empty-data parity: Swift calls detectInputPrompt even for empty chunks, so
    // an empty frame still (re)arms the silence timer.
    @Test
    fun emptyChunkStillArmsSilenceTimer() = runTest {
        val vm = TerminalSessionVm(scope = backgroundScope)
        vm.onTerminalOutput = { }
        vm.terminalReady()

        vm.receiveOutput(ByteArray(0))
        advanceTimeBy(1001)
        runCurrent()
        assertTrue(vm.awaitingInput, "empty frame arms the timer just like any other chunk")
    }
}
