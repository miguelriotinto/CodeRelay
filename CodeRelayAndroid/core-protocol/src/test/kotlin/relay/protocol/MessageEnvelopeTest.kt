package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
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

    @Test fun `encode refresh carries empty payload`() {
        assertEquals(
            """{"type":"refresh","payload":{}}""",
            MessageEnvelope.encodeClient(ClientMessage.Refresh),
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

    @Test fun `decode session_list_result with populated sessions`() {
        val first = "11111111-2222-3333-4444-555555555555"
        val second = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        val text = """
            {"type":"session_list_result","payload":{"sessions":[
              {"id":"$first","name":"alpha","state":"active-attached","tokenId":"tok1",
               "createdAt":740000000.5,"cols":120,"rows":30,"activity":"agent_idle","agent":"claude"},
              {"id":"$second","state":"created","tokenId":"tok2",
               "createdAt":740000001.0,"cols":80,"rows":24}
            ]}}
        """.trimIndent()

        val list = MessageEnvelope.decodeServer(text) as ServerMessage.SessionList
        assertEquals(2, list.sessions.size)

        val s0 = list.sessions[0]
        assertEquals(UUID.fromString(first), s0.id)
        assertEquals("alpha", s0.name)
        assertEquals(SessionState.ACTIVE_ATTACHED, s0.state)
        assertEquals("tok1", s0.tokenId)
        assertEquals(120.toUShort(), s0.cols)
        assertEquals(30.toUShort(), s0.rows)
        assertEquals(ActivityState.AGENT_IDLE, s0.activity)
        assertEquals("claude", s0.agent)

        val s1 = list.sessions[1]
        assertEquals(UUID.fromString(second), s1.id)
        assertNull(s1.name)
        assertEquals(SessionState.CREATED, s1.state)
        assertEquals("tok2", s1.tokenId)
        assertEquals(80.toUShort(), s1.cols)
        assertEquals(24.toUShort(), s1.rows)
        assertNull(s1.activity)
    }

    @Test fun `decode session_list_result with empty sessions array`() {
        val msg = MessageEnvelope.decodeServer("""{"type":"session_list_result","payload":{"sessions":[]}}""")
        val list = msg as ServerMessage.SessionList
        assertTrue(list.sessions.isEmpty())
    }

    @Test fun `decode session_list_all_result with populated sessions`() {
        val id = "11111111-2222-3333-4444-555555555555"
        val text = """
            {"type":"session_list_all_result","payload":{"sessions":[
              {"id":"$id","state":"active-detached","tokenId":"tok9",
               "createdAt":740000000.5,"cols":100,"rows":40}
            ]}}
        """.trimIndent()

        val list = MessageEnvelope.decodeServer(text) as ServerMessage.SessionListAll
        assertEquals(1, list.sessions.size)
        assertEquals(UUID.fromString(id), list.sessions[0].id)
        assertEquals(SessionState.ACTIVE_DETACHED, list.sessions[0].state)
        assertEquals("tok9", list.sessions[0].tokenId)
    }

    @Test fun `encode session_create omits name when null`() {
        assertEquals(
            """{"type":"session_create","payload":{}}""",
            MessageEnvelope.encodeClient(ClientMessage.SessionCreate(null)),
        )
    }

    @Test fun `encode session_create includes name when present`() {
        val encoded = MessageEnvelope.encodeClient(ClientMessage.SessionCreate("my session"))
        assertEquals(
            """{"type":"session_create","payload":{"name":"my session"}}""",
            encoded,
        )
        assertTrue(encoded.contains(""""name":"my session""""))
    }

    @Test fun `session_create encodes cols and rows when present`() {
        val encoded = MessageEnvelope.encodeClient(ClientMessage.SessionCreate("dev", 120u, 40u))
        assertTrue(encoded.contains(""""cols":120"""))
        assertTrue(encoded.contains(""""rows":40"""))
        assertTrue(encoded.contains(""""name":"dev""""))
    }

    @Test fun `session_create omits cols and rows when null`() {
        val encoded = MessageEnvelope.encodeClient(ClientMessage.SessionCreate("dev"))
        assertTrue(!encoded.contains("cols"))
        assertTrue(!encoded.contains("rows"))
    }

    @Test fun `encode session_attach uses lowercase-hyphenated uuid`() {
        val upper = UUID.fromString("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        val encoded = MessageEnvelope.encodeClient(ClientMessage.SessionAttach(upper))
        assertEquals(
            """{"type":"session_attach","payload":{"sessionId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}}""",
            encoded,
        )
    }

    @Test fun `encode resize handles UShort boundary values`() {
        val encoded = MessageEnvelope.encodeClient(ClientMessage.Resize(cols = 65535u, rows = 0u))
        assertTrue(encoded.contains(""""cols":65535"""))
        assertTrue(encoded.contains(""""rows":0"""))
    }

    @Test fun `decode session_created preserves max UShort cols`() {
        val id = "11111111-2222-3333-4444-555555555555"
        val msg = MessageEnvelope.decodeServer(
            """{"type":"session_created","payload":{"sessionId":"$id","cols":65535,"rows":24}}""",
        ) as ServerMessage.SessionCreated
        assertEquals(65535, msg.cols.toInt())
        assertEquals(24, msg.rows.toInt())
    }
}
