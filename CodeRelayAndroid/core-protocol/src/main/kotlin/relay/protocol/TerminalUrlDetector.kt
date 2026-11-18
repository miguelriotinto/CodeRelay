package relay.protocol

/**
 * Finds URL-shaped text in one logical terminal line (soft-wrapped rows joined
 * by the caller). The Kotlin clients' equivalent of SwiftTerm's implicit link
 * matcher: Linux has no other detector, and Android needs one on the
 * mouse-tracking path, where termlib never sees the tap.
 *
 * Detection is deliberately loose; [TerminalLinkPolicy] decides what may open.
 */
object TerminalUrlDetector {
    /** [start] inclusive, [end] exclusive, as indices into the line. */
    data class Match(val url: String, val start: Int, val end: Int)

    private val pattern = Regex("""(?i)(?:https?://|mailto:)[^\s<>"'`]+""")

    /** Every URL in [line], trailing punctuation already trimmed. */
    fun findAll(line: String): List<Match> =
        pattern.findAll(line).mapNotNull { m ->
            val url = TerminalLinkPolicy.trimImplicit(m.value)
            if (url.isEmpty()) null else Match(url, m.range.first, m.range.first + url.length)
        }.toList()

    /** The URL covering [column], or null. */
    fun find(line: String, column: Int): Match? =
        findAll(line).firstOrNull { column >= it.start && column < it.end }
}
