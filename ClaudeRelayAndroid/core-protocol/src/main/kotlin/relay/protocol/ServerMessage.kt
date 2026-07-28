package relay.protocol

import java.util.UUID

/**
 * Messages sent from the server to the client.
 *
 * Ports `ServerMessage.swift`. Like [ClientMessage], these carry a [typeString]
 * and are framed/parsed manually by [MessageEnvelope]. Note that the session
 * list responses use `session_list_result` / `session_list_all_result` wire
 * types to stay disjoint from the client's request types.
 */
sealed interface ServerMessage {
    val typeString: String

    data class AuthSuccess(val protocolVersion: Int? = null, val tokenId: String? = null) : ServerMessage {
        override val typeString get() = "auth_success"
    }

    data class AuthFailure(val reason: String) : ServerMessage {
        override val typeString get() = "auth_failure"
    }

    data class SessionCreated(val sessionId: UUID, val cols: UShort, val rows: UShort) : ServerMessage {
        override val typeString get() = "session_created"
    }

    data class SessionAttached(val sessionId: UUID, val state: String) : ServerMessage {
        override val typeString get() = "session_attached"
    }

    data class SessionResumed(val sessionId: UUID) : ServerMessage {
        override val typeString get() = "session_resumed"
    }

    data class ReplayComplete(val sessionId: UUID) : ServerMessage {
        override val typeString get() = "replay_complete"
    }

    data object SessionDetached : ServerMessage {
        override val typeString get() = "session_detached"
    }

    data class SessionTerminated(val sessionId: UUID, val reason: String) : ServerMessage {
        override val typeString get() = "session_terminated"
    }

    data class SessionExpired(val sessionId: UUID) : ServerMessage {
        override val typeString get() = "session_expired"
    }

    data class SessionStateMsg(val sessionId: UUID, val state: String) : ServerMessage {
        override val typeString get() = "session_state"
    }

    data class SessionActivity(
        val sessionId: UUID,
        val activity: ActivityState,
        val agent: String? = null,
        val agentState: AgentDetectedState? = null,
        val title: String? = null,
    ) : ServerMessage {
        override val typeString get() = "session_activity"
    }

    data class SessionStolen(val sessionId: UUID) : ServerMessage {
        override val typeString get() = "session_stolen"
    }

    data class SessionRenamed(val sessionId: UUID, val name: String) : ServerMessage {
        override val typeString get() = "session_renamed"
    }

    data class SessionList(val sessions: List<SessionInfo>) : ServerMessage {
        override val typeString get() = "session_list_result"
    }

    data class SessionListAll(val sessions: List<SessionInfo>) : ServerMessage {
        override val typeString get() = "session_list_all_result"
    }

    data class ResizeAck(val cols: UShort, val rows: UShort) : ServerMessage {
        override val typeString get() = "resize_ack"
    }

    data class PasteImageResult(val success: Boolean) : ServerMessage {
        override val typeString get() = "paste_image_result"
    }

    data object Pong : ServerMessage {
        override val typeString get() = "pong"
    }

    data class Error(val code: Int, val message: String) : ServerMessage {
        override val typeString get() = "error"
    }

    companion object {
        val ALL_TYPE_STRINGS: Set<String> = setOf(
            "auth_success", "auth_failure",
            "session_created", "session_attached", "session_resumed", "replay_complete",
            "session_detached", "session_terminated", "session_expired", "session_state",
            "session_activity", "session_stolen", "session_renamed",
            "session_list_result", "session_list_all_result",
            "resize_ack", "paste_image_result", "pong", "error",
        )
    }
}
