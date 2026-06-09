package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class EnumsTest {
    @Test fun `session state raw values are hyphenated`() {
        assertEquals("active-attached", SessionState.ACTIVE_ATTACHED.raw)
        assertEquals(SessionState.ACTIVE_DETACHED, SessionState.fromRaw("active-detached"))
    }

    @Test fun `session state terminal set`() {
        assertTrue(SessionState.TERMINATED.isTerminal)
        assertFalse(SessionState.ACTIVE_ATTACHED.isTerminal)
    }

    @Test fun `activity state decodes legacy claude names`() {
        assertEquals(ActivityState.AGENT_ACTIVE, ActivityState.fromRaw("claude_active"))
        assertEquals(ActivityState.AGENT_IDLE, ActivityState.fromRaw("claude_idle"))
        assertEquals(ActivityState.AGENT_ACTIVE, ActivityState.fromRaw("agent_active"))
    }

    @Test fun `activity state unknown defaults to active`() {
        assertEquals(ActivityState.ACTIVE, ActivityState.fromRaw("nonsense"))
    }

    @Test fun `activity state always encodes modern names`() {
        assertEquals("agent_active", ActivityState.AGENT_ACTIVE.raw)
    }

    @Test fun `connection quality thresholds`() {
        assertEquals(ConnectionQuality.EXCELLENT, ConnectionQuality.of(medianRttSec = 0.05, successRate = 1.0))
        assertEquals(ConnectionQuality.GOOD, ConnectionQuality.of(0.2, 0.83))
        assertEquals(ConnectionQuality.POOR, ConnectionQuality.of(0.5, 0.6))
        assertEquals(ConnectionQuality.VERY_POOR, ConnectionQuality.of(0.05, 0.4))
    }
}
