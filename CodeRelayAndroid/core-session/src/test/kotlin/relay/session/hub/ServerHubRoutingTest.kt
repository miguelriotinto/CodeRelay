package relay.session.hub

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.SessionDeepLink
import relay.protocol.SessionRef
import java.util.UUID

/** Port of Swift `ServerHubRoutingTests` + the deep-link half of `ServerHubFixPassTests`. */
@OptIn(ExperimentalCoroutinesApi::class)
class ServerHubRoutingTest {

    @Test fun instanceIdRoutesToThatServer() = runTest {
        val iid = UUID.randomUUID(); val a = cfg("a"); val b = cfg("b").copy(instanceId = iid)
        val h = HubHarness(hubScope(), listOf(a, b)); h.hub.start(); advanceUntilIdle()
        val s = session(); h.slot(b.id)!!.goLive(listOf(s)); advanceUntilIdle()
        assertEquals(DeepLinkOutcome.Selected(SessionRef(b.id, s.id)), h.hub.handleDeepLink(SessionDeepLink(s.id, iid)))
        advanceUntilIdle()
        assertEquals(listOf(s.id), h.slot(b.id)!!.switchedTo)
    }

    @Test fun deepLinkBeforeStartIsQueuedAndRoutesByInstanceId() = runTest { // Review Focus 1
        val iid = UUID.randomUUID(); val a = cfg("a").copy(instanceId = iid); val b = cfg("b")
        val h = HubHarness(hubScope(), listOf(b, a))
        val target = UUID.randomUUID()
        val routed = async { h.hub.handleDeepLink(SessionDeepLink(target, iid)) }
        advanceUntilIdle()
        assertFalse(routed.isCompleted, "held until start() completes")
        h.hub.start(); advanceUntilIdle()
        assertEquals(DeepLinkOutcome.Selected(SessionRef(a.id, target)), routed.await())
    }

    @Test fun instanceIdOnADisabledBookmarkEnablesItAndDetachesTheCurrentServerFirst() = runTest {
        val iid = UUID.randomUUID(); val a = cfg("a"); val b = cfg("b", enabled = false).copy(instanceId = iid)
        val h = HubHarness(hubScope(), listOf(a, b)); h.hub.start(); advanceUntilIdle()
        val slotA = h.slot(a.id)!!
        slotA.goLive(listOf(session())); advanceUntilIdle()
        h.hub.select(SessionRef(a.id, slotA.sessions.value[0].id)); advanceUntilIdle()
        val target = UUID.randomUUID()
        assertEquals(
            DeepLinkOutcome.EnabledAndSelected(SessionRef(b.id, target)),
            h.hub.handleDeepLink(SessionDeepLink(target, iid)),
        )
        assertEquals(1, slotA.detachCount)
        assertEquals("Enabled b to open this session", h.hub.notice.value)
        assertTrue(h.bookmarks.loadAll().first { it.id == b.id }.enabled)
        advanceUntilIdle()
        h.slot(b.id)!!.goLive(listOf(session(target))); advanceUntilIdle()
        assertEquals(listOf(target), h.slot(b.id)!!.switchedTo, "the pending selection lands once b is live")
    }

    @Test fun anEnabledDuplicateBookmarkWins() = runTest {
        val iid = UUID.randomUUID()
        val off = cfg("off", enabled = false).copy(instanceId = iid); val on = cfg("on").copy(instanceId = iid)
        val h = HubHarness(hubScope(), listOf(off, on)); h.hub.start(); advanceUntilIdle()
        val s = session(); h.slot(on.id)!!.goLive(listOf(s)); advanceUntilIdle()
        assertEquals(DeepLinkOutcome.Selected(SessionRef(on.id, s.id)), h.hub.handleDeepLink(SessionDeepLink(s.id, iid)))
        assertFalse(h.bookmarks.loadAll().first { it.id == off.id }.enabled, "never a second socket to one relay")
    }

