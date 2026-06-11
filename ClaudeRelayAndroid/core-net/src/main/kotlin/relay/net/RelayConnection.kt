package relay.net

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
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
import java.util.concurrent.ConcurrentHashMap

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
 * All mutable state except the subscriber map is confined to
 * [NetworkConfinement.dispatcher] (the Kotlin analogue of Swift's `@MainActor`),
 * so the receive loop and ping bookkeeping need no additional locking. The
 * subscriber map is a [ConcurrentHashMap] because [SessionController]
 * adds/removes subscribers from the caller's thread (off the confinement
 * dispatcher) while the receive loop iterates it on the dispatcher — a genuine
 * cross-thread access that the dispatcher alone cannot serialize. Every OkHttp
 * listener callback is marshalled onto the dispatcher and dropped if its captured
 * [generation] no longer matches the live one — the "stale-callback bail" from
 * the Swift receive loop.
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

    /**
     * Server-message fan-out targets. A [ConcurrentHashMap] — not a plain map —
     * because [SessionController.sendAndWaitForResponse] adds/removes subscribers
     * on the *caller's* thread (off [NetworkConfinement.dispatcher]) while the
     * receive loop iterates this map on the dispatcher. Fan-out order is not
     * load-bearing (each subscriber self-filters by response type), so CHM's
     * lock-free, weakly-consistent iteration is exactly what we want, and
     * add/remove stay non-suspend for future push-callback adders.
     */
    private val subscribers = ConcurrentHashMap<UUID, (ServerMessage) -> Unit>()

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

    /** Sliding window of recent ping RTTs (seconds); null entries are failures. */
    private val rttWindow = ArrayDeque<Double?>()
    private var consecutiveFailures = 0

    /**
     * Dedups concurrent [measurePingRtt] callers onto a single in-flight ping,
     * so overlapping pings don't stomp the single [pendingPong] slot.
     */
    private var activePing: Deferred<Double?>? = null

    // MARK: - Public API

    /**
     * Connects to the server described by [config], storing [token] for later
     * [forceReconnect]. Does NOT enable any auto-reconnect — the coordinator owns
     * recovery.
     *
     * **Cleartext gate (unbypassable).** Before opening the socket this enforces
     * [CleartextPolicy.requireAllowed]: a plaintext `ws://` connection to a
     * non-private host throws [CleartextPolicyException]. Because *every* connect
     * path — manual tap, auto-connect, deep-link attach, and the status probe —
     * funnels through here, the gate cannot be skipped. This is the Android analog
     * of iOS enforcing `NSAllowsLocalNetworking` at the platform layer; Android's
     * `network_security_config` cannot express RFC1918 CIDR ranges, so this code
     * gate is the authoritative enforcer. The check runs first so a rejected
     * config never mutates [config]/[token] or touches the socket.
     */
    suspend fun connect(config: ConnectionConfig, token: String) {
        CleartextPolicy.requireAllowed(config)
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
        activePing?.cancel()
        activePing = null

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

    /**
     * Disconnects from the server. Does not attempt reconnection. A `suspend fun`
     * wrapped in `withContext(scope.coroutineContext)` — symmetric with [connectRaw]
     * — so the teardown completes before the call returns and a caller that
     * immediately reconnects observes a fully torn-down state (no `scope.launch`
     * fire-and-forget interleaving with the next [connect]).
     */
    suspend fun disconnect(): Unit = withContext(scope.coroutineContext) {
        cancelKeepalive()
        resolvePendingPong(false)
        activePing?.cancel()
        activePing = null
        generation += 1
        webSocket?.cancel()
        webSocket = null
        state = ConnectionState.DISCONNECTED
        connectionQuality = ConnectionQuality.DISCONNECTED
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

    // MARK: - Liveness

    /** Checks whether the WebSocket is still alive by sending a ping. */
    suspend fun isAlive(): Boolean = measurePingRtt() != null

    /**
     * Sends an application-level ping and returns the round-trip time in seconds,
     * or null on failure. Concurrent callers share a single in-flight ping so the
     * single [pendingPong] slot is never stomped by overlapping pings.
     */
    suspend fun measurePingRtt(): Double? = withContext(scope.coroutineContext) {
        activePing?.let { return@withContext it.await() }
        val task = scope.async { performPing() }
        activePing = task
        val result = task.await()
        if (activePing === task) activePing = null
        result
    }

    /**
     * Performs a single ping/pong exchange. Called only from [measurePingRtt] —
     * dedup is enforced by [activePing]. Installs a fresh [pendingPong], sends the
     * ping, and awaits the pong with a 5 s timeout.
     */
    private suspend fun performPing(): Double? {
        if (webSocket == null || state != ConnectionState.CONNECTED) return null

        // Evict any prior pong slot (defensive — activePing dedup should prevent it).
        resolvePendingPong(false)
        val deferred = CompletableDeferred<Boolean>()
        pendingPong = deferred

        val start = System.nanoTime()
        try {
            sendInternal(ClientMessage.Ping)
        } catch (_: Exception) {
            resolvePendingPong(false)
            return null
        }

        val gotPong = withTimeoutOrNull(PONG_TIMEOUT_MS) { deferred.await() } ?: false
        // Clear the slot if the timeout (not a real pong) resolved us.
        if (pendingPong === deferred) pendingPong = null
        return if (gotPong) (System.nanoTime() - start) / 1_000_000_000.0 else null
    }

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

    // MARK: - Quality monitor

    /**
     * Starts the keepalive loop for connection [gen]. Pings every 10 s, records
     * the RTT, fires the death detector at three consecutive failures, and
     * otherwise republishes [connectionQuality]. The loop captures [gen] and bails
     * the moment a newer connection supersedes it.
     */
    private fun startQualityMonitor(gen: Long) {
        cancelKeepalive()
        rttWindow.clear()
        consecutiveFailures = 0
        connectionQuality = ConnectionQuality.EXCELLENT

        keepaliveJob = scope.launch {
            while (isActive) {
                delay(PING_INTERVAL_MS)
                if (!isActive || gen != generation || state != ConnectionState.CONNECTED) return@launch

                val rtt = measurePingRtt()
                if (!isActive || gen != generation) return@launch

                recordRtt(rtt)

                if (consecutiveFailures >= DEATH_THRESHOLD) {
                    markConnectionDead()
                    return@launch
                }

                connectionQuality = computeQuality()
            }
        }
    }

    /**
     * Appends an RTT sample to the sliding window, enforces the window cap, and
     * updates the consecutive-failure counter. A non-null sample resets failures
     * and reports a healthy ping so the coordinator can clear its recovery breaker.
     */
    private fun recordRtt(rtt: Double?) {
        rttWindow.addLast(rtt)
        if (rttWindow.size > WINDOW_SIZE) rttWindow.removeFirst()
        if (rtt == null) {
            consecutiveFailures += 1
        } else {
            consecutiveFailures = 0
            onHealthyPing?.invoke()
        }
    }

    private fun computeQuality(): ConnectionQuality {
        if (rttWindow.isEmpty()) return ConnectionQuality.EXCELLENT
        val successes = rttWindow.filterNotNull()
        val successRate = successes.size.toDouble() / rttWindow.size.toDouble()
        if (successes.isEmpty()) return ConnectionQuality.VERY_POOR
        val sorted = successes.sorted()
        val median = sorted[sorted.size / 2]
        return ConnectionQuality.of(median, successRate)
    }

    /**
     * Marks the current connection as dead: cancels the keepalive, bumps the
     * generation so stale callbacks are rejected, tears down the socket, and
     * notifies the coordinator. The coordinator owns recovery — never self-reconnect.
     */
    private fun markConnectionDead() {
        cancelKeepalive()
        resolvePendingPong(false)
        activePing?.cancel()
        activePing = null
        generation += 1
        webSocket?.cancel()
        webSocket = null
        state = ConnectionState.DISCONNECTED
        connectionQuality = ConnectionQuality.DISCONNECTED
        onSendFailed?.invoke()
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
                // ConcurrentHashMap iteration is weakly consistent and safe even
                // if a handler removes itself (or another subscriber is added on a
                // caller thread) mid-dispatch — no snapshot needed.
                for (handler in subscribers.values) {
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
        activePing?.cancel()
        activePing = null
        webSocket = null
        state = ConnectionState.DISCONNECTED
        connectionQuality = ConnectionQuality.DISCONNECTED
        onSendFailed?.invoke()
    }

    // MARK: - Test seams
    //
    // Exposed only for tests so the RTT/quality/death bookkeeping can be exercised
    // without waiting on the real 10 s keepalive interval or 5 s pong timeout.
    // Mirrors Swift's `_testOnly_*` hooks. Not for production use.

    internal fun testRecordRtt(rtt: Double?) = recordRtt(rtt)
    internal val testRttWindowCount: Int get() = rttWindow.size
    internal val testConsecutiveFailures: Int get() = consecutiveFailures
    internal fun testComputeQuality(): ConnectionQuality = computeQuality()

    /** Replicates the keepalive loop's death decision: fire the detector iff at threshold. */
    internal fun testMarkDeadIfNeeded() {
        if (consecutiveFailures >= DEATH_THRESHOLD) markConnectionDead()
    }

    companion object {
        const val PING_INTERVAL_MS = 10_000L
        const val PONG_TIMEOUT_MS = 5_000L
        const val WINDOW_SIZE = 6
        const val DEATH_THRESHOLD = 3

        /**
         * Transport-level (WebSocket opcode 0x9) ping interval. Defense-in-depth
         * ONLY — the authoritative liveness signal is the application-level
         * ping/pong on [PING_INTERVAL_MS], because some network configurations
         * silently drop protocol-level ping frames (the reason the app-level
         * keepalive exists). When 0x9 frames DO get through, this lets OkHttp
         * fail a dead socket via `onFailure` without waiting on the app-level
         * keepalive's three-strike death detector — covering the fully-idle
         * session (no typing, so the input-activity probe never fires). Set
         * longer than the app-level interval so the app-level path stays the
         * primary detector and the two don't double up on healthy connections.
         */
        const val TRANSPORT_PING_INTERVAL_MS = 20_000L

        private val defaultClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .pingInterval(TRANSPORT_PING_INTERVAL_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
                .build()
        }
    }
}
