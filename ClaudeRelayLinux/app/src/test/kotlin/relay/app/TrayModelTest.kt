package relay.app

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ActivityState
import relay.protocol.AgentDetectedState
import relay.protocol.SessionInfo
import relay.protocol.SessionState
import java.util.UUID

class TrayModelTest {

    private val a: UUID = UUID.fromString("aaaaaaaa-0000-0000-0000-000000000001")
    private val b: UUID = UUID.fromString("bbbbbbbb-0000-0000-0000-000000000002")

    private fun info(id: UUID, name: String? = null) = SessionInfo(
        id = id, name = name, state = SessionState.ACTIVE_ATTACHED, tokenId = "tok",
        createdAt = 0.0, cols = 80u, rows = 24u, activity = ActivityState.ACTIVE, agent = null,
    )

    @Test
    fun `rows carry the state glyph, the name and the active mark`() {
        val model = TrayModel.rows(
            sessions = listOf(info(a), info(b)),
            names = mapOf(a to "api", b to "web"),
            agentStates = mapOf(a to AgentDetectedState.WORKING, b to AgentDetectedState.BLOCKED),
            awaitingInput = emptySet(),
            activeId = a,
        )
        assertEquals(listOf("● api ✓", "◐ web"), model.sessions.map { it.label })
        assertFalse(model.sessions[0].needsAttention)
        assertTrue(model.sessions[1].needsAttention)
    }

    @Test
    fun `awaiting input counts as attention even without an agent state`() {
        val model = TrayModel.rows(listOf(info(a)), mapOf(a to "api"), emptyMap(), setOf(a), null)
        assertEquals("◐ api", model.sessions.single().label)
        assertEquals(1, model.attentionCount)
    }

    @Test
    fun `an idle agent and no agent render differently`() {
        val model = TrayModel.rows(
            listOf(info(a), info(b)), mapOf(a to "x", b to "y"),
            mapOf(a to AgentDetectedState.IDLE), emptySet(), null,
        )
        assertEquals(listOf("○ x", "y"), model.sessions.map { it.label })
    }

    @Test
    fun `falls back to the server name, then the short id`() {
        val model = TrayModel.rows(listOf(info(a, "from-server"), info(b)), emptyMap(), emptyMap(), emptySet(), null)
        assertEquals("from-server", model.sessions[0].label)
        assertEquals(b.toString().take(8), model.sessions[1].label)
    }

    @Test
    fun `tooltip mentions the server and the waiting count`() {
        val model = TrayModel.rows(listOf(info(a)), mapOf(a to "api"), mapOf(a to AgentDetectedState.BLOCKED), emptySet(), null)
        assertEquals("Code[Relay] — mac · 1 waiting", model.tooltip("mac"))
        assertEquals("Code[Relay]", TrayModel().tooltip(null))
    }
}
