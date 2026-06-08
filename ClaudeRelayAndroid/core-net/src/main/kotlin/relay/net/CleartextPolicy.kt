package relay.net

/**
 * Decides whether plaintext `ws://` is permitted to a given host, mirroring the
 * iOS/macOS apps' `NSAllowsLocalNetworking` ATS scope.
 *
 * Apple's `NSAllowsLocalNetworking` permits cleartext only to RFC1918 private
 * ranges, loopback, link-local, and `.local` mDNS names. Everything else —
 * including Tailscale's CGNAT range (`100.64.0.0/10`), IPv6 ULA (`fc00::/7`),
 * and any public host — requires `wss://`. Apple enforces this at the platform
 * layer; Android has no equivalent, so we replicate the same scope in code and
 * the app rejects `ws://` to non-private hosts before connecting.
 *
 * Note: CGNAT and ULA are deliberately treated as NON-private here, matching the
 * README ("Tailscale CGNAT, IPv6 ULA, and public hostnames require TLS").
 */
object CleartextPolicy {

    /** True iff cleartext `ws://` is allowed to [host]. */
    fun isPrivateNetworkHost(host: String): Boolean {
        val h = host.trim().removeBracketsIfIPv6().lowercase()
        if (h.isEmpty()) return false

        // mDNS / Bonjour names.
        if (h == "local" || h.endsWith(".local")) return true

        parseIPv4(h)?.let { return it.isPrivateIPv4() }
        if (h.contains(':')) return isPrivateIPv6(h)

        // Any other hostname is treated as potentially public → require TLS.
        return false
    }

    private fun String.removeBracketsIfIPv6(): String =
        if (startsWith("[") && endsWith("]")) substring(1, length - 1) else this

    /** Parses a dotted-quad IPv4 string into four octets, or null if not IPv4. */
    private fun parseIPv4(s: String): IntArray? {
        val parts = s.split('.')
        if (parts.size != 4) return null
        val octets = IntArray(4)
        for (i in 0 until 4) {
            val p = parts[i]
            if (p.isEmpty() || p.length > 3 || p.any { !it.isDigit() }) return null
            val v = p.toInt()
            if (v !in 0..255) return null
            octets[i] = v
        }
        return octets
    }

    private fun IntArray.isPrivateIPv4(): Boolean {
        val (a, b) = this[0] to this[1]
        return when {
            a == 127 -> true // loopback 127.0.0.0/8
            a == 10 -> true // 10.0.0.0/8
            a == 172 && b in 16..31 -> true // 172.16.0.0/12
            a == 192 && b == 168 -> true // 192.168.0.0/16
            a == 169 && b == 254 -> true // link-local 169.254.0.0/16
            else -> false // includes CGNAT 100.64.0.0/10 and all public ranges
        }
    }

    private fun isPrivateIPv6(s: String): Boolean {
        if (s == "::1") return true // loopback
        // Link-local fe80::/10 — first 16-bit group in fe80..febf.
        val firstGroup = s.substringBefore("::").substringBefore(':')
        val groupValue = firstGroup.toIntOrNull(16) ?: return false
        return groupValue in 0xfe80..0xfebf // excludes ULA fc00::/7 and global unicast
    }
}
