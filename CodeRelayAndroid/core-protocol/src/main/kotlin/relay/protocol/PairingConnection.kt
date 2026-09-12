package relay.protocol

import java.util.UUID

/**
 * The subset of RelayConnection a PairingController needs. Lets tests inject a
 * stub without a live socket. RelayConnection satisfies it as-is.
 *
 * Defined in core-protocol (not core-session or core-net) to break the circular
 * dependency: core-session depends on core-net, so core-net can't depend on
 * core-session. By placing the interface in the shared protocol module, both
 * can implement/use it without a cycle.
 */
interface PairingConnection {
    val generation: Long
    val isConnected: Boolean
    suspend fun connect(config: ConnectionConfig, token: String)
    suspend fun disconnect()
    fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID
    fun removeSubscriber(id: UUID)
    suspend fun send(message: ClientMessage)
}
