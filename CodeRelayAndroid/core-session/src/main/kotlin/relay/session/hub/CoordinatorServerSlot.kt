package relay.session.hub

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import relay.protocol.ConnectionConfig
import relay.protocol.ServerIdentity
import relay.protocol.SessionInfo
import relay.protocol.WorkspaceRollup
import relay.session.SessionCoordinator
import java.util.UUID

/**
 * Adapts one unchanged [SessionCoordinator] to [ServerSlot]. `open` so each app
 * can carry its own per-server objects (the `WorkspaceViewModel` the shared
 * screen hosts) on a subclass.
 */
open class CoordinatorServerSlot(
    final override val config: ConnectionConfig,
    val coordinator: SessionCoordinator,
) : ServerSlot {
    override val sessions: StateFlow<List<SessionInfo>> get() = coordinator.activeSessions
    override val activeSessionId: StateFlow<UUID?> get() = coordinator.activeSessionId
    override val isRecovering: StateFlow<Boolean> get() = coordinator.isRecovering
    override val recoveryFailed: StateFlow<Boolean> get() = coordinator.recoveryFailed
    override val isAuthRejected: StateFlow<Boolean> get() = coordinator.isAuthRejected
    override val isPerformingHandshake: StateFlow<Boolean> get() = coordinator.isPerformingHandshake
    override val connected: StateFlow<Boolean> get() = coordinator.connected
    override val serverIdentity: StateFlow<ServerIdentity?> get() = coordinator.serverIdentity
    override val sessionsAwaitingInput: StateFlow<Set<UUID>> get() = coordinator.sessionsAwaitingInput

    override val changes: Flow<Unit> = merge(
        coordinator.activeSessions.drop(1).map { },
        coordinator.activeSessionId.drop(1).map { },
        coordinator.isRecovering.drop(1).map { },
        coordinator.recoveryFailed.drop(1).map { },
        coordinator.isAuthRejected.drop(1).map { },
        coordinator.isPerformingHandshake.drop(1).map { },
        coordinator.connected.drop(1).map { },
        coordinator.serverIdentity.drop(1).map { },
        coordinator.sessionsAwaitingInput.drop(1).map { },
        coordinator.agentStates.drop(1).map { },
    )

    override fun rollups(sessions: List<SessionInfo>): List<WorkspaceRollup> =
        coordinator.activityCoordinator.rollups(sessions)
    override suspend fun start() = coordinator.connect()
    override suspend fun switchToSession(id: UUID) = coordinator.switchToSession(id)
    override suspend fun createNewSession() = coordinator.createNewSession()
    override suspend fun detachForHub(budgetMs: Long) = coordinator.detachForHub(budgetMs)
    override suspend fun attachRemoteSession(id: UUID, serverName: String?) =
        coordinator.attachRemoteSession(id, serverName)
    override fun handleForegroundTransition() = coordinator.handleForegroundTransition()
    override fun triggerUserRecovery() = coordinator.triggerUserRecovery()
    override suspend fun syncPush(settings: PushSettings) = coordinator.syncPushRegistration(
        deviceToken = settings.deviceToken,
        permissionGranted = settings.permissionGranted,
        deviceId = settings.deviceId,
        pushEnabled = settings.pushEnabled,
        notifyOnFinished = settings.notifyOnFinished,
    )
    override suspend fun tearDown() = coordinator.tearDown()
}
