package relay.session

import kotlinx.coroutines.CompletableDeferred
import relay.net.ConnectionSurface
import relay.protocol.ClientMessage
import relay.protocol.ConnectionConfig
import relay.protocol.ServerMessage
import relay.protocol.SessionInfo
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Test doubles shared by [SessionCoordinatorTest] and [SessionHandshakeTest].
 *
 * Extracted verbatim from SessionCoordinatorTest so both suites drive the SAME
 * fakes: the handshake and the coordinator ops run over one connection, and a
 * double that drifted between the two suites would let a regression pass in one
 * while the other still "proved" the old behavior.
 */
// ---- Shared ordered call-log -------------------------------------------

internal class CallLog {
    val entries = ArrayList<String>()
    fun add(entry: String) = entries.add(entry)
    /** True when [a] occurs before [b] in the log (both must be present). */
    fun precedes(a: String, b: String): Boolean {
        val ia = entries.indexOf(a)
        val ib = entries.indexOf(b)
        return ia >= 0 && ib >= 0 && ia < ib
    }
    operator fun contains(entry: String) = entries.contains(entry)
}

// ---- Fake ConnectionSurface backing the REAL SessionController ---------
//
// On send it records the RPC and immediately delivers a canned response so
// the real SessionController.sendAndWaitForResponse resolves without a socket.

internal class FakeConnectionSurface(private val log: CallLog) : ConnectionSurface {
    override var generation: Long = 1L
    private val subscribers = ConcurrentHashMap<UUID, (ServerMessage) -> Unit>()

    /** Override to fail a specific op (e.g. attach) — return the error to throw via response. */
    var responder: (ClientMessage) -> ServerMessage? = { defaultResponse(it) }

    /**
     * Awaited between logging an RPC and delivering its response — lets a
     * test park a session op mid-flight (e.g. between detach and the create
     * response) to probe the coordinator's transient state.
     */
    var sendGate: (suspend (ClientMessage) -> Unit)? = null

    override fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID {
        val id = UUID.randomUUID()
        subscribers[id] = handler
        return id
    }

    override fun removeSubscriber(id: UUID) { subscribers.remove(id) }

    /** Captured cols/rows from the most recent SessionCreate RPC (null if never sent or omitted). */
    var lastCreateCols: UShort? = null
    var lastCreateRows: UShort? = null

    /** Captured skipReplay from the most recent SessionResume RPC (null if never sent). */
    var lastResumeSkipReplay: Boolean? = null

    override suspend fun send(message: ClientMessage) {
        log.add("rpc:${message.typeString}")
        if (message is ClientMessage.SessionCreate) {
            lastCreateCols = message.cols
            lastCreateRows = message.rows
        }
        if (message is ClientMessage.SessionResume) {
            lastResumeSkipReplay = message.skipReplay
        }
        sendGate?.invoke(message)
        responder(message)?.let { response ->
            for (h in subscribers.values) h(response)
        }
    }

    private fun defaultResponse(message: ClientMessage): ServerMessage? = when (message) {
        is ClientMessage.AuthRequest -> ServerMessage.AuthSuccess(protocolVersion = 1, tokenId = myTokenId)
        is ClientMessage.SessionCreate -> ServerMessage.SessionCreated(NEW_SESSION_ID, 80u, 24u)
        is ClientMessage.SessionAttach -> ServerMessage.SessionAttached(message.sessionId, "running")
        is ClientMessage.SessionResume -> ServerMessage.SessionResumed(message.sessionId)
        is ClientMessage.SessionDetach -> ServerMessage.SessionDetached
        is ClientMessage.SessionList ->
            if (failSessionList) ServerMessage.Error(code = 500, message = "session_list unavailable")
            else ServerMessage.SessionList(sessionsOnServer)
        // SessionListAll defaults to the token-scoped list, but tests can stage a
        // SUPERSET (sessions on OTHER tokens) by setting [allSessionsOnServer] to
        // exercise the prune-against-all-sessions behavior.
        is ClientMessage.SessionListAll ->
            if (failAllSessions) {
                ServerMessage.Error(code = 500, message = "session_list_all unavailable")
            } else {
                ServerMessage.SessionListAll(allSessionsOnServer ?: sessionsOnServer)
            }
        else -> null // rename/terminate/ping are fire-and-forget here
    }

