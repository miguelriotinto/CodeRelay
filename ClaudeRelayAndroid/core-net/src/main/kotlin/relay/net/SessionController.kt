package relay.net

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import relay.protocol.ClientMessage
import relay.protocol.ServerMessage
import relay.protocol.SessionInfo
import java.util.UUID

/**
 * Protocol version constants. Ports `ClaudeRelayKit.protocolVersion` /
 * `minProtocolVersion`. The client sends [CURRENT] in `auth_request`; the server
 * echoes its version in `auth_success` and the controller rejects anything below
 * [MIN].
 */
object ProtocolVersions {
    const val CURRENT = 1
    const val MIN = 0
}

/**
 * Errors surfaced by [SessionController]. Ports `SessionController.SessionError`.
 */
class SessionException(
    message: String,
    /** True when the failure indicates the server saw us as not authenticated. */
    val isNotAuthenticated: Boolean = false,
    /**
     * True for the refusal raised on a DESYNCHRONIZED socket (see
     * [SessionController.isDesynchronized]). A typed flag rather than another
     * message match, because the caller's classification is load-bearing: this is
     * a TRANSPORT condition, and treating it as app-level would evict the active
     * terminal and clear the user's session over what is really just a socket that
     * needs replacing. Swift distinguishes it by enum case
     * (`SessionError.connectionDesynchronized`); this is the port of that.
     */
    val isDesynchronized: Boolean = false,
) : Exception(message)

/**
 * Orchestrates authentication and session lifecycle on top of a
 * [ConnectionSurface]. Ports `SessionController.swift`.
 *
 * The critical correctness property is replicated exactly: every request
 * installs its response subscriber **before** sending, so a response that beats
 * the await is still captured (via [ResumeGuard.pendingValue]). The guard
 * guarantees the awaiting coroutine is resumed exactly once even when the
 * response, the timeout, and a duplicate response all race.
 *
 * Not thread-safe across dispatchers — like the Swift original (`@MainActor`),
 * all mutable state ([sessionId], [isAuthenticated], the generation stamps) is
 * written and read under the coordinator's single confined dispatcher. The
 * stamps carry no `@Volatile`; cross-thread visibility is provided by that
 * confinement, not by the fields themselves.
 */
class SessionController(private val connection: ConnectionSurface) {

    var sessionId: UUID? = null
        private set

    var isAuthenticated = false
        private set

    /**
     * This connection's own token id, delivered in `auth_success`. Null against
     * older servers that don't send it — the coordinator's reconcile then falls
     * back to a strictly-safe "retain if still on the server" rule. Used to tell
     * "my session, transiently missing from the token-scoped list" from
     * "genuinely moved to another token".
     */
    var tokenId: String? = null
        private set

    /**
     * The connection generation when auth was established. Used to detect stale
     * auth after the WebSocket reconnects (the server then sees a fresh
     * unauthenticated handler).
     */
    var authenticatedGeneration: Long = 0L
        private set

    /**
     * The connection generation when the current [sessionId] attachment was
     * established (create/attach/resume succeeded). Server-side attachment is
     * per-connection-handler state, so a socket replacement silently orphans it:
     * the new handler has no attached PTY and **drops typed bytes without an
     * error** (RelayMessageHandler.swift `handleBinaryFrame` guard). Comparing
     * this stamp against [ConnectionSurface.generation] is the only client-side
     * way to detect that orphaned state — the transport stays alive and pongs
     * normally, so liveness probes can't see it.
     */
    var attachedGeneration: Long = 0L
        private set

    /**
     * Whether the controller is authenticated on the **current** connection.
     * False once the socket has been replaced since auth was established, and
     * false when there is no live socket at all.
     *
     * The liveness term is load-bearing, not belt-and-braces: a receive-loop
     * failure nils the socket WITHOUT bumping [ConnectionSurface.generation], so
     * generation equality alone reported "authenticated" over a socket that had
     * already gone. Callers then skipped re-auth, sent the RPC, and got
     * `notConnected` — an error `withAuth` does not retry, i.e. a silent dead end
     * (a blank session pane). Reporting invalid instead makes the handshake
     * reconnect first.
     */
    val isAuthValid: Boolean
        get() = isAuthenticated &&
            authenticatedGeneration == connection.generation &&
            connection.isConnected &&
            // A desynchronized socket can't carry an RPC, so auth over it is of no
            // use to a caller — report invalid and let the handshake replace it.
            !isDesynchronized

