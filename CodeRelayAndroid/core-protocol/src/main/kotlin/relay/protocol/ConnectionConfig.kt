package relay.protocol

import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * Configuration for connecting to a CodeRelay server.
 *
 * Ports `ConnectionConfig.swift` (which lives in CodeRelayClient, not Kit).
 * [wsUrl] builds the WebSocket URL, choosing `wss` when [useTLS] is set.
 */
@Serializable
data class ConnectionConfig(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val name: String,
    val host: String,
    val port: UShort = 9200u,
    val useTLS: Boolean = false,
    /** Live in the workspace (multi-server spec §9). Pre-feature bookmarks decode as enabled; the hub's one-time migration then disables all but the last-used one. */
    val enabled: Boolean = true,
    /** The relay's instance id, learned from `auth_success` (spec §5.2). */
    @Serializable(with = UuidSerializer::class) val instanceId: UUID? = null,
    /** The relay's own display name, learned from `auth_success`. */
    val displayName: String? = null,
) {
    val wsUrl: String
        get() = "${if (useTLS) "wss" else "ws"}://$host:$port"

    /** Section / row title: the relay's own name when learned, else the bookmark name. */
    val title: String get() = displayName ?: name
}
