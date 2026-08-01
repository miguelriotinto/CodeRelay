package relay.session

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import relay.protocol.ClientMessage
import relay.protocol.ConnectionConfig
import relay.protocol.PairingConnection
import relay.protocol.PairingURL
import relay.protocol.ServerMessage
import java.util.UUID

sealed class PairingError : Exception() {
    object InvalidCode : PairingError()
    object RateLimited : PairingError()
    object TlsRequired : PairingError()
    object Unreachable : PairingError()
    object TimedOut : PairingError()
    data class Server(val code: Int, val text: String) : PairingError()
}

/**
 * Minimal storage seams for injection testing. PairingController uses these
 * interfaces; production passes real stores, tests pass fakes.
 */
interface ConnectionStoreAdapter {
    suspend fun add(connection: ConnectionConfig): List<ConnectionConfig>
}

interface TokenStoreAdapter {
    fun saveToken(token: String, connectionId: UUID)
}

/**
 * Redeems a pairing code over a fresh, pre-auth WebSocket connection and
 * persists the minted token the same way ServersViewModel.addOrUpdate does.
 *
 * Ports the Swift PairingController (Sources/ClaudeRelayClient/PairingController.swift).
 * One home for the redeem sequence so iOS, macOS, and Android share it. It
 * deliberately does NOT authenticate — after pair() returns, the caller connects
 * through the normal path with the persisted token, keeping one authenticated path.
 */
class PairingController(
    private val store: ConnectionStoreAdapter,
    private val tokenStore: TokenStoreAdapter,
    private val deviceName: String,
    private val platform: String,
    private val connectionFactory: () -> PairingConnection,
    private val timeoutMs: Long = 10_000L,
) {
    /**
     * Dials the host in [url], redeems [url.code], persists a ConnectionConfig
     * plus the minted token, and returns the config. Throws [PairingError] on any
     * failure. Never leaves a dangling socket.
     */
    suspend fun pair(url: PairingURL): ConnectionConfig {
        val connection = connectionFactory()

        // Pre-auth dial: connect() with an empty token (we redeem first)
        val dialConfig = ConnectionConfig(
            name = url.host,
            host = url.host,
            port = url.port.toUShort(),
            useTLS = url.useTLS
        )
        try {
            connection.connect(dialConfig, token = "")
        } catch (e: Exception) {
            throw PairingError.Unreachable
        }

        try {
            val reply = redeem(url.code, connection)
            val success = reply as? ServerMessage.PairSuccess ?: throw mapError(reply)
            val config = ConnectionConfig(
                name = success.label.ifEmpty { url.host },
                host = url.host,
                port = url.port.toUShort(),
                useTLS = url.useTLS
            )
            store.add(config)
            tokenStore.saveToken(success.token, config.id)
            return config
        } finally {
            withContext(NonCancellable) {
                connection.disconnect()
            }
        }
    }

    /**
     * Installs the response subscriber BEFORE sending (mirrors
     * SessionController.awaitResponse), matches pair_success or error, and
     * resolves within the deadline. Only one RPC is ever in flight here.
     */
    private suspend fun redeem(code: String, connection: PairingConnection): ServerMessage {
        val deferred = CompletableDeferred<ServerMessage>()
        val matchTypes = setOf("pair_success", "error")

        val subId = connection.addServerMessageSubscriber { msg ->
            if (msg.typeString in matchTypes) {
                deferred.complete(msg)
            }
        }

        try {
            connection.send(ClientMessage.PairRequest(code, deviceName, platform))
            return withTimeoutOrNull(timeoutMs) { deferred.await() } ?: throw PairingError.TimedOut
        } catch (e: CancellationException) {
            throw e
        } catch (e: PairingError) {
            throw e
        } catch (e: Exception) {
            throw PairingError.Unreachable
        } finally {
            connection.removeSubscriber(subId)
        }
    }

    private fun mapError(message: ServerMessage): PairingError {
        val err = message as? ServerMessage.Error
            ?: return PairingError.Server(-1, "Unexpected reply")
        return when (err.code) {
            401 -> PairingError.InvalidCode
            429 -> PairingError.RateLimited
            else -> PairingError.Server(err.code, err.message)
        }
    }
}
