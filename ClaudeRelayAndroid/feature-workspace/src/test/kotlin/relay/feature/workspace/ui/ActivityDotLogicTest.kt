package relay.feature.workspace.ui

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ActivityState

/**
 * Verifies the activity dot color + blink decisions match `ActivityDot.swift`:
 *  - active / idle → green
 *  - agentActive / agentIdle → the agent color
 *  - blink iff agentIdle
 */
class ActivityDotLogicTest {

    @Test
    fun `active and idle are green`() {
        assertEquals(QualityGreen, activityDotColor(ActivityState.ACTIVE, agentId = null))
        assertEquals(QualityGreen, activityDotColor(ActivityState.IDLE, agentId = null))
    }

    @Test
    fun `agent states use the agent color`() {
        assertEquals(agentColor("claude"), activityDotColor(ActivityState.AGENT_ACTIVE, "claude"))
        assertEquals(agentColor("codex"), activityDotColor(ActivityState.AGENT_IDLE, "codex"))
        // Unknown / null agent in an agent state falls back to the codex teal.
        assertEquals(agentColor(null), activityDotColor(ActivityState.AGENT_ACTIVE, null))
    }

    @Test
    fun `blink only on agentIdle`() {
        assertFalse(activityDotShouldBlink(ActivityState.ACTIVE))
        assertFalse(activityDotShouldBlink(ActivityState.IDLE))
        assertFalse(activityDotShouldBlink(ActivityState.AGENT_ACTIVE))
        assertTrue(activityDotShouldBlink(ActivityState.AGENT_IDLE))
    }
}
