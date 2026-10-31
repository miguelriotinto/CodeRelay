package relay.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionConfig
import relay.protocol.ServerIdentity
import relay.protocol.SessionDeepLink
import relay.protocol.SessionInfo
import relay.protocol.WorkspaceRollup
import relay.session.hub.BookmarkStore
import relay.session.hub.HubPreferences
import relay.session.hub.PushSettings
import relay.session.hub.ServerSlot
import relay.session.hub.TokenSource
import java.util.UUID

@OptIn(ExperimentalCoroutinesApi::class)
class HubViewModelTest {

    private class Slot(override val config: ConnectionConfig) : ServerSlot {
        override val sessions = MutableStateFlow<List<SessionInfo>>(emptyList())
        override val activeSessionId = MutableStateFlow<UUID?>(null)
        override val isRecovering = MutableStateFlow(false)
        override val recoveryFailed = MutableStateFlow(false)
        override val isAuthRejected = MutableStateFlow(false)
        override val isPerformingHandshake = MutableStateFlow(false)
        override val connected = MutableStateFlow(true)
        override val serverIdentity = MutableStateFlow<ServerIdentity?>(null)
        override val sessionsAwaitingInput = MutableStateFlow<Set<UUID>>(emptySet())
        override val changes: Flow<Unit> = MutableSharedFlow()
        var tornDown = false
        val remote = mutableListOf<UUID>()
        override fun rollups(sessions: List<SessionInfo>): List<WorkspaceRollup> = emptyList()
        override var onSessionsLost: ((relay.session.hub.SessionLossReport) -> Unit)? = null
        override suspend fun start(reason: relay.session.SessionHandshake.Reason) {}
        override suspend fun awaitPassFinished() {}
        override suspend fun switchToSession(id: UUID) { activeSessionId.value = id }
        override suspend fun createNewSession() {}
        override suspend fun detachForHub(budgetMs: Long) { activeSessionId.value = null }
        override suspend fun attachRemoteSession(id: UUID, serverName: String?) { remote += id; activeSessionId.value = id }
        override fun handleForegroundTransition() {}
        override fun triggerUserRecovery() {}
        override suspend fun syncPush(settings: PushSettings) {}
        override suspend fun tearDown() { tornDown = true }
    }

    private class Bookmarks(var list: List<ConnectionConfig>) : BookmarkStore {
        override suspend fun loadAll() = list
        override suspend fun saveAll(list: List<ConnectionConfig>) { this.list = list }
        override suspend fun add(c: ConnectionConfig) { list = list.filterNot { it.id == c.id } + c }
        override suspend fun delete(id: UUID) { list = list.filterNot { it.id == id } }
    }

    private class Tokens : TokenSource {
        override suspend fun loadToken(id: UUID) = "tok"
        override fun deleteToken(id: UUID) {}
    }

    private class Prefs : HubPreferences {
        val map = mutableMapOf<String, String>()
        override fun get(key: String) = map[key]
        override fun put(key: String, value: String?) { if (value == null) map.remove(key) else map[key] = value }
    }

    private fun kotlinx.coroutines.test.TestScope.vm(configs: List<ConnectionConfig>, built: MutableList<Slot>) =
        HubViewModel(
            HubDeps(
                scope = CoroutineScope(coroutineContext + Job()),
                bookmarks = Bookmarks(configs),
                tokens = Tokens(),
                prefs = Prefs(),
                slotFactory = { c, _ -> Slot(c).also { built += it } },
                migration = null,
                pushSettings = { null },
            ),
        )

    @Test fun hubViewModelStartsTheHubOnce() = runTest { // Review Focus 2
        val built = mutableListOf<Slot>()
        val vm = vm(listOf(ConnectionConfig(name = "a", host = "a")), built)
        vm.start(); vm.start(); advanceUntilIdle()
        assertEquals(1, built.size, "activity recreation calls start() again; the retained hub must not start twice")
    }

    @Test fun aColdStartSessionLinkIsRoutedAfterTheHubStarts() = runTest { // Review Focus 1
        val built = mutableListOf<Slot>()
        val vm = vm(listOf(ConnectionConfig(name = "a", host = "a")), built)
        val target = UUID.randomUUID()
        vm.open(SessionDeepLink(target))       // MainActivity.onCreate hands the link over before start()
        vm.start(); advanceUntilIdle()
        assertEquals(listOf(target), built.single().remote, "one server: the pre-hub cross-device attach")
    }

    @Test fun shutdownTearsEverySlotDown() = runTest {
        val built = mutableListOf<Slot>()
        val vm = vm(listOf(ConnectionConfig(name = "a", host = "a"), ConnectionConfig(name = "b", host = "b")), built)
        vm.start(); advanceUntilIdle()
        vm.shutdown(); advanceUntilIdle()
        assertTrue(built.all { it.tornDown })
    }
}
