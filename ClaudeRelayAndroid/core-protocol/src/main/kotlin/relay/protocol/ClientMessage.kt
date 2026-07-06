package relay.protocol

import java.util.UUID

/**
 * Messages sent from the client to the server.
 *
 * Ports `ClientMessage.swift`. These are plain Kotlin types carrying a
 * [typeString]; the wire `{"type":..,"payload":..}` framing and per-case payload
 * shape are handled manually by [MessageEnvelope] — there is no kotlinx
 * polymorphic discriminator.
 */
sealed interface ClientMessage {
    val typeString: String

    data class AuthRequest(val token: String, val protocolVersion: Int? = null) : ClientMessage {
        override val typeString get() = "auth_request"
    }

    data class SessionCreate(
        val name: String? = null,
        val cols: UShort? = null,
        val rows: UShort? = null,
    ) : ClientMessage {
        override val typeString get() = "session_create"
    }

    data class SessionAttach(val sessionId: UUID) : ClientMessage {
        override val typeString get() = "session_attach"
    }

    /**
     * Resume a detached session. [skipReplay] (default false) lets the client
     * opt out of the server's ring-buffer replay when it already holds a live
     * terminal with full scrollback — e.g. switching tabs on the same device.
     */
    data class SessionResume(val sessionId: UUID, val skipReplay: Boolean = false) : ClientMessage {
        override val typeString get() = "session_resume"
    }

    data object SessionDetach : ClientMessage {
        override val typeString get() = "session_detach"
    }

    data class SessionTerminate(val sessionId: UUID) : ClientMessage {
        override val typeString get() = "session_terminate"
    }

    data object SessionList : ClientMessage {
        override val typeString get() = "session_list"
    }

    data object SessionListAll : ClientMessage {
        override val typeString get() = "session_list_all"
    }

    data class SessionRename(val sessionId: UUID, val name: String) : ClientMessage {
        override val typeString get() = "session_rename"
    }

    data class Resize(val cols: UShort, val rows: UShort) : ClientMessage {
        override val typeString get() = "resize"
    }

    /**
     * Ask the server to SIGWINCH the attached session's foreground process
     * group so full-screen apps re-emit their whole screen. Used by
     * tap-to-redraw: a client-side repaint can only redraw the local (possibly
     * corrupt) grid — only the running application can rebuild the content.
     */
    data object Refresh : ClientMessage {
        override val typeString get() = "refresh"
    }

    data class PasteImage(val data: String) : ClientMessage {
        override val typeString get() = "paste_image"
    }

    data object Ping : ClientMessage {
        override val typeString get() = "ping"
    }

    companion object {
        val ALL_TYPE_STRINGS: Set<String> = setOf(
            "auth_request",
            "session_create", "session_attach", "session_resume", "session_detach",
            "session_terminate", "session_list", "session_list_all", "session_rename",
            "resize", "refresh", "paste_image", "ping",
        )
    }
}
