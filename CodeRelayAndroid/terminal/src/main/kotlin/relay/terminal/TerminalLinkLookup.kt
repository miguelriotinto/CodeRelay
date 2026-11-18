package relay.terminal

import relay.protocol.TerminalLinkDecision
import relay.protocol.TerminalLinkPolicy
import relay.protocol.TerminalLinkSource
import relay.protocol.TerminalUrlDetector

/**
 * One screen row, as the link lookup needs it — engine-neutral so Android
 * (termlib) and Linux (our libvterm emulator) share one tested implementation.
 *
 * @property text the row's characters, one per column (index == column).
 * @property continuesPrevious true when this row is a soft-wrap continuation of
 *   the row above (the program did not print a newline between them).
 * @property links OSC 8 hyperlinks on this row, as column spans.
 */
data class LinkLine(
    val text: String,
    val continuesPrevious: Boolean = false,
    val links: List<LinkSpan> = emptyList(),
)

/**
 * Whether a row continues the one above it. An engine's own soft-wrap flag is
 * trusted when set, but not when clear: termlib 0.1.0 drops it on every resize
 * (seen on the emulator — a URL still wrapped on screen reported `false` for all
 * its rows once the keyboard had opened), and on a phone the keyboard resizes
 * the grid all the time. So a row filled to its last column, followed by a row
 * that starts with a non-blank, counts as one logical line — the same guess
 * terminals make for copy/paste of wrapped text.
 */
fun continuesPreviousRow(previousText: String?, previousSoftWrapped: Boolean, text: String): Boolean {
    if (previousText == null) return false
    if (previousSoftWrapped) return true
    return previousText.isNotEmpty() && previousText.last() != ' ' && text.firstOrNull()?.let { it != ' ' } == true
}

/** An OSC 8 hyperlink over columns [start, end) of one row. */
data class LinkSpan(val start: Int, val end: Int, val url: String)

/** A link found on screen, with what [TerminalLinkPolicy] needs to judge it. Mirror of Swift `TerminalLinkHit`. */
data class TerminalLinkHit(
    val target: String,
    val source: TerminalLinkSource,
    /** For an explicit link: the text of the cells that carry it. */
    val visibleText: String? = null,
) {
    val decision: TerminalLinkDecision
        get() = TerminalLinkPolicy.decide(target, source, visibleText)
}

/**
 * Finds the link under a screen cell, or judges a target handed over alone.
 * The Kotlin twin of Swift's `TerminalLinkResolver`: OSC 8 first (judged by the
 * text of the cells carrying it), then URL-shaped text across soft-wrapped rows.
 */
object TerminalLinkLookup {
    fun at(lines: List<LinkLine>, col: Int, row: Int): TerminalLinkHit? {
        val line = lines.getOrNull(row) ?: return null
        if (col < 0) return null
        line.links.firstOrNull { col >= it.start && col < it.end }?.let { span ->
            return TerminalLinkHit(span.url, TerminalLinkSource.EXPLICIT, visibleText(lines, row, span))
        }
        // Join the logical line this row belongs to, then detect in it.
        var first = row
        while (first > 0 && lines[first].continuesPrevious) first--
        var last = row
        while (last + 1 < lines.size && lines[last + 1].continuesPrevious) last++
        val joined = StringBuilder()
        var offset = 0
        for (r in first..last) {
            if (r == row) offset = joined.length
            joined.append(lines[r].text)
        }
        val match = TerminalUrlDetector.find(joined.toString(), offset + col) ?: return null
        return TerminalLinkHit(match.url, TerminalLinkSource.IMPLICIT)
    }

    /**
     * For a target the engine already resolved (termlib's `onHyperlinkClick`),
     * without knowing which run was tapped. Fails closed: every run carrying the
     * target is judged, and one whose text hides it makes the answer `Confirm` —
     * otherwise a program could show the target once in plain sight and also hang
     * it on a label, and a tap on the label would open without asking.
     */
    fun forTarget(lines: List<LinkLine>, url: String): TerminalLinkHit {
        var chosen: TerminalLinkHit? = null
        lines.forEachIndexed { row, line ->
            for (span in line.links) {
                if (span.url != url) continue
                // A span continuing the previous row's run is not a run of its own.
                if (span.start == 0 && line.continuesPrevious &&
                    lines[row - 1].links.any { it.url == url && it.end >= lines[row - 1].text.length }) continue
                val run = TerminalLinkHit(url, TerminalLinkSource.EXPLICIT, visibleText(lines, row, span))
                if (run.decision !is TerminalLinkDecision.Open) return run
                if (chosen == null) chosen = run
            }
        }
        return chosen ?: unresolved(lines, url)
    }

    /**
     * A target no OSC 8 span carries. Implicit only if its text is on screen
     * (what you see is the target); otherwise explicit with unknown text, which
     * the policy confirms — never a silent open.
     */
    fun unresolved(lines: List<LinkLine>?, url: String): TerminalLinkHit {
        val screen = lines?.let { rows ->
            buildString { rows.forEachIndexed { i, r -> if (i > 0 && !r.continuesPrevious) append('\n'); append(r.text) } }
        }
        return if (screen != null && screen.contains(url)) {
            TerminalLinkHit(url, TerminalLinkSource.IMPLICIT)
        } else {
            TerminalLinkHit(url, TerminalLinkSource.EXPLICIT, visibleText = null)
        }
    }

    /** The span's text plus any same-target spans it wraps into, above and below. */
    private fun visibleText(lines: List<LinkLine>, row: Int, span: LinkSpan): String {
        fun textOf(r: Int, s: LinkSpan) = lines[r].text.substring(
            s.start.coerceIn(0, lines[r].text.length), s.end.coerceIn(0, lines[r].text.length))

        val parts = ArrayDeque<String>()
        parts.add(textOf(row, span))
        // Backwards: the previous row must end with the same link and this row
        // must continue it from column 0.
        var r = row
        var current = span
        while (current.start == 0 && r > 0 && lines[r].continuesPrevious) {
            val prev = lines[r - 1].links.lastOrNull { it.url == span.url } ?: break
            if (prev.end < lines[r - 1].text.length) break
            parts.addFirst(textOf(r - 1, prev))
            r--
            current = prev
        }
        r = row
        current = span
        while (current.end >= lines[r].text.length && r + 1 < lines.size && lines[r + 1].continuesPrevious) {
            val next = lines[r + 1].links.firstOrNull { it.url == span.url && it.start == 0 } ?: break
            parts.addLast(textOf(r + 1, next))
            r++
            current = next
        }
        return parts.joinToString("").trimEnd()
    }
}