    /** Sessions the server reports for SessionList (token-scoped). Mutable so tests can stage prune scenarios. */
    var sessionsOnServer: List<SessionInfo> = emptyList()

    /**
     * Sessions the server reports for SessionListAll (all tokens). `null` ⇒ mirror
     * [sessionsOnServer]; set to a superset to model sessions owned under another
     * token, which must survive the prune.
     */
    var allSessionsOnServer: List<SessionInfo>? = null

    /** When true, SessionListAll responds with an Error so listAllSessions throws. */
    var failAllSessions: Boolean = false

    /** When true, SessionList responds with an Error so listSessions throws. */
    var failSessionList: Boolean = false

    /**
     * The token id the server reports in auth_success. Defaults to "tok" to
     * match the [session] helper's tokenId, so a session in the all-sessions
     * list is classified as owned by THIS token unless a test overrides it.
     * Set null to model an older server that doesn't send a token id.
     */
    var myTokenId: String? = "tok"

    companion object {
        val NEW_SESSION_ID: UUID = UUID.fromString("00000000-0000-0000-0000-0000000000aa")
    }
}

// ---- Fake CoordinatorConnection (wiring + control sends) ---------------

internal class FakeCoordinatorConnection(private val log: CallLog) : CoordinatorConnection {
    var alive: Boolean = true

    /**
     * Whether the transport reports a socket. Starts true (a fake surface always
     * answers RPCs), so tests that don't care see the old behavior; set false to
     * model the socket the handshake must reconnect before authenticating.
     */
    var connected: Boolean = true
    override val isConnected: Boolean get() = connected
    var lastWiredHandler: ((ByteArray) -> Unit)? = null
    /** When set, forceReconnect awaits it (lets a test park the recovery pass). */
    var forceReconnectGate: CompletableDeferred<Unit>? = null
    /**
     * When set, isAlive awaits it — parks a recovery pass inside the probe,
     * BEFORE it commits (isRecovering is still false there), so a test can
     * race a user op into that window.
     */
    var isAliveGate: CompletableDeferred<Unit>? = null
    /**
     * Invoked on forceReconnect — lets a test mirror the real transport, where
     * reconnecting bumps the (shared) connection generation that the
     * SessionController's auth/attachment stamps are compared against.
     */
    var onForceReconnect: (() -> Unit)? = null
    private val subscribers = ConcurrentHashMap<UUID, (ServerMessage) -> Unit>()

    override var onTerminalOutput: ((ByteArray) -> Unit)? = null
        set(value) {
            field = value
            lastWiredHandler = value
            log.add("wire")
        }
    override var onSendFailed: (() -> Unit)? = null
    override var onHealthyPing: (() -> Unit)? = null

    override suspend fun connect(config: ConnectionConfig, token: String) { log.add("connect") }
    override suspend fun forceReconnect() {
        log.add("forceReconnect")
        onForceReconnect?.invoke()
        forceReconnectGate?.await()
    }
    override suspend fun disconnect() { log.add("disconnect") }
    override suspend fun isAlive(): Boolean {
        isAliveGate?.await()
        return alive
    }
    override suspend fun send(message: ClientMessage) { log.add("send:${message.typeString}") }
    override fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID {
        val id = UUID.randomUUID()
        subscribers[id] = handler
        return id
    }
    override fun removeSubscriber(id: UUID) { subscribers.remove(id) }

    /** Push a server message through the coordinator's installed fan-in. */
    fun deliver(message: ServerMessage) { subscribers.values.forEach { it(message) } }
}

// ---- In-memory OwnershipStore ------------------------------------------

internal class FakeOwnershipStore(
    private val log: CallLog? = null,
    seedNames: Map<UUID, String> = emptyMap(),
    seedAgents: Map<UUID, String> = emptyMap(),
) : OwnershipStore {
    private val namesMap = seedNames.toMutableMap()
    private val agentsMap = seedAgents.toMutableMap()

    override val names: Map<UUID, String> get() = namesMap.toMap()
    override val agents: Map<UUID, String> get() = agentsMap.toMap()

    override fun setName(id: UUID, name: String?) {
        if (name == null) namesMap.remove(id) else namesMap[id] = name
    }
    override fun setAgent(id: UUID, agentId: String?) {
        if (agentId == null) agentsMap.remove(id) else agentsMap[id] = agentId
        log?.add("setAgent")
    }
}
