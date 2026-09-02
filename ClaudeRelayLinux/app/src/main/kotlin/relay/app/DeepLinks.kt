package relay.app

import relay.protocol.PairingURL
import java.net.URI
import java.util.UUID

/**
 * Parses the `clauderelay://` URLs the app is registered to handle.
 *
 * Two forms exist, both produced by tooling the user already has:
 *
 *  - `clauderelay://session/<uuid>` — from the session QR / share sheet.
 *  - `clauderelay://pair?host=&port=&tls=&code=` — from `claude-relay setup`.
 *
 * Pairing URLs are handed to the shared [PairingURL] parser rather than being
 * re-parsed here: that validation is the one tested place for hostile QR input,
 * and duplicating it is exactly how the three clients would drift.
 *
 * Every failure returns [Unhandled] rather than throwing. A URL arrives from
 * outside the app — an `xdg-open` from any process — so it is untrusted input on
 * a startup path, and a malformed one must not prevent the app from launching.
 */
sealed interface DeepLink {
    /** Attach to an existing session. */
    data class Session(val id: UUID) : DeepLink

    /** Redeem a pairing code against a host. */
    data class Pair(val url: PairingURL) : DeepLink

    /** Not a link we recognise. */
    data object Unhandled : DeepLink
}

object DeepLinks {

    const val SCHEME = "clauderelay"

    /**
     * Resolves [raw] to a [DeepLink].
     *
     * Accepts both `clauderelay://session/<uuid>` and a bare `<uuid>`, because
     * the share sheet shows the full URL but users paste either.
     */
    fun parse(raw: String?): DeepLink {
        val text = raw?.trim().orEmpty()
        if (text.isEmpty()) return DeepLink.Unhandled

        // A bare UUID is the common paste.
        parseUuid(text)?.let { return DeepLink.Session(it) }

        val uri = runCatching { URI(text) }.getOrNull() ?: return DeepLink.Unhandled
        if (!uri.scheme.equals(SCHEME, ignoreCase = true)) return DeepLink.Unhandled

        return when (uri.host?.lowercase()) {
            "session" -> {
                // URI.path is "/<uuid>" for clauderelay://session/<uuid>.
                val id = parseUuid(uri.path?.removePrefix("/").orEmpty())
                if (id != null) DeepLink.Session(id) else DeepLink.Unhandled
            }
            "pair" -> {
                val parsed = runCatching { PairingURL.parse(text) }.getOrNull()
                if (parsed != null) DeepLink.Pair(parsed) else DeepLink.Unhandled
            }
            else -> DeepLink.Unhandled
        }
    }

    /**
     * Picks the first recognised link out of the process argv.
     *
     * The `.desktop` entry passes the URL as `%u`, so it arrives as a plain
     * argument. Other arguments (`--new-session` from the desktop action) are
     * ignored here rather than rejected, so adding one never breaks link
     * handling.
     */
    fun fromArgs(args: Array<String>): DeepLink =
        args.asSequence()
            .map(::parse)
            .firstOrNull { it !is DeepLink.Unhandled }
            ?: DeepLink.Unhandled

    private fun parseUuid(value: String): UUID? {
        if (value.isEmpty()) return null
        return runCatching { UUID.fromString(value) }.getOrNull()
            // Reject a value UUID.fromString accepted but re-renders differently
            // (it is lenient about short groups), so a malformed id can never be
            // sent to the server as if it were real.
            ?.takeIf { it.toString().equals(value, ignoreCase = true) }
    }
}
