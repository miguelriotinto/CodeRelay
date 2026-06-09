package relay.terminal

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Ported from the iOS suite `Tests/ClaudeRelayClientTests/TerminalViewModelTests.swift`.
 * Each test name maps to the Swift case it mirrors. Cases that depend on
 * `RelayConnection` (send-suppression, UTF-8 encoding) or the M4 input-prompt
 * silence detector are intentionally NOT ported here — they live in :core-net /
 * are M4 Task 3.
 */
class TerminalSessionVmTest {

    private fun makeVm() = TerminalSessionVm()

    // Mirrors `testBuffersOutputBeforeTerminalReady`.
    @Test
    fun buffersOutputBeforeTerminalReady() {
        val vm = makeVm()
        val received = mutableListOf<ByteArray>()
        vm.onTerminalOutput = { received.add(it) }

        vm.receiveOutput(byteArrayOf(0x41))
        vm.receiveOutput(byteArrayOf(0x42))

        assertTrue(received.isEmpty(), "Output should be buffered until terminalReady()")
    }

    // Mirrors `testTerminalReadyFlushesBuffer`.
    @Test
    fun terminalReadyFlushesBuffer() {
        val vm = makeVm()
        val received = mutableListOf<ByteArray>()
        vm.onTerminalOutput = { received.add(it) }

        vm.receiveOutput(byteArrayOf(0x41))
        vm.receiveOutput(byteArrayOf(0x42))
        vm.terminalReady()

        assertEquals(1, received.size)
        assertArrayEquals(byteArrayOf(0x41, 0x42), received[0])
    }

    // Mirrors `testOutputForwardedAfterReady`.
    @Test
    fun outputForwardedAfterReady() {
        val vm = makeVm()
        val received = mutableListOf<ByteArray>()
        vm.onTerminalOutput = { received.add(it) }
        vm.terminalReady()

        vm.receiveOutput(byteArrayOf(0x43))

        assertEquals(1, received.size)
        assertArrayEquals(byteArrayOf(0x43), received[0])
    }

    // Mirrors `testTerminalReadyIsIdempotent`.
    @Test
    fun terminalReadyIsIdempotent() {
        val vm = makeVm()
        var count = 0
        vm.onTerminalOutput = { count += 1 }

        vm.receiveOutput(byteArrayOf(0x41))
        vm.terminalReady()
        vm.terminalReady()

        assertEquals(1, count, "Second terminalReady should be a no-op")
    }

    // Mirrors `testPrepareForSwitchClearsState`.
    @Test
    fun prepareForSwitchClearsState() {
        val vm = makeVm()
        vm.onTerminalOutput = { }
        vm.onAwaitingInputChanged = { }
        vm.terminalReady()
        vm.receiveOutput(byteArrayOf(0x41))

        vm.prepareForSwitch()

        assertNull(vm.onTerminalOutput)
        assertNull(vm.onAwaitingInputChanged)
    }

    // Mirrors `testPrepareForReplayThenTerminalReadySendsRIS`.
    @Test
    fun prepareForReplayThenTerminalReadySendsRIS() {
        val vm = makeVm()
        vm.onTerminalOutput = { }
        vm.terminalReady()
        vm.receiveOutput(byteArrayOf(0x41))

        vm.prepareForReplay()

        assertNull(vm.onTerminalOutput)
        assertNull(vm.onAwaitingInputChanged)

        // Mirror coordinator flow: beginReplay -> wire handler -> terminalReady.
        // terminalReady detects isReplaying and immediately feeds RIS.
        vm.beginReplay()
        val received = mutableListOf<ByteArray>()
        vm.onTerminalOutput = { received.add(it) }
        vm.terminalReady()

        assertEquals(1, received.size)
        assertArrayEquals(ReplayProtocol.RIS, received[0])
    }

    // Mirrors `testResetForReplaySendsRIS`.
    @Test
    fun resetForReplaySendsRIS() {
        val vm = makeVm()
        val received = mutableListOf<ByteArray>()
        vm.onTerminalOutput = { received.add(it) }
        vm.terminalReady()

        vm.resetForReplay()

        assertEquals(1, received.size)
        assertArrayEquals(ReplayProtocol.RIS, received[0])
    }

    // Plan case: replay buffers then flushes a SINGLE contiguous blob on endReplay.
    @Test
    fun endReplayFlushesSingleContiguousBlob() {
        val vm = makeVm()
        vm.onTerminalOutput = { }
        vm.terminalReady()

        // Re-arm for replay (clears the handler), then re-wire and begin replay.
        vm.prepareForReplay()
        vm.beginReplay()
        val received = mutableListOf<ByteArray>()
        vm.onTerminalOutput = { received.add(it) }
        // terminalReady during replay emits RIS only — drop it so we can assert
        // the flush blob in isolation.
        vm.terminalReady()
        received.clear()

        vm.receiveOutput("foo".toByteArray(Charsets.US_ASCII))
        vm.receiveOutput("bar".toByteArray(Charsets.US_ASCII))
        // Still buffered while replaying.
        assertTrue(received.isEmpty(), "Output must stay buffered until endReplay()")

        vm.endReplay()

        assertEquals(1, received.size, "endReplay must flush exactly ONE contiguous blob")
        assertArrayEquals("foobar".toByteArray(Charsets.US_ASCII), received[0])
    }

