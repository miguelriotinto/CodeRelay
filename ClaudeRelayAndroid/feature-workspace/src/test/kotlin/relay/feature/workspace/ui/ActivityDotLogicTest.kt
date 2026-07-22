package relay.feature.workspace.ui

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ActivityState
import relay.protocol.AgentDetectedState

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

    @Test
    fun `phase2 color map`() {
        assertEquals(QualityRed, activityDotColor(ActivityState.AGENT_IDLE, "claude", AgentDetectedState.BLOCKED, seen = false))
        assertEquals(agentColor("claude"), activityDotColor(ActivityState.AGENT_ACTIVE, "claude", AgentDetectedState.WORKING))
        assertEquals(DoneTeal, activityDotColor(ActivityState.AGENT_IDLE, "claude", AgentDetectedState.IDLE, seen = false))
        assertEquals(QualityGreen, activityDotColor(ActivityState.AGENT_IDLE, "claude", AgentDetectedState.IDLE, seen = true))
        assertEquals(UnknownGray, activityDotColor(ActivityState.AGENT_ACTIVE, "claude", AgentDetectedState.UNKNOWN))
    }

    @Test
    fun `phase2 blink only on blocked`() {
        assertTrue(activityDotShouldBlink(ActivityState.AGENT_IDLE, AgentDetectedState.BLOCKED))
        assertFalse(activityDotShouldBlink(ActivityState.AGENT_IDLE, AgentDetectedState.WORKING))
        assertFalse(activityDotShouldBlink(ActivityState.AGENT_IDLE, AgentDetectedState.IDLE))
    }

    @Test
    fun `null agentState falls back to legacy`() {
        assertEquals(QualityGreen, activityDotColor(ActivityState.IDLE, null, null))
        assertTrue(activityDotShouldBlink(ActivityState.AGENT_IDLE, null))
    }
}