    /**
     * The generation of a socket left DESYNCHRONIZED by an RPC that timed out,
     * i.e. one with a request outstanding that nobody is waiting for any more.
     *
     * [rpcLock] guarantees one request in flight at a time, but a timeout retires
     * the waiter while leaving the *request* outstanding server-side. Its late
     * reply then lands on whichever waiter is installed when it arrives — and
     * with no request ids, that waiter cannot reject it. Two consecutive
     * `session_list`s is the worst case and the original bug verbatim: the launch
     * list times out, a post-create list follows, and the late pre-create reply
     * resolves it, so the new session is missing from the sidebar.
     *
     * So a timeout poisons the socket rather than just failing one call: every
     * later RPC on it fails until it is replaced. Keying on the generation makes
     * that self-expiring — any reconnect bumps it, and a fresh socket cannot
     * carry the old one's in-flight reply. `SessionHandshake` recovers with no
     * special case: its catch-all already does `resetAuth()` + `disconnect()`
     * and retries, which is exactly the required response.
     */
    private var desyncedGeneration: Long? = null

    /**
     * Whether the CURRENT socket is desynchronized — i.e. no RPC can run on it and
     * only replacing it will help.
     *
     * Public because the recovery layer has to know. Its "is the connection usable"
     * probe is a ping/pong, and pongs are routed inside the connection rather than
     * through this controller's RPC path, so a desynchronized socket pongs
     * perfectly while refusing every request. Recovery would then see a healthy
     * transport, decline to reconnect, and re-enter the same doomed restore on
     * every trigger — the socket is only ever cured by a reconnect, so something
     * has to ask for one. That is the same shape as the bug the liveness term in
     * [isAuthValid] fixed: "the transport is up" is not "the transport is usable".
     */
    val isDesynchronized: Boolean
        get() = desyncedGeneration == connection.generation

    /**
     * Whether [sessionId]'s server-side attachment was established on the
     * **current** connection. False when there is no attachment, or when the
     * socket has been replaced since the attach/resume succeeded (the server's
     * new handler has no attached PTY even though [sessionId] is still set).
     */
    val isAttachmentValid: Boolean
        get() = sessionId != null && attachedGeneration == connection.generation

    /** Resets auth so the next operation re-authenticates. Call after reconnect. */
    fun resetAuth() {
        isAuthenticated = false
        sessionId = null
    }

    // MARK: - Authentication

    /**
     * Sends an authentication request and waits for the server response. Includes
     * the client's protocol version and checks the server's version on success.
     */
    suspend fun authenticate(token: String) {
        val response = sendAndWaitForResponse(
            ClientMessage.AuthRequest(token = token, protocolVersion = ProtocolVersions.CURRENT),
            expected = setOf("auth_success", "auth_failure"),
        )
        when (response) {
            is ServerMessage.AuthSuccess -> {
                val serverVersion = response.protocolVersion ?: 0
                if (serverVersion < ProtocolVersions.MIN) {
                    isAuthenticated = false
                    throw SessionException(
                        "This app is not compatible with the server version running on the backend.",
                    )
                }
                isAuthenticated = true
                authenticatedGeneration = connection.generation
                // Null against older servers; the coordinator's reconcile falls
                // back to a safe "retain if still on the server" rule when unknown.
                response.tokenId?.let { tokenId = it }
            }
            is ServerMessage.AuthFailure -> {
                isAuthenticated = false
                throw SessionException("Authentication failed: ${response.reason}")
            }
            is ServerMessage.Error -> {
                // The server can reply with `error` on the auth path. A 400
                // "Already authenticated" means this socket is ALREADY
                // authenticated server-side (a client/server auth-state desync —
                // e.g. a redundant auth after a reconnect where the server still
                // held the socket authenticated). That's not a failure: adopt the
                // authenticated state so session creation proceeds. Without this,
                // the reply fell through to `else` and threw
                // `unexpected(response)` whose detail is the "error" type string.
                // Every other error (rate-limit 429, auth timeout 401, server
                // 500) is a real failure — surface its actual message.
                if (response.code == 400) {
                    isAuthenticated = true
                    authenticatedGeneration = connection.generation
                } else {
                    isAuthenticated = false
                    throw unexpected(response.message)
                }
            }
            else -> throw unexpected(response)
        }
    }

    // MARK: - Session lifecycle

    /** Creates a new terminal session on the server. Returns the session UUID. */
    suspend fun createSession(name: String? = null, cols: UShort? = null, rows: UShort? = null): UUID {
        val response = sendAndWaitForResponse(
            ClientMessage.SessionCreate(name, cols, rows),
            expected = setOf("session_created"),
        )
        return when (response) {
            is ServerMessage.SessionCreated -> response.sessionId.also { recordAttachment(it) }
            is ServerMessage.Error -> throw unexpected(response.message)
            else -> throw unexpected(response)
        }
    }

