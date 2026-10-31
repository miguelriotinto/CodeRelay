package relay.session.hub

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNotSame
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ServerIdentity
import java.util.UUID

/** Port of Swift `ServerHubTests` + the lifecycle half of `ServerHubFixPassTests`. */
@OptIn(ExperimentalCoroutinesApi::class)
class ServerHubTest {

    @Test fun startBuildsOneSlotPerEnabledBookmarkWithAStagger() = runTest {
        val h = HubHarness(hubScope(), listOf(cfg("a"), cfg("b", enabled = false), cfg("c")))
        h.hub.start(); advanceUntilIdle()
        assertEquals(listOf("a", "c"), h.built.map { it.config.name })
        assertEquals(listOf(0L, 150L), h.sleeps)
        assertEquals(3, h.hub.sections.value.size)
        assertEquals(ServerSectionStatus.Disabled, h.hub.sections.value[1].status)
    }

    @Test fun aSlowServerStartDoesNotDelayTheOthers() = runTest {
        val slow = cfg("slow"); val fast = cfg("fast")
        val h = HubHarness(hubScope(), listOf(slow, fast), hangs = setOf(slow.id))
        val starting = launch { h.hub.start() }
        advanceUntilIdle()
        assertEquals(1, h.built.first { it.config.name == "fast" }.startCount, "built while the slow relay is still parked")
        assertFalse(starting.isCompleted)
        h.built.first { it.config.name == "slow" }.startGate.complete(Unit)
        starting.join()
    }

    @Test fun liveSlotPublishesItsSessionsAndOfflineKeepsThemCached() = runTest {
        val a = cfg("a"); val h = HubHarness(hubScope(), listOf(a)); h.hub.start(); advanceUntilIdle()
        val s = session()
        h.slot(a.id)!!.goLive(listOf(s)); advanceUntilIdle()
        assertEquals(ServerSectionStatus.Live, h.hub.sections.value[0].status)
        assertEquals(1, h.hub.aggregate.value.liveServers)
        h.slot(a.id)!!.goOffline(); advanceUntilIdle()
        val sec = h.hub.sections.value[0]
        assertEquals(ServerSectionStatus.Offline, sec.status)
        assertTrue(sec.isCached)
        assertEquals(listOf(s.id), sec.sessions.map { it.id })
        assertEquals(0, h.hub.aggregate.value.liveServers)
    }

    @Test fun missingTokenBecomesAuthFailedSection() = runTest {
        val a = cfg("a"); val h = HubHarness(hubScope(), listOf(a), tokensFor = emptySet())
        h.hub.start(); advanceUntilIdle()
        assertNull(h.slot(a.id))
        assertEquals(ServerSectionStatus.AuthFailed("No token stored for this server"), h.hub.sections.value[0].status)
    }

    @Test fun tokenLookupThatThrowsBecomesAuthFailed() = runTest { // Review Focus 5
        val a = cfg("a"); val h = HubHarness(hubScope(), listOf(a))
        h.tokens.throwsFor = setOf(a.id)
        h.hub.start(); advanceUntilIdle()
        assertEquals(ServerSectionStatus.AuthFailed("No token stored for this server"), h.hub.sections.value[0].status)
    }

    @Test fun aSlotWhoseStartThrowsStaysInTheHub() = runTest {
        // A rejected token makes the coordinator's connect() throw; the section
        // must still render (authFailed from the coordinator's own flag).
        val a = cfg("a")
        val h = HubHarness(hubScope(), listOf(a))
        val hub = ServerHub(hubScope(), h.bookmarks, h.tokens, h.state, factory = { c, _ ->
            object : ServerSlot by FakeServerSlot(c) {
                override suspend fun start(reason: relay.session.SessionHandshake.Reason) { error("Authentication failed: bad token") }
            }
        }, sleepMs = {})
        hub.start(); advanceUntilIdle()
        assertNotNull(hub.slot(a.id))
    }

    @Test fun capRefusesTheNinthServerWithANotice() = runTest {
        val configs = (1..9).map { cfg("s$it", enabled = it <= 8) }
        val h = HubHarness(hubScope(), configs); h.hub.start(); advanceUntilIdle()
        assertFalse(h.hub.setEnabled(configs[8].id, true))
        assertEquals("Up to 8 servers can be enabled at once. Disable one first.", h.hub.notice.value)
    }