    // Plan case: terminalReady during replay emits RIS only (one emit == RIS).
    @Test
    fun terminalReadyDuringReplayEmitsRisOnly() {
        val vm = makeVm()
        vm.beginReplay()
        val received = mutableListOf<ByteArray>()
        vm.onTerminalOutput = { received.add(it) }

        // Buffer something so we can prove it is NOT flushed here.
        vm.receiveOutput(byteArrayOf(0x41, 0x42))
        vm.terminalReady()

        assertEquals(1, received.size, "terminalReady during replay emits exactly one frame")
        assertArrayEquals(ReplayProtocol.RIS, received[0], "and that frame is RIS, not the buffer")
    }

    // Plan case: pending buffer drops oldest beyond 4MB.
    // Mirrors `testPendingOutputByteCapEvictsOldest` /
    // `testPendingOutputOverCapDropsOldestChunks`.
    @Test
    fun pendingBufferDropsOldestBeyondCap() {
        val vm = makeVm()
        val chunk = ByteArray(64 * 1024) { 0x41 } // 64 KB
        repeat(80) { vm.receiveOutput(chunk) }    // 5 MB > 4 MB cap

        val received = mutableListOf<ByteArray>()
        vm.onTerminalOutput = { received.add(it) }
        vm.terminalReady()

        val total = received.sumOf { it.size }
        assertTrue(
            total <= 4 * 1024 * 1024 + chunk.size,
            "Total delivered should stay within cap + one head-chunk slack (was $total)"
        )
        assertTrue(
            total > 3 * 1024 * 1024,
            "cap should keep at least ~3 MB of recent output (was $total)"
        )
    }

    // Boundary case: exactly at the 4 MB cap must not evict anything.
    // Mirrors `testPendingOutputExactlyAtCapDoesNotEvict`.
    @Test
    fun pendingBufferExactlyAtCapDoesNotEvict() {
        val vm = makeVm()
        val chunk = ByteArray(1024 * 1024) { 0x42 } // 1 MB
        repeat(4) { vm.receiveOutput(chunk) }        // 4 MB, exactly at cap

        val received = mutableListOf<ByteArray>()
        vm.onTerminalOutput = { received.add(it) }
        vm.terminalReady()

        val total = received.sumOf { it.size }
        assertEquals(
            4 * 1024 * 1024, total,
            "All 4 MB should be preserved when buffer is at cap (but not over)"
        )
    }

    // Mirrors `testReceiveOutputEmptyDataNoCrash`.
    @Test
    fun receiveOutputEmptyDataNoCrash() {
        val vm = makeVm()
        val received = mutableListOf<ByteArray>()
        vm.onTerminalOutput = { received.add(it) }
        vm.terminalReady()

        vm.receiveOutput(ByteArray(0))
        // Should not crash. An empty live frame is forwarded as-is (parity with
        // Swift, which calls the handler unconditionally on the live path).
    }

    // endReplay before terminalReady: nothing flushes (terminal not sized yet),
    // and the buffer survives to be flushed by terminalReady.
    @Test
    fun endReplayBeforeTerminalReadyDefersFlush() {
        val vm = makeVm()
        val received = mutableListOf<ByteArray>()
        vm.onTerminalOutput = { received.add(it) }

        vm.beginReplay()
        vm.receiveOutput("foo".toByteArray(Charsets.US_ASCII))
        vm.receiveOutput("bar".toByteArray(Charsets.US_ASCII))

        // endReplay while NOT sized: must not emit; buffer is retained.
        vm.endReplay()
        assertTrue(received.isEmpty(), "endReplay before terminalReady must not flush")

        // terminalReady (no longer replaying) flushes the retained buffer once.
        vm.terminalReady()
        assertEquals(1, received.size)
        assertArrayEquals("foobar".toByteArray(Charsets.US_ASCII), received[0])
    }

    // endReplay is a no-op when not replaying (guard parity with Swift).
    @Test
    fun endReplayWhenNotReplayingIsNoOp() {
        val vm = makeVm()
        val received = mutableListOf<ByteArray>()
        vm.onTerminalOutput = { received.add(it) }
        vm.terminalReady()

        vm.endReplay()

        assertTrue(received.isEmpty(), "endReplay without an active replay must do nothing")
    }
}
