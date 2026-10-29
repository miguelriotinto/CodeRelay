package relay.protocol

import java.net.URI
import java.util.UUID

/**
 * `coderelay://session/<uuid>[?server=<instanceId>]` (multi-server spec §10).
 * The legacy `clauderelay` scheme is still accepted, and a malformed `server`
 * value is ignored rather than rejecting the link. Mirrors
 * `Sources/CodeRelayKit/Protocol/SessionDeepLink.swift`.
 */
data class SessionDeepLink(val sessionId: UUID, val serverInstanceId: UUID? = null) {

    val uri: String
        get() = buildString {
            append(SCHEME).append("://").append(HOST).append('/').append(sessionId)
            serverInstanceId?.let { append('?').append(SERVER_QUERY).append('=').append(it) }
        }

    companion object {
        const val SCHEME = "coderelay"
        const val LEGACY_SCHEME = "clauderelay"
        const val HOST = "session"
        const val SERVER_QUERY = "server"

        fun parse(raw: String): SessionDeepLink? {
            val uri = runCatching { URI(raw.trim()) }.getOrNull() ?: return null
            val scheme = uri.scheme?.lowercase() ?: return null
            if (scheme != SCHEME && scheme != LEGACY_SCHEME) return null
            if (uri.host?.lowercase() != HOST) return null
            val first = uri.path.orEmpty().trim('/').substringBefore('/')
            val sessionId = runCatching { UUID.fromString(first) }.getOrNull() ?: return null
            val server = uri.rawQuery.orEmpty().split('&')
                .map { it.split('=', limit = 2) }
                .firstOrNull { it.size == 2 && it[0].equals(SERVER_QUERY, ignoreCase = true) }
                ?.let { runCatching { UUID.fromString(it[1]) }.getOrNull() }
            return SessionDeepLink(sessionId, server)
        }
    }
}