    @Test fun reloadAtTheCapDisablesTheNewBookmarkWithANotice() = runTest {
        val h = HubHarness(hubScope(), listOf(cfg("a"), cfg("b")), maxEnabled = 2); h.hub.start(); advanceUntilIdle()
        val c = cfg("c"); h.bookmarks.add(c); h.tokens.tokens[c.id] = "t"
        h.hub.reloadBookmarks(); advanceUntilIdle()
        assertFalse(h.bookmarks.loadAll().first { it.id == c.id }.enabled)
        assertNull(h.slot(c.id))
        assertEquals("Up to 2 servers can be enabled at once. c was added disabled.", h.hub.notice.value)
    }

    @Test fun reloadBuildsNewAndRebuildsEditedAndRetiresRemoved() = runTest {
        val a = cfg("a"); val b = cfg("b"); val h = HubHarness(hubScope(), listOf(a, b)); h.hub.start(); advanceUntilIdle()
        val oldA = h.slot(a.id)!!; val oldB = h.slot(b.id)!!
        val c = cfg("c"); h.tokens.tokens[c.id] = "t"
        h.bookmarks.saveAll(listOf(a.copy(host = "moved.local"), c))
        h.hub.reloadBookmarks(); advanceUntilIdle()
        assertTrue(oldA.tornDown); assertNotSame(oldA, h.slot(a.id)); assertNotNull(h.slot(a.id))
        assertTrue(oldB.tornDown); assertNull(h.slot(b.id))
        assertNotNull(h.slot(c.id))
    }

    @Test fun disablingUnregistersPushBeforeTearingDownAndKeepsTheCachedRows() = runTest {
        val a = cfg("a"); val b = cfg("b"); val h = HubHarness(hubScope(), listOf(a, b)); h.hub.start(); advanceUntilIdle()
        h.hub.syncPushRegistration(PushSettings("t", true, "d", pushEnabled = true, notifyOnFinished = false)); advanceUntilIdle()
        val slotB = h.slot(b.id)!!
        slotB.goLive(listOf(session())); advanceUntilIdle()
        val log = mutableListOf<String>(); slotB.log = { log += it }
        assertTrue(h.hub.setEnabled(b.id, false)); advanceUntilIdle()
        assertNull(h.slot(b.id))
        assertEquals(listOf("push:false", "teardown:b"), log)
        val sec = h.hub.sections.value.first { it.id == b.id }
        assertEquals(ServerSectionStatus.Disabled, sec.status)
        assertEquals(1, sec.sessions.size, "spec §7: the cached list is kept")
    }

    @Test fun slotsBuiltAfterASyncReceiveTheCurrentPushSettings() = runTest {
        val b = cfg("b", enabled = false); val h = HubHarness(hubScope(), listOf(cfg("a"), b)); h.hub.start(); advanceUntilIdle()
        val push = PushSettings("t", true, "d", pushEnabled = true, notifyOnFinished = false)
        h.hub.syncPushRegistration(push)
        h.hub.setEnabled(b.id, true); advanceUntilIdle()
        assertEquals(listOf(push), h.slot(b.id)!!.pushSyncs)
    }

    @Test fun stopDuringStartLeavesNoSlotConnected() = runTest {
        val a = cfg("a"); val h = HubHarness(hubScope(), listOf(a, cfg("b")), hangs = setOf(a.id))
        val starting = launch { h.hub.start() }
        advanceUntilIdle()
        h.hub.stop()
        h.built.first { it.config.name == "a" }.startGate.complete(Unit)
        starting.join(); advanceUntilIdle()
        assertTrue(h.built.all { it.tornDown }, "a coordinator whose handshake ended after stop() is torn down")
        assertTrue(h.hub.sections.value.isNotEmpty())
    }

    @Test fun disableWhileTheBuildIsStillHandshakingTearsItDown() = runTest {
        val a = cfg("a"); val h = HubHarness(hubScope(), listOf(a), hangs = setOf(a.id))
        val starting = launch { h.hub.start() }
        advanceUntilIdle()
        h.hub.setEnabled(a.id, false); advanceUntilIdle()
        h.built.single().startGate.complete(Unit)
        starting.join(); advanceUntilIdle()
        assertTrue(h.built.single().tornDown)
        assertNull(h.slot(a.id))
    }

