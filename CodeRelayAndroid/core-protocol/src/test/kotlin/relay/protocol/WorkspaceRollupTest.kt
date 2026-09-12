package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import java.util.UUID

class WorkspaceRollupTest {
    private fun session(agent: String?, state: AgentDetectedState?, dir: String?,
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

    // Ordering — parity with Swift `WorkspaceRollupTests`. Every case is built so
    // alphabetical and severity ordering disagree, so the old worst-state-first
    // comparator fails each one.

    private fun titles(sessions: List<SessionInfo>) =
        WorkspaceRollup.group(sessions, emptyMap(), emptySet(),
            groupKey = { it.workingDir ?: WorkspaceRollup.OTHER_GROUP_KEY },
            title = {
                if (it == WorkspaceRollup.OTHER_GROUP_KEY) {
                    WorkspaceRollup.OTHER_TITLE
                } else {
                    it.substringAfterLast('/')
                }
            }).map { it.title }

    @Test fun `order is alphabetical not by severity`() {
        val alpha = session("claude", AgentDetectedState.IDLE, "/repo/alpha")
        val zeta = session("claude", AgentDetectedState.BLOCKED, "/repo/zeta")
        assertEquals(listOf("alpha", "zeta"), titles(listOf(zeta, alpha)))
    }

    @Test fun `order is stable across state changes`() {
        val quiet = titles(listOf(
            session("claude", AgentDetectedState.IDLE, "/repo/alpha"),
            session("claude", AgentDetectedState.BLOCKED, "/repo/zeta")))
        val flipped = titles(listOf(
            session("claude", AgentDetectedState.BLOCKED, "/repo/alpha"),
            session("claude", AgentDetectedState.IDLE, "/repo/zeta")))
        assertEquals(quiet, flipped)
    }

    @Test fun `order is case insensitive`() {
        val zebra = session("claude", AgentDetectedState.IDLE, "/repo/Zebra")
        val apple = session("claude", AgentDetectedState.IDLE, "/repo/apple")
        assertEquals(listOf("apple", "Zebra"), titles(listOf(zebra, apple)))
    }

    @Test fun `order is natural numeric`() {
        val nine = session("claude", AgentDetectedState.IDLE, "/w/repo9")
        val ten = session("claude", AgentDetectedState.IDLE, "/w/repo10")
        assertEquals(listOf("repo9", "repo10"), titles(listOf(ten, nine)))
    }

    @Test fun `other group is pinned last regardless of state`() {
        val homeless = session("claude", AgentDetectedState.BLOCKED, null)
        val zeta = session("claude", AgentDetectedState.IDLE, "/repo/zeta")
        val alpha = session("claude", AgentDetectedState.IDLE, "/repo/alpha")
        assertEquals(listOf("alpha", "zeta", "Other"), titles(listOf(homeless, zeta, alpha)))
    }

    @Test fun `repo literally named Other still sorts alphabetically`() {
        val other = session("claude", AgentDetectedState.IDLE, "/repo/Other")
        val zeta = session("claude", AgentDetectedState.IDLE, "/repo/zeta")
        assertEquals(listOf("Other", "zeta"), titles(listOf(zeta, other)))
    }

    @Test fun `order is total for duplicate titles`() {
        val work = session("claude", AgentDetectedState.IDLE, "/work/app")
        val fork = session("claude", AgentDetectedState.BLOCKED, "/fork/app")
        val groups = WorkspaceRollup.group(listOf(work, fork), emptyMap(), emptySet(),
            groupKey = { it.workingDir ?: "~" }, title = { it.substringAfterLast('/') })
        assertEquals(listOf("app", "app"), groups.map { it.title })
        assertEquals(listOf("/fork/app", "/work/app"), groups.map { it.id })
    }

    @Test fun `natural comparison matches localizedStandardCompare semantics`() {
        // Direct unit coverage of the hand-written comparator: the JVM has no
        // single case-insensitive + natural-numeric comparison, so this is the
        // part most at risk of drifting from Swift's Foundation behaviour.
        fun sign(a: String, b: String) = WorkspaceRollup.compareNaturally(a, b).let {
            if (it < 0) -1 else if (it > 0) 1 else 0
        }
        assertEquals(-1, sign("apple", "Zebra"))       // case-insensitive
        assertEquals(-1, sign("repo9", "repo10"))      // numeric, not lexical
        assertEquals(-1, sign("repo02", "repo3"))      // leading zeros ignored
        assertEquals(0, sign("Repo", "repo"))          // equal ignoring case
        assertEquals(-1, sign("repo", "repo1"))        // prefix sorts first
        assertEquals(1, sign("repo10a", "repo10"))     // longer suffix sorts after
    }
}
