package relay.net

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import relay.protocol.ClientMessage
import relay.protocol.ConnectionConfig
import relay.protocol.ConnectionQuality
import relay.protocol.MessageEnvelope
import relay.protocol.ServerMessage
import java.util.UUID

/**
 * Minimal surface a [SessionController] needs from a connection. Defining it as
 * an interface lets tests substitute a fake without an OkHttp socket.
 */
interface ConnectionSurface {
    val generation: Long
    fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID
    fun removeSubscriber(id: UUID)
    suspend fun send(message: ClientMessage)
}

/**
 * Manages a WebSocket connection to a ClaudeRelay server with connection-quality
 * monitoring.
 *
 * Ports `RelayConnection.swift`. Uses OkHttp's [WebSocket] for transport and
 * monitors health via application-level ping/pong on a 10-second interval.
 * Recovery is owned exclusively by the coordinator — this class never
 * auto-reconnects on its own. When the socket dies it fires [onSendFailed] and
 * lets the coordinator drive recovery.
 *
 * All mutable state is confined to [NetworkConfinement.dispatcher] (the Kotlin
 * analogue of Swift's `@MainActor`), so the receive loop, ping bookkeeping, and
 * subscriber map need no additional locking. Every OkHttp listener callback is
 * marshalled onto that dispatcher and dropped if its captured [generation] no
 * longer matches the live one — the "stale-callback bail" from the Swift
 * receive loop.
 */
