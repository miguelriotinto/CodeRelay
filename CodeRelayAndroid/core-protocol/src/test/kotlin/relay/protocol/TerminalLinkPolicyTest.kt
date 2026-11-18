package relay.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Runs the vectors shared with Swift's `TerminalLinkPolicyTests`, so both
 * implementations of the policy provably agree, plus the detector's vectors.
 */
class TerminalLinkPolicyTest {
    private val vectors: JsonObject by lazy {
        val text = checkNotNull(javaClass.classLoader.getResource("terminal-link-vectors.json")).readText()
        Json.parseToJsonElement(text).jsonObject
    }

    private fun JsonObject.str(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull

    @Test fun `policy matches the shared vectors`() {
        val cases = vectors.getValue("policy").jsonArray.map { it.jsonObject }
        assertTrue(cases.size > 20)
        for (c in cases) {
            val name = c.str("name")
            val source = if (c.str("source") == "explicit") TerminalLinkSource.EXPLICIT else TerminalLinkSource.IMPLICIT
            val got = TerminalLinkPolicy.decide(c.str("candidate")!!, source, c.str("visibleText"))
            val expected = when (c.str("decision")) {
                "open" -> TerminalLinkDecision.Open(c.str("url")!!)
                "confirm" -> TerminalLinkDecision.Confirm(c.str("url")!!)
                else -> TerminalLinkDecision.Reject
            }
            assertEquals(expected, got, name)
        }
    }

    @Test fun `over-long link is rejected`() {
        val link = "https://example.com/" + "a".repeat(TerminalLinkPolicy.MAX_LENGTH)
        assertEquals(TerminalLinkDecision.Reject, TerminalLinkPolicy.decide(link, TerminalLinkSource.IMPLICIT))
    }

    @Test fun `detector matches the shared vectors`() {
        val cases = vectors.getValue("detector").jsonArray.map { it.jsonObject }
        for (c in cases) {
            val name = c.str("name")
            val got = TerminalUrlDetector.find(c.str("line")!!, c.getValue("column").jsonPrimitive.int)
            val url = c.str("url")
            if (url == null) {
                assertEquals(null, got, name)
            } else {
                assertEquals(
                    TerminalUrlDetector.Match(url, c.getValue("start").jsonPrimitive.int, c.getValue("end").jsonPrimitive.int),
                    got, name,
                )
            }
        }
    }
}
