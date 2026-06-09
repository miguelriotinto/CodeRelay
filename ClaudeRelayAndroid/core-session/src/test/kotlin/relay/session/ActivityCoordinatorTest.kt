package relay.session

import app.cash.turbine.test
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ActivityState
import java.util.UUID

/**
 * Behavioral parity harness for ActivityCoordinator, ported from
 * Sources/ClaudeRelayClient/ViewModels/ActivityCoordinator.swift. Verifies the
 * agent-map put/remove rule, awaiting-input derivation, stolen+unclaim, the
 * persist-on-change contract, and hydrate-from-store on init. Pure-JVM: uses a
 * fake [AgentPersistence] and Turbine for the StateFlows; no Android.
 */
class ActivityCoordinatorTest {

    /** Records every store interaction so tests assert persist-on-change exactly. */
    private class FakePersistence(initial: Map<UUID, String> = emptyMap()) : AgentPersistence {
        private val map = initial.toMutableMap()
        val setAgentCalls = mutableListOf<Pair<UUID, String?>>()
        val unclaimCalls = mutableListOf<UUID>()

        override val agents: Map<UUID, String> get() = map.toMap()

        override fun setAgent(id: UUID, agentId: String?) {
            setAgentCalls.add(id to agentId)
            if (agentId == null) map.remove(id) else map[id] = agentId
        }

        override fun unclaim(id: UUID) {
            unclaimCalls.add(id)
        }
    }

    private val id1 = UUID.randomUUID()
    private val id2 = UUID.randomUUID()

    // applyActivity with agentActive + agent → map has id.
    @Test
    fun `applyActivity agentActive with agent puts id in map`() = runTest {
        val store = FakePersistence()
        val coordinator = ActivityCoordinator(store)

        coordinator.applyActivity(id1, ActivityState.AGENT_ACTIVE, agent = "claude")

        assertEquals(mapOf(id1 to "claude"), coordinator.agentSessions.value)
        assertEquals("claude", coordinator.activeAgent(id1))
        assertTrue(coordinator.isRunningAgent(id1))
        // Persisted on the transition (ActivityCoordinator.swift:103-114).
        assertEquals(listOf(id1 to "claude"), store.setAgentCalls)
        // agentActive (not idle) → not awaiting.
        assertFalse(coordinator.sessionsAwaitingInput.value.contains(id1))
        assertEquals(ActivityState.AGENT_ACTIVE, coordinator.activityState(id1))
    }

    // applyActivity with active + null → map removed (and persisted removal).
    @Test
    fun `applyActivity active with null removes id from map and persists removal`() = runTest {
        val store = FakePersistence(mapOf(id1 to "claude"))
        val coordinator = ActivityCoordinator(store)
        assertEquals(mapOf(id1 to "claude"), coordinator.agentSessions.value)

        coordinator.applyActivity(id1, ActivityState.ACTIVE, agent = null)

        assertTrue(coordinator.agentSessions.value.isEmpty())
        assertFalse(coordinator.isRunningAgent(id1))
        // Removal persisted exactly once (setAgent(id, null)).
        assertEquals(listOf<Pair<UUID, String?>>(id1 to null), store.setAgentCalls)
        assertEquals(ActivityState.ACTIVE, coordinator.activityState(id1))
    }

    // A redundant agentActive update does NOT re-persist (Swift `changed` guard).
    @Test
    fun `redundant agentActive does not re-persist`() = runTest {
        val store = FakePersistence()
        val coordinator = ActivityCoordinator(store)

        coordinator.applyActivity(id1, ActivityState.AGENT_ACTIVE, agent = "claude")
        coordinator.applyActivity(id1, ActivityState.AGENT_ACTIVE, agent = "claude")

        assertEquals(1, store.setAgentCalls.size)
    }

    // applyActivity agentIdle → awaiting-input set contains id (only with an agent).
    @Test
    fun `applyActivity agentIdle marks session awaiting input`() = runTest {
        val store = FakePersistence()
        val coordinator = ActivityCoordinator(store)

        coordinator.applyActivity(id1, ActivityState.AGENT_IDLE, agent = "claude")

        assertTrue(coordinator.sessionsAwaitingInput.value.contains(id1))
        assertTrue(coordinator.isRunningAgent(id1))
        assertEquals(ActivityState.AGENT_IDLE, coordinator.activityState(id1))
    }

    // Awaiting is cleared when the agent exits in the same update (active/null).
    @Test
    fun `awaiting input clears when agent exits`() = runTest {
        val store = FakePersistence()
        val coordinator = ActivityCoordinator(store)
        coordinator.applyActivity(id1, ActivityState.AGENT_IDLE, agent = "claude")
        assertTrue(coordinator.sessionsAwaitingInput.value.contains(id1))

        coordinator.applyActivity(id1, ActivityState.ACTIVE, agent = null)

        assertFalse(coordinator.sessionsAwaitingInput.value.contains(id1))
    }

