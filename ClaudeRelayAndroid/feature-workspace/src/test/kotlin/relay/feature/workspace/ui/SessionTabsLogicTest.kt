package relay.feature.workspace.ui

import androidx.compose.ui.graphics.Color
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * Verifies the tab background decision matches `ActiveTerminalView.swift:318-324`:
 *  - needsAttention → flashOn ? agentColor : white15
 *  - else agentId != null → agentColor
 *  - else → white15
 */
class SessionTabsLogicTest {

    private val white15 = Color.White.copy(alpha = 0.15f)

    @Test
    fun `no agent and no attention is dim white`() {
        assertEquals(white15, tabBackground(agentId = null, needsAttention = false, flashOn = false))
        assertEquals(white15, tabBackground(agentId = null, needsAttention = false, flashOn = true))
    }

    @Test
    fun `agent without attention is the agent color`() {
        assertEquals(agentColor("claude"), tabBackground("claude", needsAttention = false, flashOn = false))
        assertEquals(agentColor("codex"), tabBackground("codex", needsAttention = false, flashOn = true))
    }

    @Test
    fun `attention flashes between agent color and dim white`() {
        assertEquals(agentColor("claude"), tabBackground("claude", needsAttention = true, flashOn = true))
        assertEquals(white15, tabBackground("claude", needsAttention = true, flashOn = false))
    }
}
