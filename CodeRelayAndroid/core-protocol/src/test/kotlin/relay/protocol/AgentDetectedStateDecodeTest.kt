package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class AgentDetectedStateDecodeTest {
    @Test
    fun `fromRaw maps known and unknown`() {
        assertEquals(AgentDetectedState.BLOCKED, AgentDetectedState.fromRaw("blocked"))
        assertEquals(AgentDetectedState.UNKNOWN, AgentDetectedState.fromRaw("nope"))
    }

    @Test
    fun `needsAttention only for blocked`() {
        assertEquals(true, AgentDetectedState.BLOCKED.needsAttention)
        assertEquals(false, AgentDetectedState.IDLE.needsAttention)
    }

    @Test
    fun `session_activity decodes agentState and title`() {
        val json = """{"type":"session_activity","payload":{"sessionId":"12345678-1234-1234-1234-123456789abc","activity":"agent_active","agent":"codex","agentState":"working","title":"build"}}"""
        val msg = MessageEnvelope.decodeServer(json) as ServerMessage.SessionActivity
        assertEquals(AgentDetectedState.WORKING, msg.agentState)
        assertEquals("build", msg.title)
    }

    @Test
    fun `session_activity without new fields decodes to null`() {
        val json = """{"type":"session_activity","payload":{"sessionId":"12345678-1234-1234-1234-123456789abc","activity":"idle"}}"""
        val msg = MessageEnvelope.decodeServer(json) as ServerMessage.SessionActivity
        assertNull(msg.agentState)
        assertNull(msg.title)
    }
}