    /**
     * Attaches to a session that may still be active on another connection.
     * Unlike resume, this does not require the session to be detached first.
     */
    suspend fun attachSession(id: UUID) {
        val response = sendAndWaitForResponse(
            ClientMessage.SessionAttach(id),
            expected = setOf("session_attached"),
        )
        when (response) {
            is ServerMessage.SessionAttached -> recordAttachment(response.sessionId)
            is ServerMessage.Error -> throw unexpected(response.message)
            else -> throw unexpected(response)
        }
    }

    /**
     * Resumes an existing session by its identifier. When [skipReplay] is true the
     * server skips the ring-buffer replay (the client already holds the scrollback).
     */
    suspend fun resumeSession(id: UUID, skipReplay: Boolean = false) {
        val response = sendAndWaitForResponse(
            ClientMessage.SessionResume(id, skipReplay),
            expected = setOf("session_resumed"),
        )
        when (response) {
            is ServerMessage.SessionResumed -> recordAttachment(response.sessionId)
            is ServerMessage.Error -> throw unexpected(response.message)
            else -> throw unexpected(response)
        }
    }

    /** Lists all sessions owned by the authenticated token. */
    suspend fun listSessions(): List<SessionInfo> {
        val response = sendAndWaitForResponse(
            ClientMessage.SessionList,
            expected = setOf("session_list_result"),
        )
        return when (response) {
            is ServerMessage.SessionList -> response.sessions
            is ServerMessage.Error -> throw unexpected(response.message)
            else -> throw unexpected(response)
        }
    }

    /** Lists all sessions across all tokens. Used for cross-device attach. */
    suspend fun listAllSessions(): List<SessionInfo> {
        val response = sendAndWaitForResponse(
            ClientMessage.SessionListAll,
            expected = setOf("session_list_all_result"),
        )
        return when (response) {
            is ServerMessage.SessionListAll -> response.sessions
            is ServerMessage.Error -> throw unexpected(response.message)
            else -> throw unexpected(response)
        }
    }

    /**
     * Renames a session. Fire-and-forget — the server broadcasts the rename to all
     * connections via `session_renamed`. No response is awaited (matches Swift).
     */
    suspend fun renameSession(id: UUID, name: String) {
        connection.send(ClientMessage.SessionRename(id, name))
    }

    /** Detaches from the current session without terminating it. */
    suspend fun detach() {
        val response = sendAndWaitForResponse(
            ClientMessage.SessionDetach,
            expected = setOf("session_detached"),
        )
        when (response) {
            is ServerMessage.SessionDetached -> sessionId = null
            is ServerMessage.Error -> throw unexpected(response.message)
            else -> throw unexpected(response)
        }
    }

    // MARK: - Internal helpers

    /** Stamps a successful create/attach/resume against the current connection. */
    private fun recordAttachment(id: UUID) {
        sessionId = id
        attachedGeneration = connection.generation
    }

    private fun unexpected(response: ServerMessage): SessionException = unexpected(response.typeString)

    private fun unexpected(detail: String): SessionException =
        SessionException(
            "Unexpected server response: $detail",
            isNotAuthenticated = detail.contains("not authenticated", ignoreCase = true),
        )

    /**
     * Serializes request-response RPCs: **at most one may be outstanding on a
     * connection at a time.**
     *
     * This is a protocol constraint, not an optimization. Replies carry no request
     * id, so the only thing a waiter can match on is the response TYPE — and
     * `error` is a legal reply to *every* request. Two overlapping RPCs therefore
     * always share at least one possible reply type, and whichever reply lands
     * first resolves BOTH waiters:
     *
     *  - a `session_list` from a pane refresh and one from a handshake: both
     *    resolve on the first `session_list_result`, so the later request (the one
     *    issued *after* a create) renders a pre-create list and the new session
     *    vanishes from the sidebar;
     *  - an `error` for a failing `session_create` also completes a concurrent
     *    `session_list` waiter, so the handshake concludes ITS list failed, drops
     *    the socket and retries — tearing down the transport under the create.
     *
     * Scoping each waiter to its own reply type (see [expected] below) shrinks the
     * window but cannot close it, because of `error`. Serializing does close it.
     *
     * Cost: a queued RPC waits for the one ahead of it, worst case
     * [RESPONSE_TIMEOUT_MS]. That is strictly better than the cross-delivery it
     * replaces, which corrupted state silently.
     *
     * **Constraint for future code: never issue an RPC from inside another RPC's
     * await window** — this lock is not reentrant and that would self-deadlock.
     * Today's paths are all sequential: `withAuth` completes `ensureAuthenticated`
     * (one RPC) before running its body (the next RPC), and inbound-push handlers
     * dispatch onto their own coroutines rather than calling back in.
     */
    private val rpcLock = Mutex()

