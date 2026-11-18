package relay.protocol

import java.net.URI
import java.net.URISyntaxException

/** Where a terminal link came from. Mirror of Swift `TerminalLinkSource`. */
enum class TerminalLinkSource {
    /** An OSC 8 hyperlink: the program chose the target; the text can be anything. */
    EXPLICIT,

    /** URL-shaped text detected on screen: what you see is the target. */
    IMPLICIT,
}

/** What a client does with a link the user activated. Mirror of Swift `TerminalLinkDecision`. */
sealed interface TerminalLinkDecision {
    /** Open it in the device's browser (or mail app) straight away. */
    data class Open(val url: String) : TerminalLinkDecision

    /** Show the full target first (Open / Copy / Cancel). */
    data class Confirm(val url: String) : TerminalLinkDecision

    /** Never open it. */
    data object Reject : TerminalLinkDecision
}

/**
 * Kotlin mirror of Swift `TerminalLinkPolicy` — the one rule every client
 * applies before opening a link from terminal output. Terminal output is written
 * by whatever runs on the host, so only web and mail links open, and our own
 * `coderelay:` deep links can never be fired by text a program printed.
 *
 * Both implementations run the same vectors
 * (`core-protocol/src/test/resources/terminal-link-vectors.json`).
 */
object TerminalLinkPolicy {
    val allowedSchemes: Set<String> = setOf("http", "https", "mailto")
    const val MAX_LENGTH = 2048

    /**
     * RFC 3986 unreserved + reserved characters and `%`, checked here rather than
     * left to the parser so this policy and Swift's agree on every input (Foundation
     * percent-encodes `|`/`{` that `java.net.URI` rejects).
     */
    private const val URI_CHARACTERS =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"

    fun decide(
        candidate: String,
        source: TerminalLinkSource,
        visibleText: String? = null,
    ): TerminalLinkDecision {
        val link = if (source == TerminalLinkSource.IMPLICIT) trimImplicit(candidate) else candidate
        if (link.isEmpty() || link.toByteArray(Charsets.UTF_8).size > MAX_LENGTH) return TerminalLinkDecision.Reject
        if (!link.all { it in URI_CHARACTERS }) return TerminalLinkDecision.Reject
        val colon = link.indexOf(':')
        if (colon < 0) return TerminalLinkDecision.Reject

        val scheme = link.substring(0, colon)
        if (!isValidScheme(scheme) || scheme.lowercase() !in allowedSchemes) return TerminalLinkDecision.Reject

        val rest = link.substring(colon + 1)
        var hasUserInfo = false
        if (scheme.lowercase() == "mailto") {
            if (!rest.contains('@') || rest.startsWith('@')) return TerminalLinkDecision.Reject
        } else {
            if (!rest.startsWith("//")) return TerminalLinkDecision.Reject
            val authority = rest.substring(2).takeWhile { it !in "/?#" }
            hasUserInfo = authority.contains('@')
            val hostAndPort = authority.substringAfterLast('@')
            val host = if (hostAndPort.startsWith("[")) {
                hostAndPort.drop(1).takeWhile { it != ']' }
            } else {
                hostAndPort.takeWhile { it != ':' }
            }
            if (host.isEmpty()) return TerminalLinkDecision.Reject
        }

        try {
            URI(link)
        } catch (_: URISyntaxException) {
            return TerminalLinkDecision.Reject
        }
        if (hasUserInfo) return TerminalLinkDecision.Confirm(link)
        if (source == TerminalLinkSource.EXPLICIT && !visibleTextMatches(visibleText, link)) {
            return TerminalLinkDecision.Confirm(link)
        }
        return TerminalLinkDecision.Open(link)
    }

    /**
     * Drops sentence punctuation after a URL and closing brackets with no opener
     * inside it — `(see https://x.dev/a)` must not open `https://x.dev/a)`.
     */
    fun trimImplicit(text: String): String {
        var s = text
        val pairs = mapOf(')' to '(', ']' to '[', '}' to '{')
        while (s.isNotEmpty()) {
            val last = s.last()
            val opener = pairs[last]
            s = when {
                last in ".,;:!?'\"" -> s.dropLast(1)
                opener != null && s.count { it == last } > s.count { it == opener } -> s.dropLast(1)
                else -> break
            }
        }
        return s
    }

    private fun isValidScheme(scheme: String): Boolean {
        val first = scheme.firstOrNull() ?: return false
        if (!(first in 'a'..'z' || first in 'A'..'Z')) return false
        return scheme.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it in "+.-" }
    }

    /** The text on screen "is" the link when it shows the whole target, with or without its scheme. */
    private fun visibleTextMatches(visible: String?, link: String): Boolean {
        val shown = visible?.trim(' ', '\t') ?: return false
        if (shown.isEmpty()) return false
        if (shown == link) return true
        return listOf("https://", "http://", "mailto:").any { prefix ->
            link.lowercase().startsWith(prefix) && shown == link.substring(prefix.length)
        }
    }
}
