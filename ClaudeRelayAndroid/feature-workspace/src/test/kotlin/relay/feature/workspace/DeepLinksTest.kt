package relay.feature.workspace

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import java.util.UUID

/**
 * Verifies [DeepLinks] parses/builds the `coderelay://session/<uuid>` shape
 * that matches iOS (`QRCodeSheet.swift` builds it, `ClaudeRelayApp.swift` parses
 * it). Pure JVM — no Android dependency.
 */
class DeepLinksTest {

    @Test
    fun `parses a valid lowercase session link`() {
        val expected = UUID.fromString("550e8400-e29b-41d4-a716-446655440000")
        assertEquals(
            expected,
            DeepLinks.parseSessionId("coderelay://session/550e8400-e29b-41d4-a716-446655440000"),
        )
    }

    @Test
    fun `parses an uppercase uuid case-insensitively (iOS emits uppercase)`() {
        val expected = UUID.fromString("550e8400-e29b-41d4-a716-446655440000")
        assertEquals(
            expected,
            DeepLinks.parseSessionId("coderelay://session/550E8400-E29B-41D4-A716-446655440000"),
        )
    }

    @Test
    fun `wrong host returns null`() {
        val uuid = "550e8400-e29b-41d4-a716-446655440000"
        assertNull(DeepLinks.parseSessionId("coderelay://nonsense/$uuid"))
        assertNull(DeepLinks.parseSessionId("coderelay://nonsense"))
    }

    @Test
    fun `wrong scheme returns null`() {
        val uuid = "550e8400-e29b-41d4-a716-446655440000"
        assertNull(DeepLinks.parseSessionId("https://session/$uuid"))
    }

    @Test
    fun `missing uuid returns null`() {
        assertNull(DeepLinks.parseSessionId("coderelay://session/"))
        assertNull(DeepLinks.parseSessionId("coderelay://session"))
    }

    @Test
    fun `garbage uuid returns null`() {
        assertNull(DeepLinks.parseSessionId("coderelay://session/not-a-uuid"))
        assertNull(DeepLinks.parseSessionId("coderelay://session/1234"))
    }

    @Test
    fun `extra path segment returns null`() {
        val uuid = "550e8400-e29b-41d4-a716-446655440000"
        assertNull(DeepLinks.parseSessionId("coderelay://session/$uuid/extra"))
        assertNull(DeepLinks.parseSessionId("coderelay://session/$uuid/"))
    }

    @Test
    fun `empty and junk input returns null`() {
        assertNull(DeepLinks.parseSessionId(""))
        assertNull(DeepLinks.parseSessionId("coderelay://nonsense"))
        assertNull(DeepLinks.parseSessionId("just some text"))
    }

    @Test
    fun `sessionUri emits canonical lowercase form`() {
        val uuid = UUID.fromString("550E8400-E29B-41D4-A716-446655440000")
        assertEquals(
            "coderelay://session/550e8400-e29b-41d4-a716-446655440000",
            DeepLinks.sessionUri(uuid),
        )
    }

    @Test
    fun `sessionUri round-trips through parseSessionId`() {
        val uuid = UUID.randomUUID()
        assertEquals(uuid, DeepLinks.parseSessionId(DeepLinks.sessionUri(uuid)))
    }

    @Test
    fun `parsePairingUrl parses a valid pair link`() {
        val u = DeepLinks.parsePairingUrl("coderelay://pair?host=h.local&port=9200&tls=0&code=K7QP2M4X")
        assertEquals("h.local", u?.host)
        assertEquals(9200, u?.port)
        assertEquals(false, u?.useTLS)
        assertEquals("K7QP2M4X", u?.code)
    }

    @Test
    fun `parsePairingUrl parses a TLS pair link`() {
        val u = DeepLinks.parsePairingUrl("coderelay://pair?host=example.com&port=443&tls=1&code=ABC123XY")
        assertEquals("example.com", u?.host)
        assertEquals(443, u?.port)
        assertEquals(true, u?.useTLS)
        assertEquals("ABC123XY", u?.code)
    }

    @Test
    fun `parsePairingUrl rejects a session link`() {
        assertNull(DeepLinks.parsePairingUrl("coderelay://session/${UUID.randomUUID()}"))
    }

    @Test
    fun `parsePairingUrl rejects garbage`() {
        assertNull(DeepLinks.parsePairingUrl(""))
        assertNull(DeepLinks.parsePairingUrl("just text"))
        assertNull(DeepLinks.parsePairingUrl("https://pair?host=h&port=9200&tls=0&code=X"))
    }

    @Test
    fun `parseSessionId still rejects a pair link`() {
        assertNull(DeepLinks.parseSessionId("coderelay://pair?host=h.local&port=9200&tls=0&code=K7QP2M4X"))
    }
}