class RelayConnection(
    private val scope: CoroutineScope = CoroutineScope(NetworkConfinement.dispatcher),
    private val client: OkHttpClient = defaultClient,
) : ConnectionSurface {

    enum class ConnectionState { DISCONNECTED, CONNECTING, CONNECTED }

    // MARK: - State (confined to NetworkConfinement.dispatcher)

    @Volatile
    var state: ConnectionState = ConnectionState.DISCONNECTED
        private set

    @Volatile
    var connectionQuality: ConnectionQuality = ConnectionQuality.DISCONNECTED
        private set

    /**
     * Monotonically increasing counter bumped each time a connection is
     * established AND each time it is torn down. Stale receive-loop / keepalive
     * callbacks compare against this and become no-ops once superseded.
     */
    @Volatile
    override var generation: Long = 0L
        private set

    // MARK: - Callbacks

    /** Called when terminal output (binary) data is received from the server. */
    var onTerminalOutput: ((ByteArray) -> Unit)? = null

    /**
     * Called when a user-visible send fails or the receive loop ends, signalling
     * the connection is likely dead. The coordinator drives recovery. Internal
     * pings do NOT trigger this — only user commands and the death detector.
     */
    var onSendFailed: (() -> Unit)? = null

    /** Fires each time the keepalive loop records a healthy ping RTT. */
    var onHealthyPing: (() -> Unit)? = null

    // MARK: - Subscribers

    private val subscribers = LinkedHashMap<UUID, (ServerMessage) -> Unit>()

    override fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID {
        val id = UUID.randomUUID()
        subscribers[id] = handler
        return id
    }

    override fun removeSubscriber(id: UUID) {
        subscribers.remove(id)
    }

    // MARK: - Private transport state

    private var webSocket: WebSocket? = null
    private var config: ConnectionConfig? = null
    private var token: String? = null

    /** Single pong slot. Completed with the result of the in-flight ping. */
    private var pendingPong: CompletableDeferred<Boolean>? = null
    private var keepaliveJob: Job? = null

    // MARK: - Public API

    /**
     * Connects to the server described by [config], storing [token] for later
     * [forceReconnect]. Does NOT enable any auto-reconnect — the coordinator owns
     * recovery.
     */
    suspend fun connect(config: ConnectionConfig, token: String) {
        this.config = config
        this.token = token
        connectRaw(config.wsUrl)
    }

    /**
     * Test seam / transport core: opens a socket to the given `ws://`/`wss://`
     * URL, bumps the generation, installs the listener, and starts the quality
     * monitor. [connect] wraps this with config/token storage.
     */
    suspend fun connectRaw(wsUrl: String) = withContext(scope.coroutineContext) {
        // Resolve any stale pong from a previous connection before we tear down.
        resolvePendingPong(false)

        webSocket?.cancel()
        webSocket = null
        cancelKeepalive()

        // Bump generation so stale callbacks from the old socket become no-ops.
        generation += 1
        val gen = generation

        state = ConnectionState.CONNECTING

        val request = Request.Builder().url(wsUrl).build()
        val socket = client.newWebSocket(request, Listener(gen))
        webSocket = socket

        state = ConnectionState.CONNECTED
        startQualityMonitor(gen)
    }

    /** Disconnects from the server. Does not attempt reconnection. */
    fun disconnect() {
        scope.launch {
            cancelKeepalive()
            resolvePendingPong(false)
            generation += 1
            webSocket?.cancel()
            webSocket = null
            state = ConnectionState.DISCONNECTED
            connectionQuality = ConnectionQuality.DISCONNECTED
        }
    }

    /**
     * Tears down the current connection and establishes a fresh one immediately,
     * reusing the stored config/token. Does NOT enable any auto-reconnect loop.
     */
    suspend fun forceReconnect() {
        val cfg = config ?: throw IllegalStateException("Not connected")
        val tok = token ?: throw IllegalStateException("Not connected")
        connect(cfg, tok)
    }

    /**
     * Sends a user-initiated control message (JSON text frame). Fires
     * [onSendFailed] and throws on transport failure so the coordinator can start
     * recovery.
     */
    override suspend fun send(message: ClientMessage) = sendClientMessage(message, notifyOnFailure = true)

    private suspend fun sendInternal(message: ClientMessage) = sendClientMessage(message, notifyOnFailure = false)

    private suspend fun sendClientMessage(message: ClientMessage, notifyOnFailure: Boolean): Unit =
        withContext(scope.coroutineContext) {
            val socket = webSocket ?: run {
                if (notifyOnFailure) onSendFailed?.invoke()
                throw IllegalStateException("Not connected")
            }
            val json = MessageEnvelope.encodeClient(message)
            if (!socket.send(json)) {
                if (notifyOnFailure) onSendFailed?.invoke()
                throw IllegalStateException("WebSocket send failed (queue full or closing)")
            }
        }

    /** Sends raw terminal input as a binary WebSocket frame. */
    suspend fun sendBinary(data: ByteArray): Unit = withContext(scope.coroutineContext) {
        val socket = webSocket ?: run {
            onSendFailed?.invoke()
            throw IllegalStateException("Not connected")
        }
        if (!socket.send(data.toByteString())) {
            onSendFailed?.invoke()
            throw IllegalStateException("WebSocket send failed (queue full or closing)")
        }
    }

    /** Sends a terminal resize command to the server. */
    suspend fun sendResize(cols: UShort, rows: UShort) = send(ClientMessage.Resize(cols, rows))

    /** Sends base64-encoded image data to be pasted on the server's clipboard. */
    suspend fun sendPasteImage(base64Data: String) = send(ClientMessage.PasteImage(base64Data))

    // MARK: - Pong routing

    /** Resolves the pending pong, if any, with [gotPong]. Idempotent. */
    private fun resolvePendingPong(gotPong: Boolean) {
        val deferred = pendingPong ?: return
        pendingPong = null
        deferred.complete(gotPong)
    }

    private fun cancelKeepalive() {
        keepaliveJob?.cancel()
        keepaliveJob = null
    }

    /**
     * Placeholder until the ping/pong health task wires up the keepalive loop.
     * [connectRaw] always calls it so the call site is stable.
     */
    private fun startQualityMonitor(gen: Long) {
        // Filled in by the ping/pong health monitor task.
    }

    // MARK: - OkHttp listener

    /**
     * Captures [gen] at listener-creation time; every callback re-enters the
     * confinement dispatcher and bails if the generation has moved on.
     */
    private inner class Listener(private val gen: Long) : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            scope.launch {
                if (gen != generation) return@launch
                val message = runCatching { MessageEnvelope.decodeServer(text) }.getOrNull() ?: return@launch
                if (message is ServerMessage.Pong) {
                    resolvePendingPong(true)
                    return@launch
                }
                // Snapshot so a handler that removes itself mid-dispatch doesn't
                // mutate the collection we're iterating.
                for (handler in subscribers.values.toList()) {
                    handler(message)
                }
            }
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            val copy = bytes.toByteArray()
            scope.launch {
                if (gen != generation) return@launch
                onTerminalOutput?.invoke(copy)
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            scope.launch {
                if (gen != generation) return@launch
                handleReceiveFailure()
            }
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            scope.launch {
                if (gen != generation) return@launch
                handleReceiveFailure()
            }
        }
    }

    /**
     * Called when the receive loop fails or the socket closes — connection is
     * dead at the transport layer. Notifies the coordinator; no self-reconnect.
     */
    private fun handleReceiveFailure() {
        cancelKeepalive()
        resolvePendingPong(false)
        webSocket = null
        state = ConnectionState.DISCONNECTED
        connectionQuality = ConnectionQuality.DISCONNECTED
        onSendFailed?.invoke()
    }

    companion object {
        private val defaultClient: OkHttpClient by lazy { OkHttpClient() }
    }
}
