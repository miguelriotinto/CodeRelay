package relay.feature.workspace.hub

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ActivityState
import relay.protocol.ConnectionConfig
import relay.protocol.SessionInfo
import relay.protocol.SessionRef
import relay.protocol.SessionState
import relay.session.hub.HubAggregate
import relay.session.hub.ServerSection
import relay.session.hub.ServerSectionStatus
import java.util.UUID

class HubWorkspaceLogicTest {
    private fun session(id: UUID = UUID.randomUUID()) = SessionInfo(
        id = id, name = null, state = SessionState.ACTIVE_DETACHED, tokenId = "t", createdAt = 0.0,
        cols = 80u, rows = 24u, activity = ActivityState.ACTIVE, agent = null,
    )

    private fun section(
        name: String, status: ServerSectionStatus, enabled: Boolean = true, sessions: Int = 1,
    ) = ServerSection(
        ConnectionConfig(name = name, host = name, enabled = enabled), status,
        (0 until sessions).map { session() }, !status.isLive, emptyList(), 0, false,
    )

    @Test fun noEnabledServerPresentsManagement() { // Review Focus 3
        assertTrue(HubWorkspaceLogic.shouldPresentManagement(HubAggregate()))
        assertTrue(HubWorkspaceLogic.shouldPresentManagement(HubAggregate(totalServers = 2, enabledServers = 0)))
        assertFalse(HubWorkspaceLogic.shouldPresentManagement(HubAggregate(totalServers = 1, enabledServers = 1)))
    }

    @Test fun tabsNumberAcrossServersSkipDisabledAndTitleOnlyWithSeveral() {
        val a = section("a", ServerSectionStatus.Live, sessions = 2)
        val b = section("b", ServerSectionStatus.Live)
        val c = section("c", ServerSectionStatus.Disabled, enabled = false, sessions = 3)
        val tabs = HubWorkspaceLogic.tabs(listOf(a, b, c), SessionRef(b.id, b.sessions[0].id))
        assertEquals(listOf(1, 2, 3), tabs.map { it.number })
        assertEquals(listOf(a.id, a.id, b.id), tabs.map { it.ref.serverId })
        assertEquals(listOf(false, false, true), tabs.map { it.isSelected })
        assertEquals(listOf("a", "a", "b"), tabs.map { it.serverTitle })
        val single = HubWorkspaceLogic.tabs(listOf(a.copy(sessions = a.sessions.take(1)), c), null)
        assertEquals(listOf<String?>(null), single.map { it.serverTitle }, "G8: one server, no prefix")
    }

    @Test fun tabsAreKeyedByRefNotBareUuid() { // Review Focus 4
        val shared = session()
        val a = section("a", ServerSectionStatus.Live).copy(sessions = listOf(shared))
        val b = section("b", ServerSectionStatus.Live).copy(sessions = listOf(shared))
        val tabs = HubWorkspaceLogic.tabs(listOf(a, b), SessionRef(b.id, shared.id))
        assertEquals(2, tabs.map { it.ref }.toSet().size)
        assertEquals(listOf(false, true), tabs.map { it.isSelected }, "the same UUID on two servers is two tabs, one selected")
    }

    @Test fun retryAndConnectingRules() {
        assertEquals(RetryAction.OPEN_MANAGEMENT, HubWorkspaceLogic.retryAction(section("a", ServerSectionStatus.AuthFailed("x"))))
        assertEquals(RetryAction.RECOVER, HubWorkspaceLogic.retryAction(section("a", ServerSectionStatus.Offline)))
        assertFalse(
            HubWorkspaceLogic.isConnecting(
                listOf(section("a", ServerSectionStatus.AuthFailed("x")), section("b", ServerSectionStatus.Offline)),
            ),
        )
        assertTrue(HubWorkspaceLogic.isConnecting(listOf(section("a", ServerSectionStatus.Connecting))))
        assertFalse(HubWorkspaceLogic.isConnecting(listOf(section("a", ServerSectionStatus.Connecting, enabled = false))))
    }

    @Test fun headerModelTable() {
        val offline = ServerSectionHeaderModel.of(section("a", ServerSectionStatus.Offline))
        assertEquals("offline", offline.subtitle); assertEquals(HeaderDot.RED, offline.dot); assertTrue(offline.offersRetry)
        val noToken = ServerSectionHeaderModel.of(section("a", ServerSectionStatus.AuthFailed("No token stored for this server")))
        assertEquals("No token stored for this server", noToken.subtitle); assertTrue(noToken.offersRetry)
        val live = ServerSectionHeaderModel.of(section("a", ServerSectionStatus.Live))
        assertNull(live.subtitle); assertEquals(HeaderDot.GREEN, live.dot); assertFalse(live.offersRetry)
        assertEquals("connecting…", ServerSectionHeaderModel.of(section("a", ServerSectionStatus.Connecting)).subtitle)
        assertEquals("reconnecting…", ServerSectionHeaderModel.of(section("a", ServerSectionStatus.Reconnecting)).subtitle)
        val off = ServerSectionHeaderModel.of(section("a", ServerSectionStatus.Disabled, enabled = false))
        assertEquals("disabled", off.subtitle); assertEquals(HeaderDot.GRAY, off.dot); assertFalse(off.offersRetry)
        assertEquals("a, offline", offline.accessibilityLabel)
    }

    @Test fun badgeCountsOnlyLiveAwaitingSessions() {
        val live = section("a", ServerSectionStatus.Live).copy(awaitingInput = 2)
        assertEquals(2, ServerSectionHeaderModel.of(live).badge)
        assertEquals(0, ServerSectionHeaderModel.of(live.copy(status = ServerSectionStatus.Offline)).badge)
    }
}
