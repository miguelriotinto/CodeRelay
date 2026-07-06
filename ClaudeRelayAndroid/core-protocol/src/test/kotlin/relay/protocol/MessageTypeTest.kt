package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class MessageTypeTest {
    @Test fun `client type strings`() {
        assertEquals("auth_request", ClientMessage.AuthRequest("t", 1).typeString)
        assertEquals("session_resume", ClientMessage.SessionResume(java.util.UUID.randomUUID(), true).typeString)
        assertEquals("ping", ClientMessage.Ping.typeString)
    }

    @Test fun `all 13 client type strings present`() {
        assertEquals(13, ClientMessage.ALL_TYPE_STRINGS.size)
        assertTrue("refresh" in ClientMessage.ALL_TYPE_STRINGS)
    }

    @Test fun `all 19 server type strings present`() {
        assertEquals(19, ServerMessage.ALL_TYPE_STRINGS.size) // verified vs ServerMessage.swift:5-23
        assertTrue("session_list_result" in ServerMessage.ALL_TYPE_STRINGS)
    }

    @Test fun `client and server type strings are disjoint`() {
        assertTrue(ClientMessage.ALL_TYPE_STRINGS.intersect(ServerMessage.ALL_TYPE_STRINGS).isEmpty())
    }
}
