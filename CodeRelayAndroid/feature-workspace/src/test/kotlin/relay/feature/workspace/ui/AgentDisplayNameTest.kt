package relay.feature.workspace.ui

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class AgentDisplayNameTest {
    @Test fun nullForNoAgent() { assertNull(friendlyAgentName(null)) }
    @Test fun claude() { assertEquals("Claude Code", friendlyAgentName("claude")) }
    @Test fun codex() { assertEquals("Codex", friendlyAgentName("codex")) }
    @Test fun opencodeTwoWords() { assertEquals("Open Code", friendlyAgentName("opencode")) }
    @Test fun unknownFallsBack() { assertEquals("mystery", friendlyAgentName("mystery")) }
}
