package relay.protocol

import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * Configuration for connecting to a ClaudeRelay server.
 *
 * Ports `ConnectionConfig.swift` (which lives in ClaudeRelayClient, not Kit).
 * [wsUrl] builds the WebSocket URL, choosing `wss` when [useTLS] is set.
 */
@Serializable
data class ConnectionConfig(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val name: String,
    val host: String,
    val port: UShort = 9200u,
    val useTLS: Boolean = false,
) {
    val wsUrl: String
        get() = "${if (useTLS) "wss" else "ws"}://$host:$port"
}
