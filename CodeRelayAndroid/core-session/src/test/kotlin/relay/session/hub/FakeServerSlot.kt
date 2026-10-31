package relay.session.hub

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import relay.protocol.ConnectionConfig
import relay.protocol.ServerIdentity
import relay.protocol.SessionInfo
import relay.protocol.WorkspaceRollup
import relay.session.SessionHandshake
import java.util.UUID

/** Scripted [ServerSlot] for the hub tests (port of the Swift `FakeServerSlot`). */
class FakeServerSlot(override val config: ConnectionConfig) : ServerSlot {
    override val sessions = MutableStateFlow<List<SessionInfo>>(emptyList())
    override val activeSessionId = MutableStateFlow<UUID?>(null)
    override val isRecovering = MutableStateFlow(false)
    override val recoveryFailed = MutableStateFlow(false)
    override val isAuthRejected = MutableStateFlow(false)
    override val isPerformingHandshake = MutableStateFlow(false)
    override val connected = MutableStateFlow(false)
    override val serverIdentity = MutableStateFlow<ServerIdentity?>(null)
    override val sessionsAwaitingInput = MutableStateFlow<Set<UUID>>(emptySet())
    private val _changes = MutableSharedFlow<Unit>(extraBufferCapacity = 64)
    override val changes: Flow<Unit> = _changes
    fun changed() { _changes.tryEmit(Unit) }

    var log: ((String) -> Unit)? = null
    var startCount = 0
    val startReasons = mutableListOf<SessionHandshake.Reason>()
    override var onSessionsLost: ((SessionLossReport) -> Unit)? = null
    var passFinishedCount = 0
    /** When set, [awaitPassFinished] parks on it (a pass still in flight). */
    var passGate: CompletableDeferred<Unit>? = null
    var foregroundCount = 0
    var recoveryCount = 0
    var detachCount = 0
    var createCount = 0
    val switchedTo = mutableListOf<UUID>()
    val remoteAttaches = mutableListOf<UUID>()
    val pushSyncs = mutableListOf<PushSettings>()
    var tornDown = false
    var startHangs = false
    val startGate = CompletableDeferred<Unit>()
    var detachHangs = false
    val detachGate = CompletableDeferred<Unit>()
    var switchFails = false

    override fun rollups(sessions: List<SessionInfo>): List<WorkspaceRollup> = emptyList()
    override suspend fun start(reason: SessionHandshake.Reason) {
        startCount += 1; startReasons += reason; log?.invoke("start:${config.name}")
        if (startHangs) startGate.await()
    }
    override suspend fun switchToSession(id: UUID) {
        switchedTo += id; log?.invoke("switch:${config.name}")
        if (!switchFails) activeSessionId.value = id
        changed()
    }
    override suspend fun createNewSession() {
        createCount += 1; activeSessionId.value = UUID.randomUUID(); log?.invoke("create:${config.name}"); changed()
    }
    override suspend fun detachForHub(budgetMs: Long) {
        detachCount += 1; log?.invoke("detach:${config.name}")
        activeSessionId.value = null
        if (detachHangs) detachGate.await()
        changed()
    }
    override suspend fun attachRemoteSession(id: UUID, serverName: String?) {
        remoteAttaches += id; activeSessionId.value = id; changed()
    }
    override fun handleForegroundTransition() { foregroundCount += 1; log?.invoke("fg:${config.name}") }
    override fun triggerUserRecovery() { recoveryCount += 1; log?.invoke("recover:${config.name}") }
    override suspend fun syncPush(settings: PushSettings) { pushSyncs += settings; log?.invoke("push:${settings.pushEnabled}") }
    override suspend fun awaitPassFinished() {
        passGate?.await()
        passFinishedCount += 1
    }
    override suspend fun tearDown() { tornDown = true; log?.invoke("teardown:${config.name}") }

    fun goLive(list: List<SessionInfo>) {
        connected.value = true; isPerformingHandshake.value = false; sessions.value = list; changed()
    }
    fun goOffline() { connected.value = false; changed() }
}

class InMemoryBookmarks(initial: List<ConnectionConfig> = emptyList()) : BookmarkStore {
    private var list = initial
    override suspend fun loadAll() = list
    override suspend fun saveAll(list: List<ConnectionConfig>) { this.list = list }
    override suspend fun add(c: ConnectionConfig) {
        list = if (list.any { it.id == c.id }) list.map { if (it.id == c.id) c else it } else list + c
    }
    override suspend fun delete(id: UUID) { list = list.filterNot { it.id == id } }
}

class FakeTokens(
    val tokens: MutableMap<UUID, String> = mutableMapOf(),
    var throwsFor: Set<UUID> = emptySet(),
) : TokenSource {
    /** When set, every load parks on it first (a slow keyring). */
    var gate: CompletableDeferred<Unit>? = null
    override suspend fun loadToken(id: UUID): String? {
        gate?.await()
        if (id in throwsFor) error("keyring locked")
        return tokens[id]
    }
    override fun deleteToken(id: UUID) { tokens.remove(id) }
}
