package relay.protocol

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue

class PairingUrlTest {
    @Test fun `parses a valid pair url`() {
        val u = PairingURL.parse("clauderelay://pair?host=silverwing.local&port=9200&tls=0&code=K7QP2M4X")!!
        assertEquals("silverwing.local", u.host)
        assertEquals(9200, u.port)
        assertFalse(u.useTLS)
        assertEquals("K7QP2M4X", u.code)
        assertEquals("ws://silverwing.local:9200", u.wsUrl)
    }

    @Test fun `tls=1 yields wss`() {
        val u = PairingURL.parse("clauderelay://pair?host=h.example.com&port=443&tls=1&code=K7QP2M4X")!!
        assertTrue(u.useTLS)
        assertEquals("wss://h.example.com:443", u.wsUrl)
    }

    @Test fun `normalizes a hyphenated lowercase code`() {
        assertEquals("K7QP2M4X", PairingURL.parse("clauderelay://pair?host=h.local&port=9200&tls=0&code=k7qp-2m4x")!!.code)
    }

    @Test fun `wrong scheme is null`() {
        assertNull(PairingURL.parse("https://pair?host=h&port=9200&tls=0&code=K7QP2M4X"))
    }

    @Test fun `wrong host is null`() {
        assertNull(PairingURL.parse("clauderelay://session/123?code=K7QP2M4X"))
    }

    @Test fun `missing code is null`() {
        assertNull(PairingURL.parse("clauderelay://pair?host=h.local&port=9200&tls=0"))
    }

    @Test fun `bad port is null`() {
        assertNull(PairingURL.parse("clauderelay://pair?host=h.local&port=0&tls=0&code=K7QP2M4X"))
        assertNull(PairingURL.parse("clauderelay://pair?host=h.local&port=99999&tls=0&code=K7QP2M4X"))
    }

    @Test fun `bad code charset is null`() {
        assertNull(PairingURL.parse("clauderelay://pair?host=h.local&port=9200&tls=0&code=K7QP2M4!"))
    }

    @Test fun `empty host is null`() {
        assertNull(PairingURL.parse("clauderelay://pair?host=&port=9200&tls=0&code=K7QP2M4X"))
    }
}