    @Test fun rebuildSlotReplacesTheCoordinator() = runTest {
        val a = cfg("a"); val h = HubHarness(hubScope(), listOf(a)); h.hub.start(); advanceUntilIdle()
        val old = h.slot(a.id)!!
        h.hub.rebuildSlot(a.id); advanceUntilIdle()
        assertTrue(old.tornDown)
        assertNotSame(old, h.slot(a.id))
        assertEquals(1, h.slot(a.id)!!.startCount)
    }

    @Test fun identityIsLearnedOntoTheBookmarkAndDuplicatesAreFlagged() = runTest {
        val a = cfg("a"); val b = cfg("b"); val h = HubHarness(hubScope(), listOf(a, b)); h.hub.start(); advanceUntilIdle()
        val iid = UUID.randomUUID()
        listOf(a, b).forEach { c ->
            h.slot(c.id)!!.serverIdentity.value = ServerIdentity(iid, "studio")
            h.slot(c.id)!!.goLive(emptyList())
        }
        advanceUntilIdle()
        assertTrue(h.bookmarks.loadAll().all { it.instanceId == iid && it.displayName == "studio" })
        assertTrue(h.hub.sections.value.all { it.isDuplicateInstance })
        assertEquals("studio", h.hub.sections.value[0].title)
    }

    @Test fun foregroundFansOutToEveryEnabledSlotWithAStagger() = runTest {
        val h = HubHarness(hubScope(), listOf(cfg("a"), cfg("b"))); h.hub.start(); advanceUntilIdle()
        h.sleeps.clear()
        h.hub.handleForegroundTransition(); advanceUntilIdle()
        assertTrue(h.built.all { it.foregroundCount == 1 })
        assertEquals(listOf(0L, 150L), h.sleeps)
    }

    @Test fun recoveryTargetsOneServerOrAll() = runTest {
        val a = cfg("a"); val b = cfg("b"); val h = HubHarness(hubScope(), listOf(a, b)); h.hub.start(); advanceUntilIdle()
        h.hub.triggerUserRecovery(a.id)
        assertEquals(listOf(1, 0), h.built.map { it.recoveryCount })
        h.hub.triggerUserRecovery()
        assertEquals(listOf(2, 1), h.built.map { it.recoveryCount })
    }

    @Test fun focusSlotIsTheOnlyEnabledServer() = runTest {
        val a = cfg("a"); val h = HubHarness(hubScope(), listOf(a, cfg("b", enabled = false))); h.hub.start(); advanceUntilIdle()
        assertSame(h.slot(a.id), h.hub.focusSlot.value, "one enabled server drives the single-server surfaces (G8)")
        assertEquals(a.id, h.hub.focusServerId.value)
    }

    @Test fun focusSlotFallsBackToTheFirstLiveServer() = runTest {
        val a = cfg("a"); val b = cfg("b"); val h = HubHarness(hubScope(), listOf(a, b)); h.hub.start(); advanceUntilIdle()
        assertNull(h.hub.focusSlot.value)
        h.slot(b.id)!!.goLive(emptyList()); advanceUntilIdle()
        assertSame(h.slot(b.id), h.hub.focusSlot.value)
    }

    @Test fun collapseIsPersisted() = runTest {
        val a = cfg("a"); val h = HubHarness(hubScope(), listOf(a)); h.hub.start(); advanceUntilIdle()
        h.hub.setCollapsed(a.id, true)
        assertTrue(h.hub.sections.value[0].isCollapsed)
        assertEquals(setOf(a.id), h.state.loadCollapsedServers())
    }

    @Test fun startIsIdempotent() = runTest {
        val h = HubHarness(hubScope(), listOf(cfg("a"))); h.hub.start(); h.hub.start(); advanceUntilIdle()
        assertEquals(1, h.built.size)
    }

    @Test fun hasStartedFlipsOnlyAfterTheFirstStart() = runTest {
        val h = HubHarness(hubScope(), emptyList())
        assertFalse(h.hub.hasStarted.value, "an empty hub before start is 'not loaded', not 'no servers'")
        h.hub.start(); advanceUntilIdle()
        assertTrue(h.hub.hasStarted.value)
    }

    @Test fun shutdownAwaitsEveryTeardown() = runTest {
        val h = HubHarness(hubScope(), listOf(cfg("a"), cfg("b"))); h.hub.start(); advanceUntilIdle()
        h.hub.shutdown()
        assertTrue(h.built.all { it.tornDown }, "torn down before shutdown() returns, not merely launched")
    }

