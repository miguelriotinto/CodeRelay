package relay.net

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class CleartextPolicyTest {

    @Test
    fun `private hosts permit cleartext`() {
        // RFC1918
        assertTrue(CleartextPolicy.isPrivateNetworkHost("192.168.1.5"))
        assertTrue(CleartextPolicy.isPrivateNetworkHost("10.0.0.1"))
        assertTrue(CleartextPolicy.isPrivateNetworkHost("172.16.0.1"))
        // loopback
        assertTrue(CleartextPolicy.isPrivateNetworkHost("127.0.0.1"))
        // .local mDNS
        assertTrue(CleartextPolicy.isPrivateNetworkHost("mymac.local"))
        // IPv6 link-local
        assertTrue(CleartextPolicy.isPrivateNetworkHost("fe80::1"))
        assertTrue(CleartextPolicy.isPrivateNetworkHost("[fe80::1]"))
    }

    @Test
    fun `public and CGNAT hosts require TLS`() {
        // public v4
        assertFalse(CleartextPolicy.isPrivateNetworkHost("8.8.8.8"))
        assertFalse(CleartextPolicy.isPrivateNetworkHost("[8.8.8.8]"))
        // public hostname
        assertFalse(CleartextPolicy.isPrivateNetworkHost("relay.example.com"))
        // Tailscale CGNAT 100.64/10
        assertFalse(CleartextPolicy.isPrivateNetworkHost("100.64.0.1"))
        // IPv6 ULA fc00::/7
        assertFalse(CleartextPolicy.isPrivateNetworkHost("fc00::1"))
        assertFalse(CleartextPolicy.isPrivateNetworkHost("[fc00::1]"))
    }

    @Test
    fun `172 16-31 is private but 172 15 and 172 32 are not`() {
        assertTrue(CleartextPolicy.isPrivateNetworkHost("172.31.255.255"))
        assertFalse(CleartextPolicy.isPrivateNetworkHost("172.15.0.1"))
        assertFalse(CleartextPolicy.isPrivateNetworkHost("172.32.0.1"))
    }
}
