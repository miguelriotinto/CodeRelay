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

    @Test fun `all 18 client type strings present`() {
        assertEquals(18, ClientMessage.ALL_TYPE_STRINGS.size)
        assertTrue("refresh" in ClientMessage.ALL_TYPE_STRINGS)
        assertTrue("register_push_token" in ClientMessage.ALL_TYPE_STRINGS)
        assertTrue("unregister_push_token" in ClientMessage.ALL_TYPE_STRINGS)
        assertTrue("pair_request" in ClientMessage.ALL_TYPE_STRINGS)
        assertTrue("optimize_prompt" in ClientMessage.ALL_TYPE_STRINGS)
        assertTrue("replace_prompt" in ClientMessage.ALL_TYPE_STRINGS)
    }

    @Test fun `all 22 server type strings present`() {
        assertEquals(22, ServerMessage.ALL_TYPE_STRINGS.size)
        assertTrue("session_list_result" in ServerMessage.ALL_TYPE_STRINGS)
        assertTrue("pair_success" in ServerMessage.ALL_TYPE_STRINGS)
        assertTrue("optimize_prompt_result" in ServerMessage.ALL_TYPE_STRINGS)
        assertTrue("replace_prompt_result" in ServerMessage.ALL_TYPE_STRINGS)
    }

    @Test fun `client and server type strings are disjoint`() {
        assertTrue(ClientMessage.ALL_TYPE_STRINGS.intersect(ServerMessage.ALL_TYPE_STRINGS).isEmpty())
    }
}