    @Test fun aSlowTokenLoadNeverBuildsTwoSlotsForOneServer() = runTest {
        // Linux reads tokens through secret-tool (seconds on a locked keyring), so
        // the read suspends off the UI thread; a reload during it must not build
        // a second coordinator for the same bookmark.
        val a = cfg("a"); val h = HubHarness(hubScope(), listOf(a))
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        h.tokens.gate = gate
        val starting = launch { h.hub.start() }
        runCurrent()
        h.hub.reloadBookmarks(); runCurrent()
        gate.complete(Unit); starting.join(); advanceUntilIdle()
        assertEquals(1, h.built.size)
    }

    // MARK: - Session-loss notices (session takeover spec §2, §3b, §6)

    private suspend fun kotlinx.coroutines.test.TestScope.liveLossHub(vararg configs: relay.protocol.ConnectionConfig): HubHarness {
        val h = HubHarness(hubScope(), configs.toList(), nowMs = { testScheduler.currentTime })
        h.hub.start(); advanceUntilIdle()
        configs.forEach { h.slot(it.id)!!.goLive(listOf(session())) }
        advanceUntilIdle()
        return h
    }

    private fun lost(name: String, id: UUID = UUID.randomUUID()) = LostSession(id, name)

    @Test fun fanOutWaitsForPassAlreadyInFlight() = runTest { // Review Focus 1
        val a = cfg("a"); val h = liveLossHub(a)
        val slot = h.slot(a.id)!!
        val alerts = mutableListOf<SessionLossAlert>()
        val sub = h.hub.scope.launch { h.hub.takenAlert.collect { it?.let(alerts::add) } }
        // Launch, foreground and network-restored inside ~100 ms: the trigger
        // returns at once because a handshake is already running; its result
        // lands later.
        val pass = kotlinx.coroutines.CompletableDeferred<Unit>()
        slot.passGate = pass
        val finishedBefore = slot.passFinishedCount
        h.hub.handleForegroundTransition()
        val hold = h.hub.lastLossHold!!
        runCurrent()
        assertEquals(1, slot.foregroundCount)
        slot.reportLost(taken = listOf(lost("api")))
        advanceTimeBy(5_000); runCurrent()
        assertTrue(alerts.isEmpty(), "held while the in-flight pass runs")
        slot.reportLost(taken = listOf(lost("web")))
        pass.complete(Unit)
        hold.join(); runCurrent()
        assertEquals(finishedBefore + 1, slot.passFinishedCount, "the hold awaited the pass, not just the trigger")
        assertEquals(1, alerts.size, "one alert for the whole fan-out")
        assertEquals("Sessions Moved", alerts[0].title)
        assertEquals("api and web were attached from another device.", alerts[0].message)
        sub.cancel()
    }

    @Test fun fanOutCapsAt10s() = runTest {
        val dead = cfg("dead"); val ok = cfg("ok"); val h = liveLossHub(dead, ok)
        h.slot(dead.id)!!.passGate = kotlinx.coroutines.CompletableDeferred() // its pass never finishes
        val okSlot = h.slot(ok.id)!!
        okSlot.onForeground = { okSlot.reportLost(taken = listOf(lost("api"))) }
        val t0 = currentTime
        h.hub.handleForegroundTransition()
        advanceTimeBy(9_999); runCurrent()
        assertEquals(1, okSlot.foregroundCount)
        assertNull(h.hub.takenAlert.value, "held: the dead server's pass has not finished")
        advanceTimeBy(2); runCurrent()
        assertEquals(t0 + 10_001, currentTime)
        assertEquals("api was attached from another device.", h.hub.takenAlert.value?.message,
            "the 10 s cap releases the other server's report")
        assertEquals("Session Moved", h.hub.takenAlert.value?.title)
    }

    @Test fun aNeverFinishingPassDelaysNeitherStartNorFanOut() = runTest {
        val a = cfg("a"); val b = cfg("b")
        val h = HubHarness(hubScope(), listOf(a, b), passHangs = setOf(a.id))
        h.hub.start()
        assertEquals(0L, currentTime, "start() returns once every slot is built, not when every pass ends")
        assertTrue(h.hub.hasStarted.value, "deep links waiting on the first start are released")
        h.hub.handleForegroundTransition(); runCurrent()
        assertEquals(0L, currentTime)
        assertTrue(h.built.all { it.foregroundCount == 1 }, "the fan-out's triggers ran without waiting on the pass")
    }

