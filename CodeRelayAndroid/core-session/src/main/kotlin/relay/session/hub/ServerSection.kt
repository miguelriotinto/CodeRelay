package relay.session.hub

import relay.protocol.ConnectionConfig
import relay.protocol.SessionInfo
import relay.protocol.WorkspaceRollup
import java.util.UUID

/** Where one server stands, for its section header (multi-server spec §7.2, §8.1). */
sealed interface ServerSectionStatus {
    data object Connecting : ServerSectionStatus
    data object Live : ServerSectionStatus
    data object Reconnecting : ServerSectionStatus
    data object Offline : ServerSectionStatus
    data class AuthFailed(val message: String) : ServerSectionStatus
    data object Disabled : ServerSectionStatus

    val isLive: Boolean get() = this == Live

    companion object {
        /**
         * Order matters: disabled beats everything, a rejected token beats
         * recovery, recovery beats the raw socket, and a handshake in flight is
         * "connecting" whether or not the socket is already up.
         */
        fun derive(
            enabled: Boolean,
            connected: Boolean,
            isRecovering: Boolean,
            isPerformingHandshake: Boolean,
            authRejected: Boolean,
        ): ServerSectionStatus = when {
            !enabled -> Disabled
            authRejected -> AuthFailed("Token rejected by the relay")
            isRecovering -> Reconnecting
            isPerformingHandshake -> Connecting
            connected -> Live
            else -> Offline
        }
    }
}

/** One server's slice of the sidebar. */
data class ServerSection(
    val config: ConnectionConfig,
    val status: ServerSectionStatus,
    /** The live list while live; the last live list otherwise (D4). */
    val sessions: List<SessionInfo>,
    val isCached: Boolean,
    val rollups: List<WorkspaceRollup>,
    val awaitingInput: Int,
    val isCollapsed: Boolean,
    /** Another bookmark learned the same instance id (spec §10, §12). */
    val isDuplicateInstance: Boolean = false,
) {
    val id: UUID get() = config.id
    val title: String get() = config.title
}

/** Cross-server counts (spec §7.6). Cached sections contribute nothing. */
data class HubAggregate(
    val liveServers: Int = 0,
    val totalServers: Int = 0,
    val enabledServers: Int = 0,
    val sessionsAwaitingInput: Int = 0,
)
