package relay.session.hub

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import relay.protocol.ConnectionConfig
import relay.protocol.ServerIdentity
import relay.protocol.SessionInfo
import relay.protocol.WorkspaceRollup
import relay.session.SessionHandshake
import java.util.UUID

/**
 * What the hub needs from one server's coordinator (multi-server spec §7.1).
 * [CoordinatorServerSlot] adapts the real `SessionCoordinator`; the hub tests
 * drive a scripted fake. Mirrors Swift `ServerSlotCoordinating`.
 */
interface ServerSlot {
    val config: ConnectionConfig
    /** The coordinator's pane list (token-scoped, terminal sessions dropped). */
    val sessions: StateFlow<List<SessionInfo>>
    val activeSessionId: StateFlow<UUID?>
    val isRecovering: StateFlow<Boolean>
    val recoveryFailed: StateFlow<Boolean>
    val isAuthRejected: StateFlow<Boolean>
    val isPerformingHandshake: StateFlow<Boolean>
    val connected: StateFlow<Boolean>
    val serverIdentity: StateFlow<ServerIdentity?>
    val sessionsAwaitingInput: StateFlow<Set<UUID>>
    /** Fires after any of the above changed; the hub republishes on it. */
    val changes: Flow<Unit>
    /** Sessions this server lost while away (or live, for a steal), classified. */
    var onSessionsLost: ((SessionLossReport) -> Unit)?

    fun rollups(sessions: List<SessionInfo>): List<WorkspaceRollup>
    /**
     * Connects and runs the first handshake with [reason]: LAUNCH at app start
     * (reports losses since the persisted baseline), ENABLE for a just-enabled or
     * rebuilt server (silent). May throw for a rejected token; the hub catches it.
     */
    suspend fun start(reason: SessionHandshake.Reason = SessionHandshake.Reason.LAUNCH)
    suspend fun switchToSession(id: UUID)
    suspend fun createNewSession()
    /** Bounded detach that clears the selection first (D9). */
    suspend fun detachForHub(budgetMs: Long)
    suspend fun attachRemoteSession(id: UUID, serverName: String?)
    fun handleForegroundTransition()
    fun triggerUserRecovery()
    suspend fun syncPush(settings: PushSettings)
    /** Returns once no handshake, recovery or session fetch is in flight —
     *  including one already running when called; immediately when idle. */
    suspend fun awaitPassFinished()
    suspend fun tearDown()
}

/** The push inputs the hub fans out to every slot, and remembers for slots built later (spec §10). */
data class PushSettings(
    val deviceToken: String?,
    val permissionGranted: Boolean,
    val deviceId: String,
    val pushEnabled: Boolean,
    val notifyOnFinished: Boolean,
)

/** The bookmark list, through whichever store a platform keeps it in (spec §9). */
interface BookmarkStore {
    suspend fun loadAll(): List<ConnectionConfig>
    suspend fun saveAll(list: List<ConnectionConfig>)
    /** Inserts, or replaces the bookmark with the same id. */
    suspend fun add(c: ConnectionConfig)
    suspend fun delete(id: UUID)
}

/** Per-bookmark relay tokens. [loadToken] may throw (a locked keyring); the hub treats that as "no token". */
interface TokenSource {
    suspend fun loadToken(id: UUID): String?
    fun deleteToken(id: UUID)
}
