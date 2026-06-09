package relay.feature.workspace.ui

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import relay.protocol.SessionState

/**
 * Verifies [WorkspaceLogic.formatUptime] matches `ActiveTerminalView.swift`'s
 * `formatUptime` format exactly (`%dd %02d:%02d:%02d` with days, else
 * `%02d:%02d:%02d`), and the sidebar state-badge bucketing.
 */
class WorkspaceLogicTest {

    @Test
    fun `formatUptime zero`() {
        assertEquals("00:00:00", WorkspaceLogic.formatUptime(0))
    }

    @Test
    fun `formatUptime 65 seconds`() {
        assertEquals("00:01:05", WorkspaceLogic.formatUptime(65))
    }

    @Test
    fun `formatUptime one hour`() {
        assertEquals("01:00:00", WorkspaceLogic.formatUptime(3_600))
    }

    @Test
    fun `formatUptime just under a day`() {
        // 23:59:59 = 86399s — still no day prefix.
        assertEquals("23:59:59", WorkspaceLogic.formatUptime(86_399))
    }

    @Test
    fun `formatUptime one day one hour one minute one second`() {
        // 90061 = 1*86400 + 1*3600 + 1*60 + 1
        assertEquals("1d 01:01:01", WorkspaceLogic.formatUptime(90_061))
    }

    @Test
    fun `formatUptime multiple days`() {
        // 2*86400 + 3*3600 + 4*60 + 5 = 183845
        assertEquals("2d 03:04:05", WorkspaceLogic.formatUptime(183_845))
    }

    @Test
    fun `formatUptime clamps negative to zero`() {
        assertEquals("00:00:00", WorkspaceLogic.formatUptime(-42))
    }

    @Test
    fun `badge bucket green for active states`() {
        assertEquals(WorkspaceLogic.BadgeBucket.GREEN, WorkspaceLogic.badgeBucket(SessionState.ACTIVE_ATTACHED))
        assertEquals(WorkspaceLogic.BadgeBucket.GREEN, WorkspaceLogic.badgeBucket(SessionState.ACTIVE_DETACHED))
    }

    @Test
    fun `badge bucket yellow for transitional states`() {
        assertEquals(WorkspaceLogic.BadgeBucket.YELLOW, WorkspaceLogic.badgeBucket(SessionState.CREATED))
        assertEquals(WorkspaceLogic.BadgeBucket.YELLOW, WorkspaceLogic.badgeBucket(SessionState.STARTING))
        assertEquals(WorkspaceLogic.BadgeBucket.YELLOW, WorkspaceLogic.badgeBucket(SessionState.RESUMING))
    }

    @Test
    fun `badge bucket red for terminal states`() {
        assertEquals(WorkspaceLogic.BadgeBucket.RED, WorkspaceLogic.badgeBucket(SessionState.EXITED))
        assertEquals(WorkspaceLogic.BadgeBucket.RED, WorkspaceLogic.badgeBucket(SessionState.FAILED))
        assertEquals(WorkspaceLogic.BadgeBucket.RED, WorkspaceLogic.badgeBucket(SessionState.TERMINATED))
        assertEquals(WorkspaceLogic.BadgeBucket.RED, WorkspaceLogic.badgeBucket(SessionState.EXPIRED))
    }

    // MARK: - utteranceInputBytes (the sendInput(String) overload's core logic)

    @Test
    fun `utteranceInputBytes encodes plain ascii as UTF-8`() {
        assertArrayEquals("ls -la".toByteArray(Charsets.UTF_8), WorkspaceLogic.utteranceInputBytes("ls -la"))
    }

    @Test
    fun `utteranceInputBytes encodes multibyte UTF-8`() {
        // A non-ASCII utterance must round-trip as multi-byte UTF-8, not be lost.
        val text = "café — naïve 你好"
        assertArrayEquals(text.toByteArray(Charsets.UTF_8), WorkspaceLogic.utteranceInputBytes(text))
    }

    @Test
    fun `utteranceInputBytes skips empty text`() {
        assertNull(WorkspaceLogic.utteranceInputBytes(""))
    }

    @Test
    fun `utteranceInputBytes skips whitespace-only text`() {
        // Mirrors the onUtteranceReady blank-skip + iOS `!text.isEmpty` guard.
        assertNull(WorkspaceLogic.utteranceInputBytes("   "))
        assertNull(WorkspaceLogic.utteranceInputBytes("\n\t  "))
    }

    @Test
    fun `utteranceInputBytes keeps text with surrounding whitespace`() {
        // Non-blank text is sent VERBATIM (no trim) — leading/trailing spaces in a
        // real command (e.g. a trailing newline the engine may include) are
        // preserved; only entirely-blank text is dropped.
        val text = " echo hi "
        assertArrayEquals(text.toByteArray(Charsets.UTF_8), WorkspaceLogic.utteranceInputBytes(text))
    }
}
