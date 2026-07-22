package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import java.util.UUID

class WorkspaceRollupTest {
    private fun session(agent: String?, state: AgentDetectedState?, dir: String,
                        id: UUID = UUID.randomUUID()) = SessionInfo(
        id = id, name = null, state = SessionState.ACTIVE_ATTACHED, tokenId = "t",
        createdAt = 0.0, cols = 80u, rows = 24u, activity = ActivityState.AGENT_ACTIVE,
        agent = agent, agentState = state, title = null, workingDir = dir)

    @Test fun `blocked is highest severity`() {
        assertEquals(RollupState.BLOCKED,
            WorkspaceRollup.rollupState(session("claude", AgentDetectedState.BLOCKED, "/r"), emptySet()))
    }

    @Test fun `finished unseen vs seen`() {
        val s = session("claude", AgentDetectedState.IDLE, "/r")
        assertEquals(RollupState.FINISHED_UNSEEN, WorkspaceRollup.rollupState(s, setOf(s.id)))
        assertEquals(RollupState.SEEN, WorkspaceRollup.rollupState(s, emptySet()))
    }

    @Test fun `groups by dir and picks worst state`() {
        val a = session("claude", AgentDetectedState.WORKING, "/repo/a")
        val b = session("claude", AgentDetectedState.BLOCKED, "/repo/a")
        val c = session("codex", AgentDetectedState.IDLE, "/repo/b")
        val groups = WorkspaceRollup.group(listOf(a, b, c), emptyMap(), emptySet(),
            groupKey = { it.workingDir ?: "~" }, title = { it.substringAfterLast('/') })
        assertEquals(2, groups.size)
        assertEquals("/repo/a", groups.first().id)
        assertEquals(RollupState.BLOCKED, groups.first().state)
        assertEquals(1, groups.first().attentionCount)
    }

    @Test fun `live agent states override snapshot`() {
        val s = session("claude", AgentDetectedState.WORKING, "/repo/a")
        val groups = WorkspaceRollup.group(listOf(s), mapOf(s.id to AgentDetectedState.BLOCKED),
            emptySet(), groupKey = { it.workingDir ?: "~" }, title = { it })
        assertEquals(RollupState.BLOCKED, groups.first().state)
    }

    @Test fun `live state wins even when snapshot agent is null`() {
        val s = session(null, null, "/repo/a")
        assertEquals(RollupState.BLOCKED,
            WorkspaceRollup.rollupState(s, emptySet(), liveState = AgentDetectedState.BLOCKED))
    }
}