    // onAgentActiveChange callback fires on enter (true) and exit (false).
    @Test
    fun `onAgentActiveChange fires on enter and exit`() = runTest {
        val store = FakePersistence()
        val coordinator = ActivityCoordinator(store)
        val events = mutableListOf<Pair<UUID, Boolean>>()

        coordinator.applyActivity(id1, ActivityState.AGENT_ACTIVE, "claude") { id, active ->
            events.add(id to active)
        }
        coordinator.applyActivity(id1, ActivityState.IDLE, null) { id, active ->
            events.add(id to active)
        }

        assertEquals(listOf(id1 to true, id1 to false), events)
    }

    // sessionStolen → stolen flag set AND unclaim called AND activity cleared.
    @Test
    fun `sessionStolen sets stolen flag and unclaims`() = runTest {
        val store = FakePersistence(mapOf(id1 to "claude"))
        val coordinator = ActivityCoordinator(store)
        coordinator.applyActivity(id1, ActivityState.AGENT_IDLE, "claude")
        assertTrue(coordinator.sessionsAwaitingInput.value.contains(id1))

        val alert = coordinator.sessionStolen(id1, nameLookup = { "Brave Otter" })

        assertTrue(coordinator.sessionsStolen.value.contains(id1))
        assertEquals(listOf(id1), store.unclaimCalls)
        assertEquals("Brave Otter", alert.sessionName)
        assertEquals(id1.toString().take(8), alert.shortId)
        assertEquals(alert, coordinator.stolenAlert.value)
        // Activity state cleared on steal.
        assertFalse(coordinator.agentSessions.value.containsKey(id1))
        assertFalse(coordinator.sessionsAwaitingInput.value.contains(id1))
    }

    // clearStolen dismisses the flag + alert.
    @Test
    fun `clearStolen dismisses flag and alert`() = runTest {
        val store = FakePersistence()
        val coordinator = ActivityCoordinator(store)
        coordinator.sessionStolen(id1)
        assertTrue(coordinator.sessionsStolen.value.contains(id1))

        coordinator.clearStolen(id1)

        assertFalse(coordinator.sessionsStolen.value.contains(id1))
        assertNull(coordinator.stolenAlert.value)
    }

    // forgetSession → removed from every map/set.
    @Test
    fun `forgetSession removes from all maps and sets`() = runTest {
        val store = FakePersistence(mapOf(id1 to "claude"))
        val coordinator = ActivityCoordinator(store)
        coordinator.applyActivity(id1, ActivityState.AGENT_IDLE, "claude")
        coordinator.sessionStolen(id1)

        coordinator.forgetSession(id1)

        assertFalse(coordinator.agentSessions.value.containsKey(id1))
        assertFalse(coordinator.sessionsAwaitingInput.value.contains(id1))
        assertFalse(coordinator.sessionsStolen.value.contains(id1))
        assertNull(coordinator.stolenAlert.value)
    }

    // hydrate from store on init populates the agent map.
    @Test
    fun `init hydrates agent map from store`() = runTest {
        val store = FakePersistence(mapOf(id1 to "claude", id2 to "codex"))
        val coordinator = ActivityCoordinator(store)

        assertEquals(mapOf(id1 to "claude", id2 to "codex"), coordinator.agentSessions.value)
        assertTrue(coordinator.isRunningAgent(id1))
        assertTrue(coordinator.isRunningAgent(id2))
    }

    // applyPrunedAgents drops dangling awaiting-input entries.
    @Test
    fun `applyPrunedAgents drops awaiting entries for removed sessions`() = runTest {
        val store = FakePersistence()
        val coordinator = ActivityCoordinator(store)
        coordinator.applyActivity(id1, ActivityState.AGENT_IDLE, "claude")
        coordinator.applyActivity(id2, ActivityState.AGENT_IDLE, "claude")

        coordinator.applyPrunedAgents(setOf(id1))

        assertFalse(coordinator.sessionsAwaitingInput.value.contains(id1))
        assertTrue(coordinator.sessionsAwaitingInput.value.contains(id2))
    }

    // StateFlow emits the expected sequence (Turbine).
    @Test
    fun `agentSessions StateFlow emits put then remove`() = runTest {
        val store = FakePersistence()
        val coordinator = ActivityCoordinator(store)

        coordinator.agentSessions.test {
            assertTrue(awaitItem().isEmpty()) // initial
            coordinator.applyActivity(id1, ActivityState.AGENT_ACTIVE, "claude")
            assertEquals(mapOf(id1 to "claude"), awaitItem())
            coordinator.applyActivity(id1, ActivityState.ACTIVE, null)
            assertTrue(awaitItem().isEmpty())
            cancelAndIgnoreRemainingEvents()
        }
    }
}