    @Test fun uniqueSessionAcrossLiveSectionsRoutesWithoutAServerHint() = runTest {
        val a = cfg("a"); val b = cfg("b"); val h = HubHarness(hubScope(), listOf(a, b)); h.hub.start(); advanceUntilIdle()
        val s = session()
        h.slot(a.id)!!.goLive(listOf(session())); h.slot(b.id)!!.goLive(listOf(s)); advanceUntilIdle()
        assertEquals(DeepLinkOutcome.Selected(SessionRef(b.id, s.id)), h.hub.handleDeepLink(SessionDeepLink(s.id)))
    }

    @Test fun unknownSessionWithOneServerFallsBackToRemoteAttach() = runTest {
        val a = cfg("a"); val h = HubHarness(hubScope(), listOf(a, cfg("off", enabled = false))); h.hub.start(); advanceUntilIdle()
        h.slot(a.id)!!.goLive(emptyList()); advanceUntilIdle()
        val target = UUID.randomUUID()
        assertEquals(DeepLinkOutcome.AttachingRemote(a.id), h.hub.handleDeepLink(SessionDeepLink(target)))
        assertEquals(listOf(target), h.slot(a.id)!!.remoteAttaches)
        assertEquals(SessionRef(a.id, target), h.hub.activeRef.value)
    }

    @Test fun unknownSessionWithSeveralServersIsNotFound() = runTest {
        val h = HubHarness(hubScope(), listOf(cfg("a"), cfg("b"))); h.hub.start(); advanceUntilIdle()
        h.built.forEach { it.goLive(listOf(session())) }; advanceUntilIdle()
        assertEquals(DeepLinkOutcome.NotFound(null), h.hub.handleDeepLink(SessionDeepLink(UUID.randomUUID())))
        assertEquals("Session not found on any enabled server", h.hub.notice.value)
    }

    @Test fun unknownInstanceIdNamesNothingButStillSearchesSessions() = runTest {
        val a = cfg("a"); val b = cfg("b"); val h = HubHarness(hubScope(), listOf(a, b)); h.hub.start(); advanceUntilIdle()
        val s = session()
        h.slot(a.id)!!.goLive(listOf(s)); h.slot(b.id)!!.goLive(emptyList()); advanceUntilIdle()
        assertEquals(
            DeepLinkOutcome.Selected(SessionRef(a.id, s.id)),
            h.hub.handleDeepLink(SessionDeepLink(s.id, UUID.randomUUID())),
        )
    }

    @Test fun deepLinkAfterStartWithOnlyTokenlessServersDoesNotHang() = runTest {
        val h = HubHarness(hubScope(), listOf(cfg("a")), tokensFor = emptySet()); h.hub.start(); advanceUntilIdle()
        assertEquals(
            DeepLinkOutcome.NotFound(null),
            withTimeout(2_000) { h.hub.handleDeepLink(SessionDeepLink(UUID.randomUUID())) },
        )
    }

    @Test fun aColdStartLinkWinsOverTheRestoredSelectionWithoutASecondSwitch() = runTest { // Review Focus 1
        // The saved active ref (F3) and a push-tap link both want server A. The
        // restore used to launch switchToSession(X) during start, and the link's
        // select then ran switchToSession(Y) concurrently on the same coordinator.
        val a = cfg("a"); val x = session(); val y = session()
        val h = HubHarness(hubScope(), listOf(a), liveAtStart = listOf(x, y))
        h.state.saveActiveRef(SessionRef(a.id, x.id))
        val routed = async { h.hub.handleDeepLink(SessionDeepLink(y.id)) }
        h.hub.start(); advanceUntilIdle()
        assertEquals(DeepLinkOutcome.Selected(SessionRef(a.id, y.id)), routed.await())
        assertEquals(listOf(y.id), h.slot(a.id)!!.switchedTo, "only the link's session is switched to")
    }
}
