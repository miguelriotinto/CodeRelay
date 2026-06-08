package relay.feature.workspace

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import java.util.UUID

/**
 * Verifies [DeepLinks] parses/builds the `clauderelay://session/<uuid>` shape
 * that matches iOS (`QRCodeSheet.swift` builds it, `ClaudeRelayApp.swift` parses
 * it). Pure JVM — no Android dependency.
 */
class DeepLinksTest {

    @Test
    fun `parses a valid lowercase session link`() {
        val expected = UUID.fromString("550e8400-e29b-41d4-a716-446655440000")
        assertEquals(
            expected,
            DeepLinks.parseSessionId("clauderelay://session/550e8400-e29b-41d4-a716-446655440000"),
        )
    }

    @Test
    fun `parses an uppercase uuid case-insensitively (iOS emits uppercase)`() {
        val expected = UUID.fromString("550e8400-e29b-41d4-a716-446655440000")
        assertEquals(
            expected,
            DeepLinks.parseSessionId("clauderelay://session/550E8400-E29B-41D4-A716-446655440000"),
        )
    }

    @Test
    fun `wrong host returns null`() {
        val uuid = "550e8400-e29b-41d4-a716-446655440000"
        assertNull(DeepLinks.parseSessionId("clauderelay://nonsense/$uuid"))
        assertNull(DeepLinks.parseSessionId("clauderelay://nonsense"))
    }

    @Test
    fun `wrong scheme returns null`() {
        val uuid = "550e8400-e29b-41d4-a716-446655440000"
        assertNull(DeepLinks.parseSessionId("https://session/$uuid"))
    }

    @Test
    fun `missing uuid returns null`() {
        assertNull(DeepLinks.parseSessionId("clauderelay://session/"))
        assertNull(DeepLinks.parseSessionId("clauderelay://session"))
    }

    @Test
    fun `garbage uuid returns null`() {
        assertNull(DeepLinks.parseSessionId("clauderelay://session/not-a-uuid"))
        assertNull(DeepLinks.parseSessionId("clauderelay://session/1234"))
    }

    @Test
    fun `extra path segment returns null`() {
        val uuid = "550e8400-e29b-41d4-a716-446655440000"
        assertNull(DeepLinks.parseSessionId("clauderelay://session/$uuid/extra"))
        assertNull(DeepLinks.parseSessionId("clauderelay://session/$uuid/"))
    }

    @Test
    fun `empty and junk input returns null`() {
        assertNull(DeepLinks.parseSessionId(""))
        assertNull(DeepLinks.parseSessionId("clauderelay://nonsense"))
        assertNull(DeepLinks.parseSessionId("just some text"))
    }

    @Test
    fun `sessionUri emits canonical lowercase form`() {
        val uuid = UUID.fromString("550E8400-E29B-41D4-A716-446655440000")
        assertEquals(
            "clauderelay://session/550e8400-e29b-41d4-a716-446655440000",
            DeepLinks.sessionUri(uuid),
        )
    }

    @Test
    fun `sessionUri round-trips through parseSessionId`() {
        val uuid = UUID.randomUUID()
        assertEquals(uuid, DeepLinks.parseSessionId(DeepLinks.sessionUri(uuid)))
    }
}
