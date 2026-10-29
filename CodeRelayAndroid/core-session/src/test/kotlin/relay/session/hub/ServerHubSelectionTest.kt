package relay.session.hub

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionConfig
import relay.protocol.SessionRef
import java.util.UUID

/** Port of Swift `ServerHubSelectionTests` + the selection half of `ServerHubFixPassTests`. */
@OptIn(ExperimentalCoroutinesApi::class)
class ServerHubSelectionTest {

    private suspend fun TestScope.liveHub(vararg names: String): Pair<HubHarness, List<ConnectionConfig>> {
        val configs = names.map { cfg(it) }
        val h = HubHarness(hubScope(), configs)
        h.hub.start(); advanceUntilIdle()
        configs.forEach { h.slot(it.id)!!.goLive(listOf(session(), session())) }
        advanceUntilIdle()
        return h to configs
    }

    private fun HubHarness.ref(c: ConnectionConfig, index: Int) = SessionRef(c.id, slot(c.id)!!.sessions.value[index].id)

    @Test fun selectAcrossServersDetachesPreviousBeforeSwitching() = runTest {
        val (h, c) = liveHub("a", "b")
        val log = mutableListOf<String>()
        c.forEach { cfg -> h.slot(cfg.id)!!.log = { log += it } }
        h.hub.select(h.ref(c[0], 0)); advanceUntilIdle(); log.clear()
        h.hub.select(h.ref(c[1], 0)); advanceUntilIdle()
        assertEquals(listOf("detach:a", "switch:b"), log)
        assertNull(h.slot(c[0].id)!!.activeSessionId.value)
        assertEquals(h.ref(c[1], 0), h.hub.activeRef.value)
        assertEquals(h.hub.activeRef.value, h.state.loadActiveRef())
    }

    @Test fun selectingTheActiveRefIsANoOp() = runTest {
        val (h, c) = liveHub("a")
        h.hub.select(h.ref(c[0], 0)); advanceUntilIdle()
        h.hub.select(h.ref(c[0], 0)); advanceUntilIdle()
        assertEquals(1, h.slot(c[0].id)!!.switchedTo.size)
    }

    @Test fun selectWithinOneServerDoesNotDetachThroughTheHub() = runTest {
        val (h, c) = liveHub("a")
        h.hub.select(h.ref(c[0], 0)); advanceUntilIdle()
        h.hub.select(h.ref(c[0], 1)); advanceUntilIdle()
        assertEquals(0, h.slot(c[0].id)!!.detachCount, "the coordinator's own switch detaches its previous session")
        assertEquals(2, h.slot(c[0].id)!!.switchedTo.size)
    }

    @Test fun hungDetachDoesNotBlockTheSwitch() = runTest {
        val (h, c) = liveHub("a", "b")
        h.hub.select(h.ref(c[0], 0)); advanceUntilIdle()
        h.slot(c[0].id)!!.detachHangs = true
        h.hub.select(h.ref(c[1], 0)); advanceUntilIdle()
        assertEquals(listOf(h.ref(c[1], 0).sessionId), h.slot(c[1].id)!!.switchedTo, "bounded by the detach budget")
        h.slot(c[0].id)!!.detachGate.complete(Unit)
    }

    @Test fun selectingOfflineRowIsAppliedWhenServerReturns() = runTest {
        val (h, c) = liveHub("a")
        val a = h.slot(c[0].id)!!
        val ref = h.ref(c[0], 0)
        a.goOffline(); advanceUntilIdle()
        h.hub.select(ref); advanceUntilIdle()
        assertEquals(1, a.recoveryCount)
        assertTrue(a.switchedTo.isEmpty())
        assertEquals(ref, h.hub.activeRef.value, "the cached row shows as selected while its server comes back")
        a.goLive(a.sessions.value); advanceUntilIdle()
        assertEquals(listOf(ref.sessionId), a.switchedTo)
    }

    @Test fun pendingSelectionForAVanishedSessionIsDropped() = runTest {
        val (h, c) = liveHub("a")
        val a = h.slot(c[0].id)!!
        val ref = h.ref(c[0], 0)
        a.goOffline(); advanceUntilIdle()
        h.hub.select(ref); advanceUntilIdle()
        a.goLive(listOf(session())); advanceUntilIdle()
        assertTrue(a.switchedTo.isEmpty())
        assertNull(h.hub.activeRef.value)
        assertEquals("That session has ended", h.hub.notice.value)
    }

