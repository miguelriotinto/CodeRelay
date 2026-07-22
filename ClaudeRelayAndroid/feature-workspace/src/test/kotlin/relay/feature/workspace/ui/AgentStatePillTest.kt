package relay.feature.workspace.ui

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import relay.protocol.AgentDetectedState
import relay.protocol.SessionState

class AgentStatePillTest {
    @Test fun words() {
        assertEquals("Waiting", agentStateWord(AgentDetectedState.IDLE))
        assertEquals("Working", agentStateWord(AgentDetectedState.WORKING))
        assertEquals("Blocked", agentStateWord(AgentDetectedState.BLOCKED))
        assertEquals("Unknown", agentStateWord(AgentDetectedState.UNKNOWN))
    }
    @Test fun blockedIsRed() {
        assertEquals(QualityRed, agentStatePillColor(AgentDetectedState.BLOCKED, "claude", true))
    }
    @Test fun workingIsAgentColor() {
        assertEquals(agentColor("claude"), agentStatePillColor(AgentDetectedState.WORKING, "claude", true))
    }
    @Test fun waitingSeenGreenUnseenTeal() {
        assertEquals(QualityGreen, agentStatePillColor(AgentDetectedState.IDLE, "claude", true))
        assertEquals(DoneTeal, agentStatePillColor(AgentDetectedState.IDLE, "claude", false))
    }
    @Test fun dotColorAttachedGreenDetachedYellowTerminalNull() {
        assertEquals(QualityGreen, sessionStatusDotColor(SessionState.ACTIVE_ATTACHED))
        assertEquals(QualityYellow, sessionStatusDotColor(SessionState.ACTIVE_DETACHED))
        assertNull(sessionStatusDotColor(SessionState.EXITED))
    }
}
