package relay.feature.workspace.ui

import androidx.compose.ui.graphics.Color
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import relay.protocol.AgentDetectedState

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

    // --- agentState (fine-grained) drives the fill when present ---

    @Test
    fun `blocked agentState flashes between red and dim white`() {
        assertEquals(
            QualityRed,
            tabBackground("claude", needsAttention = true, flashOn = true, agentState = AgentDetectedState.BLOCKED),
        )
        assertEquals(
            white15,
            tabBackground("claude", needsAttention = true, flashOn = false, agentState = AgentDetectedState.BLOCKED),
        )
    }

    @Test
    fun `working agentState is the agent color`() {
        assertEquals(
            agentColor("claude"),
            tabBackground("claude", needsAttention = false, flashOn = false, agentState = AgentDetectedState.WORKING),
        )
    }

    @Test
    fun `idle agentState is done teal`() {
        assertEquals(
            IdleYellow,
            tabBackground("claude", needsAttention = false, flashOn = true, agentState = AgentDetectedState.IDLE),
        )
    }

    @Test
    fun `unknown agentState is gray`() {
        assertEquals(
            UnknownGray,
            tabBackground("claude", needsAttention = false, flashOn = false, agentState = AgentDetectedState.UNKNOWN),
        )
    }

    @Test
    fun `null agentState falls back to legacy fill`() {
        // Same as the legacy cases above — agentState=null takes the old branch.
        assertEquals(agentColor("codex"), tabBackground("codex", needsAttention = false, flashOn = false, agentState = null))
        assertEquals(white15, tabBackground(null, needsAttention = false, flashOn = true, agentState = null))
    }

    // --- revealTarget: minimal-reveal scroll decision ---

    // Viewport 300px wide, three 100px tabs visible at offsets 0,100,200.
    private fun threeVisible() = listOf(
        VisibleTab(index = 0, offset = 0, size = 100),
        VisibleTab(index = 1, offset = 100, size = 100),
        VisibleTab(index = 2, offset = 200, size = 100),
    )

    @Test
    fun `fully visible selection does not scroll`() {
        assertEquals(null, revealTarget(threeVisible(), viewportWidth = 300, selectedIndex = 1))
    }

    @Test
    fun `selection clipped at right reveals trailing`() {
        // index 2 spans 200..300 exactly; index 3 would be off-screen (not in visible list)
        assertEquals(
            RevealTarget(3, RevealEdge.TRAILING),
            revealTarget(threeVisible(), viewportWidth = 300, selectedIndex = 3),
        )
    }

    @Test
    fun `selection before first visible reveals leading`() {
        // first visible index is 2; selecting 0 should bring it to the leading edge
        val shifted = listOf(
            VisibleTab(index = 2, offset = 0, size = 100),
            VisibleTab(index = 3, offset = 100, size = 100),
            VisibleTab(index = 4, offset = 200, size = 100),
        )
        assertEquals(
            RevealTarget(0, RevealEdge.LEADING),
            revealTarget(shifted, viewportWidth = 300, selectedIndex = 0),
        )
    }

    @Test
    fun `partially clipped left edge reveals leading`() {
        // index 0 starts at -20 (clipped left), so it is not fully visible
        val clipped = listOf(
            VisibleTab(index = 0, offset = -20, size = 100),
            VisibleTab(index = 1, offset = 80, size = 100),
            VisibleTab(index = 2, offset = 180, size = 100),
        )
        assertEquals(
            RevealTarget(0, RevealEdge.LEADING),
            revealTarget(clipped, viewportWidth = 300, selectedIndex = 0),
        )
    }

    @Test
    fun `partially clipped right edge reveals trailing`() {
        // index 2 spans 180..280 fully visible; index 3 spans 280..380 clipped right
        val clipped = listOf(
            VisibleTab(index = 1, offset = 80, size = 100),
            VisibleTab(index = 2, offset = 180, size = 100),
            VisibleTab(index = 3, offset = 280, size = 100),
        )
        assertEquals(
            RevealTarget(3, RevealEdge.TRAILING),
            revealTarget(clipped, viewportWidth = 300, selectedIndex = 3),
        )
    }

    @Test
    fun `empty visible list does not scroll`() {
        assertEquals(null, revealTarget(emptyList(), viewportWidth = 300, selectedIndex = 0))
    }

    @Test
    fun `label is black on light fills`() {
        // Regression for white-on-yellow washing out after idle teal→yellow.
        assertEquals(Color.Black, tabLabelColor(IdleYellow))                 // luma ~0.77
        assertEquals(Color.Black, tabLabelColor(agentColor("claude")))       // orange ~0.68
        assertEquals(Color.Black, tabLabelColor(UnknownGray))                // gray ~0.62
    }

    @Test
    fun `label is white on dark and translucent fills`() {
        assertEquals(Color.White, tabLabelColor(agentColor("codex")))        // teal ~0.46
        assertEquals(Color.White, tabLabelColor(QualityRed))                 // red  ~0.46
        // Translucent white over the black strip looks dark, must keep white.
        assertEquals(Color.White, tabLabelColor(white15))                    // ~0.15
    }
}
