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

    @Test
    fun `F5 agents map to distinct non-default colors`() {
        val copilot = Color(red = 110 / 255f, green = 84 / 255f, blue = 148 / 255f)
        val cursor = Color(red = 45 / 255f, green = 125 / 255f, blue = 210 / 255f)
        val droid = Color(red = 210 / 255f, green = 120 / 255f, blue = 60 / 255f)
        assertEquals(copilot, agentColor("copilot"))
        assertEquals(cursor, agentColor("cursor-agent"))
        assertEquals(droid, agentColor("droid"))
        // Each is distinct from the codex-teal default.
        assertNotEquals(agentColor("codex"), agentColor("copilot"))
        assertNotEquals(agentColor("codex"), agentColor("cursor-agent"))
        assertNotEquals(agentColor("codex"), agentColor("droid"))
    }
}
