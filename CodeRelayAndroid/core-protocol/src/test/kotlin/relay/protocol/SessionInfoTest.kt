package relay.protocol

import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import java.util.UUID

class SessionInfoTest {
    private val json: Json = WireJson.instance

    @Test fun `decodes a full payload`() {
        val id = UUID.fromString("11111111-2222-3333-4444-555555555555")
        val payload = """
            {
              "id":"11111111-2222-3333-4444-555555555555",
              "name":"my session",
              "state":"active-detached",
              "tokenId":"abc12345",
              "createdAt":740000000.5,
              "cols":120,
              "rows":30,
              "activity":"agent_idle",
              "agent":"claude"
            }
        """.trimIndent()

        val info = json.decodeFromString(SessionInfo.serializer(), payload)

        assertEquals(id, info.id)
        assertEquals("my session", info.name)
        assertEquals(SessionState.ACTIVE_DETACHED, info.state)
        assertEquals("abc12345", info.tokenId)
        assertEquals(740000000.5, info.createdAt)
        assertEquals(120.toUShort(), info.cols)
        assertEquals(30.toUShort(), info.rows)
        assertEquals(ActivityState.AGENT_IDLE, info.activity)
        assertEquals("claude", info.agent)
    }

    @Test fun `decodes payload with optionals absent`() {
        val payload = """
            {
              "id":"11111111-2222-3333-4444-555555555555",
              "state":"created",
              "tokenId":"abc12345",
              "createdAt":740000000.5,
              "cols":80,
              "rows":24
            }
        """.trimIndent()

        val info = json.decodeFromString(SessionInfo.serializer(), payload)

        assertNull(info.name)
        assertNull(info.activity)
        assertNull(info.agent)
        assertEquals(SessionState.CREATED, info.state)
        assertEquals(80.toUShort(), info.cols)
        assertEquals(24.toUShort(), info.rows)
    }
}