    @Test fun createSessionOnAnotherServerDetachesFirst() = runTest {
        val (h, c) = liveHub("a", "b")
        h.hub.select(h.ref(c[0], 0)); advanceUntilIdle()
        val log = mutableListOf<String>()
        c.forEach { cfg -> h.slot(cfg.id)!!.log = { log += it } }
        h.hub.createSession(c[1].id); advanceUntilIdle()
        assertEquals(listOf("detach:a", "create:b"), log)
        assertEquals(c[1].id, h.hub.activeRef.value?.serverId)
    }

    @Test fun createSessionOnAnOfflineServerIsRefused() = runTest {
        val (h, c) = liveHub("a")
        h.slot(c[0].id)!!.goOffline(); advanceUntilIdle()
        h.hub.createSession(c[0].id); advanceUntilIdle()
        assertEquals(0, h.slot(c[0].id)!!.createCount)
        assertEquals("That server is not connected.", h.hub.notice.value)
    }

    @Test fun removeActiveServerDetachesAndClearsActiveRef() = runTest {
        val (h, c) = liveHub("a")
        val a = h.slot(c[0].id)!!
        h.hub.select(h.ref(c[0], 0)); advanceUntilIdle()
        h.hub.removeServer(c[0].id); advanceUntilIdle()
        assertNull(h.hub.activeRef.value)
        assertEquals(1, a.detachCount)
        assertTrue(a.tornDown)
        assertTrue(h.bookmarks.loadAll().isEmpty())
        assertNull(h.tokens.loadToken(c[0].id))
        assertTrue(h.hub.sections.value.isEmpty())
    }

    @Test fun orderedRefsAndNextPreviousWrapAcrossSections() = runTest {
        val (h, c) = liveHub("a", "b")
        val refs = h.hub.orderedRefs
        assertEquals(4, refs.size)
        assertEquals(listOf(c[0].id, c[0].id, c[1].id, c[1].id), refs.map { it.serverId })
        h.hub.select(refs[3]); advanceUntilIdle()
        h.hub.selectNext(); advanceUntilIdle()
        assertEquals(refs[0], h.hub.activeRef.value)
        h.hub.selectPrevious(); advanceUntilIdle()
        assertEquals(refs[3], h.hub.activeRef.value)
    }

    @Test fun startRestoresThePersistedRefOnceItsServerListsIt() = runTest {
        val a = cfg("a"); val s = session()
        val h = HubHarness(hubScope(), listOf(a))
        h.state.saveActiveRef(SessionRef(a.id, s.id))
        h.hub.start(); advanceUntilIdle()
        assertEquals(SessionRef(a.id, s.id), h.hub.activeRef.value)
        h.slot(a.id)!!.goLive(listOf(s)); advanceUntilIdle()
        assertEquals(listOf(s.id), h.slot(a.id)!!.switchedTo)
    }

    @Test fun startDropsAPersistedRefWhoseServerIsDisabled() = runTest {
        val a = cfg("a", enabled = false)
        val h = HubHarness(hubScope(), listOf(a))
        h.state.saveActiveRef(SessionRef(a.id, UUID.randomUUID()))
        h.hub.start(); advanceUntilIdle()
        assertNull(h.hub.activeRef.value)
        assertNull(h.state.loadActiveRef())
    }

    @Test fun overlappingSelectsLeaveExactlyTheLastOneAttached() = runTest {
        val (h, c) = liveHub("a", "b")
        val a = h.slot(c[0].id)!!; val b = h.slot(c[1].id)!!
        h.hub.select(h.ref(c[0], 0)); advanceUntilIdle()
        a.detachHangs = true
        val first = launch { h.hub.select(h.ref(c[1], 0)) }
        runCurrent()           // parked inside the detach on a
        a.detachHangs = false
        h.hub.select(h.ref(c[1], 1)); advanceUntilIdle()
        a.detachGate.complete(Unit)
        first.join(); advanceUntilIdle()
        assertEquals(listOf(h.ref(c[1], 1).sessionId), b.switchedTo, "the stale select must not attach after the newer one won")
        assertEquals(h.ref(c[1], 1), h.hub.activeRef.value)
    }

    @Test fun staleCrossServerSelectDoesNotAttachOnTheAbandonedServer() = runTest {
        val (h, c) = liveHub("a", "b", "c")
        val a = h.slot(c[0].id)!!; val b = h.slot(c[1].id)!!
        h.hub.select(h.ref(c[0], 0)); advanceUntilIdle()
        a.detachHangs = true
        val first = launch { h.hub.select(h.ref(c[1], 0)) }
        runCurrent()
        a.detachHangs = false
        h.hub.select(h.ref(c[2], 0)); advanceUntilIdle()
        a.detachGate.complete(Unit)
        first.join(); advanceUntilIdle()
        assertTrue(b.switchedTo.isEmpty())
        assertEquals(c[2].id, h.hub.activeRef.value?.serverId)
    }

