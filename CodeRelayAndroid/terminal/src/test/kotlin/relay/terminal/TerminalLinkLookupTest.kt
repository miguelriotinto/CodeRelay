package relay.terminal

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import relay.protocol.TerminalLinkDecision
import relay.protocol.TerminalLinkSource

class TerminalLinkLookupTest {
    private fun row(text: String, cols: Int = 40, continues: Boolean = false, vararg links: LinkSpan) =
        LinkLine(text.padEnd(cols), continues, links.toList())

    @Test fun `plain url is implicit and opens`() {
        val lines = listOf(row("see https://example.com/a for it"))
        val hit = TerminalLinkLookup.at(lines, col = 10, row = 0)!!
        assertEquals(TerminalLinkSource.IMPLICIT, hit.source)
        assertEquals(TerminalLinkDecision.Open("https://example.com/a"), hit.decision)
    }

    @Test fun `text away from the url has no link`() {
        val lines = listOf(row("see https://example.com/a for it"))
        assertNull(TerminalLinkLookup.at(lines, col = 1, row = 0))
        assertNull(TerminalLinkLookup.at(lines, col = 1, row = 5))
    }

    @Test fun `implicit url soft-wrapped onto the next row is found whole from either row`() {
        val url = "https://example.com/" + "a".repeat(30)          // 50 chars on 40 columns
        val lines = listOf(LinkLine(url.substring(0, 40)), LinkLine(url.substring(40).padEnd(40), continuesPrevious = true))
        assertEquals(url, TerminalLinkLookup.at(lines, col = 39, row = 0)!!.target)
        assertEquals(url, TerminalLinkLookup.at(lines, col = 2, row = 1)!!.target)
    }

    @Test fun `a hard newline ends the url`() {
        val lines = listOf(row("https://example.com/abc"), row("def"))
        assertEquals("https://example.com/abc", TerminalLinkLookup.at(lines, col = 3, row = 0)!!.target)
        assertNull(TerminalLinkLookup.at(lines, col = 1, row = 1))
    }

    /** Claude Code's shape: OSC 8 whose text is its target — opens without asking. */
    @Test fun `explicit link showing its own target opens`() {
        val url = "https://code.claude.com/docs/en/overview"
        val text = "For more help: $url"
        val lines = listOf(row(text, cols = 60, links = arrayOf(LinkSpan(15, 15 + url.length, url))))
        val hit = TerminalLinkLookup.at(lines, col = 20, row = 0)!!
        assertEquals(url, hit.visibleText)
        assertEquals(TerminalLinkDecision.Open(url), hit.decision)
    }

    @Test fun `explicit link with a label confirms`() {
        val lines = listOf(row("read the docs now", links = arrayOf(LinkSpan(5, 13, "https://evil.example/x"))))
        val hit = TerminalLinkLookup.at(lines, col = 7, row = 0)!!
        assertEquals("the docs", hit.visibleText)
        assertEquals(TerminalLinkDecision.Confirm("https://evil.example/x"), hit.decision)
    }

    @Test fun `explicit link wrapped across rows reads whole`() {
        val url = "https://example.com/" + "a".repeat(30)
        val lines = listOf(
            LinkLine(url.substring(0, 40), links = listOf(LinkSpan(0, 40, url))),
            LinkLine(url.substring(40).padEnd(40), continuesPrevious = true, links = listOf(LinkSpan(0, 10, url))),
        )
        val hit = TerminalLinkLookup.at(lines, col = 2, row = 1)!!
        assertEquals(url, hit.visibleText)
        assertEquals(TerminalLinkDecision.Open(url), hit.decision)
    }

    @Test fun `own deep link is rejected`() {
        val link = "coderelay://pair?host=1.2.3.4&port=9200&tls=0&code=ABCDEFGH"
        val lines = listOf(row("click me", links = arrayOf(LinkSpan(0, 8, link))))
        assertEquals(TerminalLinkDecision.Reject, TerminalLinkLookup.at(lines, col = 2, row = 0)!!.decision)
    }

    @Test fun `target handed over alone is judged by the cells that carry it`() {
        val url = "https://code.claude.com/docs"
        val lines = listOf(row("x $url y label", cols = 60,
            links = arrayOf(LinkSpan(2, 2 + url.length, url), LinkSpan(33, 38, "https://evil.example"))))
        assertEquals(TerminalLinkDecision.Open(url), TerminalLinkLookup.forTarget(lines, url).decision)
        assertEquals(TerminalLinkDecision.Confirm("https://evil.example"),
            TerminalLinkLookup.forTarget(lines, "https://evil.example").decision)
        assertEquals(TerminalLinkSource.IMPLICIT, TerminalLinkLookup.forTarget(lines, "https://plain.example").source)
    }

    @Test fun `target handed over alone fails closed when any run hides it`() {
        val url = "https://evil.example/x"
        val lines = listOf(row("$url your bank", cols = 60,
            links = arrayOf(LinkSpan(0, url.length, url), LinkSpan(url.length + 1, url.length + 10, url))))
        assertEquals(TerminalLinkDecision.Confirm(url), TerminalLinkLookup.forTarget(lines, url).decision)
    }

    @Test fun `a row continues the one above when flagged, or when the one above is full`() {
        assertEquals(true, continuesPreviousRow("abc ", previousSoftWrapped = true, text = "x"))
        assertEquals(true, continuesPreviousRow("https://example.com/aaaa", previousSoftWrapped = false, text = "aaaa  "))
        assertEquals(false, continuesPreviousRow("short line      ", previousSoftWrapped = false, text = "next"))
        assertEquals(false, continuesPreviousRow("full-to-the-edge", previousSoftWrapped = false, text = " indented"))
        assertEquals(false, continuesPreviousRow(null, previousSoftWrapped = false, text = "first"))
    }
}