    /**
     * Installs a response subscription, sends [message], and waits up to
     * [RESPONSE_TIMEOUT_MS] for a reply whose type is in [expected] (or `error`).
     * The subscriber is installed **before** the send so a response that arrives
     * during/just after the send is captured by [ResumeGuard.pendingValue] rather
     * than lost.
     *
     * [expected] is deliberately **required**, with no permissive default. It is
     * the second half of the correlation story: [rpcLock] guarantees only one RPC
     * is outstanding, and the type scope guarantees that even a stray *pushed*
     * message (or a late reply from an RPC that already timed out) can't resolve
     * this one. A waiter matching every response type produced the cross-device
     * "No Sessions Available" bug — `listAllSessions` captured a parallel
     * `fetchSessions`' `session_list_result`, fell into its `else` branch and
     * returned empty. Every call site names its own reply type, so a new one
     * cannot silently inherit the hazard.
     */
    private suspend fun sendAndWaitForResponse(
        message: ClientMessage,
        expected: Set<String>,
    ): ServerMessage = rpcLock.withLock { awaitResponse(message, expected) }

    private suspend fun awaitResponse(
        message: ClientMessage,
        expected: Set<String>,
    ): ServerMessage {
        // A previous RPC on this socket timed out, so it still owes a reply that
        // this waiter would happily accept. Refuse until the socket is replaced.
        if (isDesynchronized) {
            throw SessionException(DESYNC_MESSAGE, isDesynchronized = true)
        }

        val guard = ResumeGuard()

        // 1) Install subscription BEFORE sending. The subscriber resumes the
        //    deferred if we're waiting, or stores the value for the post-send check.
        //    "error" is always accepted: the server answers any request with it.
        val matchTypes = expected + "error"
        val subscriptionId = connection.addServerMessageSubscriber { serverMessage ->
            if (serverMessage.typeString in matchTypes) {
                guard.deliver(serverMessage)
            }
        }
        // The generation the request actually went out on, and whether it went out
        // at all. Both are needed by the poison decision in `finally`.
        var sentGeneration: Long? = null
        try {
            // 2) Send.
            connection.send(message)
            // Read AFTER the send: a send that threw leaves nothing outstanding, so
            // it must not poison anything.
            sentGeneration = connection.generation

            // 3) If the response already arrived during send, return it.
            guard.pendingValue?.let { return it }

            // 4) Otherwise wait with a timeout.
            return withTimeoutOrNull(RESPONSE_TIMEOUT_MS) { guard.await() }
                ?: throw SessionException("The operation timed out.")
        } finally {
            connection.removeSubscriber(subscriptionId)
            // Sent but never answered ⇒ the request is STILL OUTSTANDING
            // server-side while nobody waits for it, so its late reply could
            // resolve some future waiter. Poison the socket it went out on.
            //
            // Deliberately in `finally` rather than on the timeout branch alone:
            // cancellation gets here too. A coroutine cancelled after the send
            // (scope torn down, recovery superseding a pass) abandons an
            // outstanding request just as surely as a timeout does, and handling
            // only the timeout left exactly the original corruption open — the
            // next same-type RPC would consume the abandoned request's reply.
            //
            // The generation is the one captured at send time, NOT the current
            // one: if a reconnect intervened, the request died with the old
            // socket and the fresh one can never receive its reply. Poisoning the
            // fresh socket would refuse every RPC on a healthy connection until
            // another reconnect — and if none came, permanently.
            if (sentGeneration != null && guard.pendingValue == null) {
                desyncedGeneration = sentGeneration
            }
        }
    }

    companion object {
        const val RESPONSE_TIMEOUT_MS = 10_000L

        /** User-facing text for the desynchronized-socket refusal. */
        const val DESYNC_MESSAGE = "The connection to the server needs to be re-established."
    }
}

/**
 * Ensures a waiter is resumed exactly once. Ports the Swift `ResumeGuard`. A
 * response that arrives before [await] is parked in [pendingValue]; the first
 * [deliver] wins, all later deliveries (including a duplicate response) are no-ops.
 */
private class ResumeGuard {
    private val deferred = CompletableDeferred<ServerMessage>()

    /** Set when a matching response arrives before the awaiter is suspended. */
    @Volatile
    var pendingValue: ServerMessage? = null
        private set

    fun deliver(value: ServerMessage) {
        // complete() returns false if already completed → "resume exactly once".
        if (deferred.complete(value)) {
            pendingValue = value
        }
    }

    suspend fun await(): ServerMessage = deferred.await()
}