    @Test fun abandonedPendingSelectionIsNotAppliedWhenTheServerReturns() = runTest {
        val (h, c) = liveHub("a", "b")
        val a = h.slot(c[0].id)!!
        val offlineRef = h.ref(c[0], 0)
        a.goOffline(); advanceUntilIdle()
        h.hub.select(offlineRef)
        h.hub.select(h.ref(c[1], 0)); advanceUntilIdle()
        a.goLive(a.sessions.value); advanceUntilIdle()
        assertTrue(a.switchedTo.isEmpty())
        assertEquals(c[1].id, h.hub.activeRef.value?.serverId)
    }

    @Test fun activeRefFollowsACoordinatorThatDetachedOnItsOwn() = runTest {
        val (h, c) = liveHub("a")
        val a = h.slot(c[0].id)!!
        val ref = h.ref(c[0], 0)
        h.hub.select(ref); advanceUntilIdle()
        a.activeSessionId.value = null; a.changed(); advanceUntilIdle()
        assertNull(h.hub.activeRef.value)
        h.hub.select(ref); advanceUntilIdle()
        assertEquals(listOf(ref.sessionId, ref.sessionId), a.switchedTo, "re-selecting the detached row attaches again")
    }

    @Test fun activeRefAdoptsASessionTheCoordinatorAttachedOnItsOwn() = runTest {
        val (h, c) = liveHub("a")
        val a = h.slot(c[0].id)!!
        val id = a.sessions.value[1].id
        a.activeSessionId.value = id; a.changed(); advanceUntilIdle()
        assertEquals(SessionRef(c[0].id, id), h.hub.activeRef.value)
    }

    @Test fun aFailedSwitchLeavesNoStaleHighlight() = runTest {
        val (h, c) = liveHub("a")
        val a = h.slot(c[0].id)!!
        a.switchFails = true
        h.hub.select(h.ref(c[0], 0)); advanceUntilIdle()
        assertNull(h.hub.activeRef.value)
    }

    @Test fun selectingARowOfATokenlessServerIsRefusedWithoutDetaching() = runTest {
        val a = cfg("a"); val b = cfg("b")
        val h = HubHarness(hubScope(), listOf(a, b), tokensFor = setOf(a.id))
        h.hub.start(); advanceUntilIdle()
        h.slot(a.id)!!.goLive(listOf(session())); advanceUntilIdle()
        h.hub.select(SessionRef(a.id, h.slot(a.id)!!.sessions.value[0].id)); advanceUntilIdle()
        h.hub.select(SessionRef(b.id, UUID.randomUUID())); advanceUntilIdle()
        assertEquals(a.id, h.hub.activeRef.value?.serverId)
        assertEquals(0, h.slot(a.id)!!.detachCount)
        assertEquals("b has no token. Re-pair it in Servers.", h.hub.notice.value)
    }

    @Test fun disabledServerKeepsCachedRowsButTheyAreNotSelectable() = runTest {
        val (h, c) = liveHub("a", "b")
        val cached = h.ref(c[1], 0)
        h.hub.setEnabled(c[1].id, false); advanceUntilIdle()
        assertEquals(2, h.hub.sections.value.first { it.id == c[1].id }.sessions.size)
        assertTrue(h.hub.orderedRefs.none { it.serverId == c[1].id })
        h.hub.select(cached); advanceUntilIdle()
        assertEquals("Enable b in Servers to open its sessions.", h.hub.notice.value)
        assertNull(h.hub.activeRef.value)
    }

    @Test fun attachRemoteOnAnotherServerDetachesTheCurrentOneFirst() = runTest {
        // The Attach sheet attaches a session another device owns; with two
        // servers that must still leave exactly one attachment (D9).
        val (h, c) = liveHub("a", "b")
        val a = h.slot(c[0].id)!!; val b = h.slot(c[1].id)!!
        h.hub.select(h.ref(c[0], 0)); advanceUntilIdle()
        val log = mutableListOf<String>(); a.log = { log += it }
        val foreign = UUID.randomUUID()
        h.hub.attachRemote(c[1].id, foreign, "theirs"); advanceUntilIdle()
        assertEquals(listOf("detach:a"), log)
        assertEquals(listOf(foreign), b.remoteAttaches)
        assertEquals(SessionRef(c[1].id, foreign), h.hub.activeRef.value)
    }
}