    @Test fun stopDropsAHeldNotice() = runTest {
        val a = cfg("a"); val h = liveLossHub(a)
        val slot = h.slot(a.id)!!
        val pass = kotlinx.coroutines.CompletableDeferred<Unit>()
        slot.passGate = pass
        h.hub.handleForegroundTransition(); runCurrent()
        val hold = h.hub.lastLossHold!!
        slot.reportLost(taken = listOf(lost("api")))
        h.hub.stop()
        pass.complete(Unit)
        hold.join(); advanceUntilIdle()
        assertNull(h.hub.takenAlert.value, "nothing lands behind a closed workspace")
    }

    @Test fun aRetiredSlotsReportIsDropped() = runTest {
        val a = cfg("a"); val h = liveLossHub(a)
        val old = h.slot(a.id)!!
        h.hub.rebuildSlot(a.id); advanceUntilIdle()
        old.reportLost(taken = listOf(lost("api")))
        advanceUntilIdle()
        assertNull(h.hub.takenAlert.value, "a torn-down coordinator speaks for no server")
    }

    @Test fun stealOnNonFocusedServerSurfaces() = runTest { // Review Focus 5
        val one = cfg("one"); val two = cfg("two"); val h = liveLossHub(one, two)
        h.hub.select(relay.protocol.SessionRef(one.id, h.slot(one.id)!!.sessions.value[0].id)); advanceUntilIdle()
        assertEquals(one.id, h.hub.focusServerId.value)
        val stolen = h.slot(two.id)!!.sessions.value[0].id
        h.slot(two.id)!!.reportLost(taken = listOf(lost("build", stolen)))
        advanceUntilIdle()
        assertEquals("Session Moved", h.hub.takenAlert.value?.title)
        assertEquals("build was attached from another device.", h.hub.takenAlert.value?.message)
        h.hub.dismissTakenAlert()
        assertNull(h.hub.takenAlert.value)
    }

    @Test fun endedGoesToNotice() = runTest {
        val a = cfg("a"); val h = liveLossHub(a)
        h.slot(a.id)!!.reportLost(ended = listOf(lost("api")))
        advanceUntilIdle()
        assertEquals("api ended while you were away.", h.hub.notice.value)
        assertNull(h.hub.takenAlert.value)
    }

    @Test fun multiServerBatchUsesDisplayNames() = runTest {
        val a = relay.protocol.ConnectionConfig(name = "a", host = "a.local", displayName = "Studio")
        val b = cfg("b")
        val h = HubHarness(hubScope(), listOf(a, b), nowMs = { testScheduler.currentTime })
        h.hub.start(); advanceUntilIdle()
        val pass = kotlinx.coroutines.CompletableDeferred<Unit>()
        h.slot(b.id)!!.passGate = pass
        h.hub.handleForegroundTransition(); runCurrent()
        val hold = h.hub.lastLossHold!!
        h.slot(a.id)!!.reportLost(taken = listOf(lost("api")))
        h.slot(b.id)!!.reportLost(taken = listOf(lost("web")))
        pass.complete(Unit)
        hold.join(); runCurrent()
        assertEquals("api (on Studio) and web (on b) were attached from another device.", h.hub.takenAlert.value?.message)
    }

    @Test fun enableBuildsWithEnableReason() = runTest {
        val a = cfg("a"); val b = cfg("b", enabled = false)
        val h = HubHarness(hubScope(), listOf(a, b)); h.hub.start(); advanceUntilIdle()
        assertEquals(listOf(relay.session.SessionHandshake.Reason.LAUNCH), h.slot(a.id)!!.startReasons, "launch announces")
        h.hub.setEnabled(b.id, true); advanceUntilIdle()
        assertEquals(listOf(relay.session.SessionHandshake.Reason.ENABLE), h.slot(b.id)!!.startReasons, "enabling a server is silent")
        h.hub.rebuildSlot(a.id); advanceUntilIdle()
        assertEquals(listOf(relay.session.SessionHandshake.Reason.ENABLE), h.slot(a.id)!!.startReasons, "a rebuilt slot is silent too")
        val c = cfg("c"); h.tokens.tokens[c.id] = "t"; h.bookmarks.add(c)
        h.hub.reloadBookmarks(); advanceUntilIdle()
        assertEquals(listOf(relay.session.SessionHandshake.Reason.ENABLE), h.slot(c.id)!!.startReasons, "an added/paired server is silent")
    }
}
