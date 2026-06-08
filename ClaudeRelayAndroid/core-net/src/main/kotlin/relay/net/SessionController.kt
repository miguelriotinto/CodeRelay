package relay.net

import kotlinx.coroutines.CompletableDeferred
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
 */
class SessionController(private val connection: ConnectionSurface) {

    var sessionId: UUID? = null
        private set

    var isAuthenticated = false
        private set

    /**
     * The connection generation when auth was established. Used to detect stale
     * auth after the WebSocket reconnects (the server then sees a fresh
     * unauthenticated handler).
     */
    var authenticatedGeneration: Long = 0L
        private set

    /**
     * Whether the controller is authenticated on the **current** connection.
     * False once the socket has been replaced since auth was established.
     */
    val isAuthValid: Boolean
        get() = isAuthenticated && authenticatedGeneration == connection.generation

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
            }
            is ServerMessage.AuthFailure -> {
                isAuthenticated = false
                throw SessionException("Authentication failed: ${response.reason}")
            }
            else -> throw unexpected(response)
        }
    }

    // MARK: - Session lifecycle

    /** Creates a new terminal session on the server. Returns the session UUID. */
    suspend fun createSession(name: String? = null): UUID {
        val response = sendAndWaitForResponse(ClientMessage.SessionCreate(name))
        return when (response) {
            is ServerMessage.SessionCreated -> response.sessionId.also { sessionId = it }
            is ServerMessage.Error -> throw unexpected(response.message)
            else -> throw unexpected(response)
        }
    }

    /**
     * Attaches to a session that may still be active on another connection.
     * Unlike resume, this does not require the session to be detached first.
     */
    suspend fun attachSession(id: UUID) {
        val response = sendAndWaitForResponse(ClientMessage.SessionAttach(id))
        when (response) {
            is ServerMessage.SessionAttached -> sessionId = response.sessionId
            is ServerMessage.Error -> throw unexpected(response.message)
            else -> throw unexpected(response)
        }
    }

    /**
     * Resumes an existing session by its identifier. When [skipReplay] is true the
     * server skips the ring-buffer replay (the client already holds the scrollback).
     */
    suspend fun resumeSession(id: UUID, skipReplay: Boolean = false) {
        val response = sendAndWaitForResponse(ClientMessage.SessionResume(id, skipReplay))
        when (response) {
            is ServerMessage.SessionResumed -> sessionId = response.sessionId
            is ServerMessage.Error -> throw unexpected(response.message)
            else -> throw unexpected(response)
        }
    }

    /** Lists all sessions owned by the authenticated token. */
    suspend fun listSessions(): List<SessionInfo> {
        val response = sendAndWaitForResponse(ClientMessage.SessionList)
        return when (response) {
            is ServerMessage.SessionList -> response.sessions
            is ServerMessage.Error -> throw unexpected(response.message)
            else -> throw unexpected(response)
        }
    }

    /** Lists all sessions across all tokens. Used for cross-device attach. */
    suspend fun listAllSessions(): List<SessionInfo> {
        val response = sendAndWaitForResponse(ClientMessage.SessionListAll)
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
        val response = sendAndWaitForResponse(ClientMessage.SessionDetach)
        when (response) {
            is ServerMessage.SessionDetached -> sessionId = null
            is ServerMessage.Error -> throw unexpected(response.message)
            else -> throw unexpected(response)
        }
    }

    // MARK: - Internal helpers

    private fun unexpected(response: ServerMessage): SessionException = unexpected(response.typeString)

    private fun unexpected(detail: String): SessionException =
        SessionException(
            "Unexpected server response: $detail",
            isNotAuthenticated = detail.contains("not authenticated", ignoreCase = true),
        )

    /**
     * Installs a response subscription, sends [message], and waits up to
     * [RESPONSE_TIMEOUT_MS] for a matching reply. The subscriber is installed
     * **before** the send so a response that arrives during/just after the send is
     * captured by [ResumeGuard.pendingValue] rather than lost.
     */
    private suspend fun sendAndWaitForResponse(message: ClientMessage): ServerMessage {
        val guard = ResumeGuard()

        // 1) Install subscription BEFORE sending. The subscriber resumes the
        //    deferred if we're waiting, or stores the value for the post-send check.
        val subscriptionId = connection.addServerMessageSubscriber { serverMessage ->
            if (serverMessage.typeString in RESPONSE_TYPES) {
                guard.deliver(serverMessage)
            }
        }
        try {
            // 2) Send.
            connection.send(message)

            // 3) If the response already arrived during send, return it.
            guard.pendingValue?.let { return it }

            // 4) Otherwise wait with a timeout. A null result means the timer won.
            return withTimeoutOrNull(RESPONSE_TIMEOUT_MS) { guard.await() }
                ?: throw SessionException("The operation timed out.")
        } finally {
            connection.removeSubscriber(subscriptionId)
        }
    }

    companion object {
        const val RESPONSE_TIMEOUT_MS = 10_000L

        /**
         * Response message types awaited by command requests. Mirrors the Swift
         * `responseTypes` set exactly — note that `resize_ack`,
         * `session_terminated`, and `session_renamed` are deliberately NOT awaited
         * here (resize is fire-and-forget acked separately; terminate/rename are
         * server-pushed broadcasts handled via subscribers, not request replies).
         */
        private val RESPONSE_TYPES: Set<String> = setOf(
            "auth_success", "auth_failure",
            "session_created", "session_attached", "session_resumed", "session_detached",
            "session_list_result", "session_list_all_result",
            "error",
        )
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
