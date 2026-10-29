package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import java.util.UUID

class SessionDeepLinkTest {
    private val sid = UUID.fromString("0b7a6a51-2d4f-4b5c-9a6e-1f2e3d4c5b6a")
    private val iid = UUID.fromString("9c8b7a69-5847-4362-a1b0-c9d8e7f6a5b4")

    @Test fun parsesSessionOnly() =
        assertEquals(SessionDeepLink(sid), SessionDeepLink.parse("coderelay://session/$sid"))

    @Test fun parsesServerQuery() =
        assertEquals(SessionDeepLink(sid, iid), SessionDeepLink.parse("coderelay://session/$sid?server=$iid"))

    @Test fun acceptsLegacySchemeAndAnyCase() =
        assertEquals(SessionDeepLink(sid), SessionDeepLink.parse("ClaudeRelay://SESSION/${sid.toString().uppercase()}"))

    @Test fun ignoresAMalformedServerValue() =
        assertEquals(SessionDeepLink(sid), SessionDeepLink.parse("coderelay://session/$sid?server=not-a-uuid"))

    @Test fun rejectsOtherHostsSchemesAndGarbage() {
        assertNull(SessionDeepLink.parse("coderelay://pair?host=h&port=1&tls=0&code=ABCDEFGH"))
        assertNull(SessionDeepLink.parse("https://session/$sid"))
        assertNull(SessionDeepLink.parse("coderelay://session/nope"))
        assertNull(SessionDeepLink.parse(""))
    }

    @Test fun roundTrips() {
        val link = SessionDeepLink(sid, iid)
        assertEquals("coderelay://session/$sid?server=$iid", link.uri)
        assertEquals(link, SessionDeepLink.parse(link.uri))
        assertEquals("coderelay://session/$sid", SessionDeepLink(sid).uri)
    }
}
