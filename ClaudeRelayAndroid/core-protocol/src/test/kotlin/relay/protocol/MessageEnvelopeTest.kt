package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import java.util.UUID

class MessageEnvelopeTest {
    // MARK: - Encoding (client → wire)

    @Test fun `encode auth_request with version`() {
        val msg = ClientMessage.AuthRequest(token = "tok", protocolVersion = 1)
        assertEquals(
            """{"type":"auth_request","payload":{"token":"tok","protocolVersion":1}}""",
            MessageEnvelope.encodeClient(msg),
        )
    }

    @Test fun `encode auth_request omits null version`() {
        val msg = ClientMessage.AuthRequest(token = "tok")
        assertEquals(
            """{"type":"auth_request","payload":{"token":"tok"}}""",
            MessageEnvelope.encodeClient(msg),
        )
    }

    @Test fun `encode ping carries empty payload`() {
        assertEquals(
            """{"type":"ping","payload":{}}""",
            MessageEnvelope.encodeClient(ClientMessage.Ping),
        )
    }

    @Test fun `encode session_detach and session_list carry empty payload`() {
        assertEquals("""{"type":"session_detach","payload":{}}""", MessageEnvelope.encodeClient(ClientMessage.SessionDetach))
        assertEquals("""{"type":"session_list","payload":{}}""", MessageEnvelope.encodeClient(ClientMessage.SessionList))
    }

    @Test fun `encode session_resume omits skipReplay when false`() {
        val id = UUID.fromString("11111111-2222-3333-4444-555555555555")
        assertEquals(
            """{"type":"session_resume","payload":{"sessionId":"11111111-2222-3333-4444-555555555555"}}""",
            MessageEnvelope.encodeClient(ClientMessage.SessionResume(id, skipReplay = false)),
        )
    }

    @Test fun `encode session_resume includes skipReplay when true`() {
        val id = UUID.fromString("11111111-2222-3333-4444-555555555555")
        assertEquals(
            """{"type":"session_resume","payload":{"sessionId":"11111111-2222-3333-4444-555555555555","skipReplay":true}}""",
            MessageEnvelope.encodeClient(ClientMessage.SessionResume(id, skipReplay = true)),
        )
    }

    // MARK: - Decoding (wire → server)

    @Test fun `decode auth_success`() {
        val msg = MessageEnvelope.decodeServer("""{"type":"auth_success","payload":{"protocolVersion":2}}""")
        assertEquals(ServerMessage.AuthSuccess(protocolVersion = 2), msg)
    }

    @Test fun `decode auth_success without version`() {
        val msg = MessageEnvelope.decodeServer("""{"type":"auth_success","payload":{}}""")
        assertEquals(ServerMessage.AuthSuccess(protocolVersion = null), msg)
    }

    @Test fun `decode pong`() {
        assertEquals(ServerMessage.Pong, MessageEnvelope.decodeServer("""{"type":"pong","payload":{}}"""))
    }

    @Test fun `decode session_activity with legacy claude_active maps to AGENT_ACTIVE with null agent`() {
        val id = UUID.fromString("11111111-2222-3333-4444-555555555555")
        val msg = MessageEnvelope.decodeServer(
            """{"type":"session_activity","payload":{"sessionId":"11111111-2222-3333-4444-555555555555","activity":"claude_active"}}""",
        )
        val activity = msg as ServerMessage.SessionActivity
        assertEquals(id, activity.sessionId)
        assertEquals(ActivityState.AGENT_ACTIVE, activity.activity)
        assertNull(activity.agent)
    }

    @Test fun `decode unknown type throws`() {
        assertThrows(IllegalArgumentException::class.java) {
            MessageEnvelope.decodeServer("""{"type":"totally_unknown","payload":{}}""")
        }
    }
}
