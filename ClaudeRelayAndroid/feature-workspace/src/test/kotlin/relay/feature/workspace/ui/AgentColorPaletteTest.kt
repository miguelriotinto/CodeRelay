package relay.feature.workspace.ui

import androidx.compose.ui.graphics.Color
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Test

/**
 * Verifies the agent → color mapping matches `AgentColorPalette.swift` value for
 * value, including the load-bearing fact that the default (unknown/null agent)
 * resolves to the SAME teal as `"codex"` (AgentColorPalette.swift:12-14).
 */
class AgentColorPaletteTest {

    private val claudeOrange = Color(0xFFFFA500)
    private val codexTeal = Color(red = 84 / 255f, green = 132 / 255f, blue = 137 / 255f)

    @Test
    fun `claude maps to orange`() {
        assertEquals(claudeOrange, agentColor("claude"))
    }

    @Test
    fun `codex maps to teal`() {
        assertEquals(codexTeal, agentColor("codex"))
    }

    @Test
    fun `null maps to the codex teal (default == codex)`() {
        assertEquals(codexTeal, agentColor(null))
        assertEquals(agentColor("codex"), agentColor(null))
    }

    @Test
    fun `unknown agent maps to the codex teal`() {
        assertEquals(codexTeal, agentColor("gemini"))
        assertEquals(agentColor("codex"), agentColor("gemini"))
    }

    @Test
    fun `claude and codex are distinct`() {
        assertNotEquals(agentColor("claude"), agentColor("codex"))
    }
}
