package relay.protocol

import java.net.URI
import java.net.URLDecoder

/**
 * Kotlin mirror of Swift PairingURL. Pure JVM — no android.net.Uri.
 *
 * The `clauderelay://pair?host=&port=&tls=&code=` deep link produced by
 * `claude-relay setup` and consumed by the apps.
 *
 * Parsing and validation live here, in the shared protocol module, so the
 * server-side producer and all three clients agree on exactly what a valid
 * pairing link is — and so hostile input is rejected in one tested place.
 */
data class PairingURL(
    val host: String,
    val port: Int,
    val useTLS: Boolean,
    /** Always normalized (uppercase, no hyphen). */
    val code: String,
) {
    /** The WebSocket URL a client should dial to redeem this code. */
    val wsUrl: String get() = "${if (useTLS) "wss" else "ws"}://$host:$port"

    companion object {
        const val SCHEME = "clauderelay"
        const val HOST = "pair"

        /**
         * Parses a pairing URL string, or returns null if it's invalid.
         *
         * Validates:
         * - scheme must be "clauderelay"
         * - host/authority must be "pair"
         * - query must have host (non-empty, trimmed), port (1..65535), code (via PairingCode.normalize)
         * - tls="1" → useTLS=true
         * - rejects RFC-3986-illegal host chars (space / ? # @)
         */
        fun parse(input: String): PairingURL? {
            val uri = try { URI(input) } catch (_: Exception) { return null }

            // Validate scheme
            if (uri.scheme?.lowercase() != SCHEME) return null

            // URI puts "pair" in authority/host for clauderelay://pair?...
            val authority = (uri.host ?: uri.authority)?.lowercase()
            if (authority != HOST) return null

            // Parse query parameters
            val query = uri.rawQuery ?: return null
            val params = parseQueryParams(query) ?: return null

            // Extract and validate host
            val host = params["host"]?.trim()
            if (host.isNullOrEmpty()) return null

            // Validate port
            val port = params["port"]?.toIntOrNull() ?: return null
            if (port < 1 || port > 65535) return null

            // Validate and normalize code
            val code = params["code"]?.let { PairingCode.normalize(it) } ?: return null

            // Parse TLS flag
            val useTLS = params["tls"] == "1"

            // Reject RFC-3986-illegal host characters
            if (host.any { it == ' ' || it == '/' || it == '?' || it == '#' || it == '@' }) {
                return null
            }

            return PairingURL(host, port, useTLS, code)
        }

        private fun parseQueryParams(query: String): Map<String, String>? {
            return try {
                query.split("&").mapNotNull {
                    val i = it.indexOf('=')
                    if (i < 0) null else {
                        val key = URLDecoder.decode(it.substring(0, i), "UTF-8")
                        val value = URLDecoder.decode(it.substring(i + 1), "UTF-8")
                        key to value
                    }
                }.toMap()
            } catch (e: IllegalArgumentException) {
                // URLDecoder.decode throws IllegalArgumentException on malformed
                // percent-encoding. While URI() typically rejects these first,
                // we guard here for defense-in-depth.
                null
            }
        }
    }
}
