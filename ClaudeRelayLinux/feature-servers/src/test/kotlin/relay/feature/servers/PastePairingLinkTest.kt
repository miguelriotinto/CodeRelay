package relay.feature.servers

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class PastePairingLinkTest {

    private val url = "coderelay://pair?host=mac.local&port=9200&tls=1&code=K7QP2M4X"

    @Test
    fun `a bare pairing url parses`() {
        val parsed = parsePairingLink(url)!!
        assertEquals("mac.local", parsed.host)
        assertEquals(9200, parsed.port)
        assertEquals(true, parsed.useTLS)
    }

    @Test
    fun `a whole line pasted from the setup output still parses`() {
        val parsed = parsePairingLink("  Or open:  $url  (expires in 5 minutes)")
        assertEquals("mac.local", parsed?.host)
    }

    @Test
    fun `whitespace and case on the scheme are tolerated`() {
        assertEquals("mac.local", parsePairingLink("\n${url.replaceFirst("coderelay", "CODERELAY")}\n")?.host)
    }

    @Test
    fun `a session link is not a pairing link`() {
        assertNull(parsePairingLink("coderelay://session/3f2504e0-4f89-11d3-9a0c-0305e82c3301"))
    }

    @Test
    fun `garbage and blanks are null`() {
        assertNull(parsePairingLink(""))
        assertNull(parsePairingLink("   "))
        assertNull(parsePairingLink("http://example.com"))
    }
}
