package relay.feature.workspace.ui

import androidx.compose.ui.graphics.Color

/**
 * Centralized per-agent color mapping, ported VALUE-for-VALUE from
 * `Sources/ClaudeRelayClient/Views/AgentColorPalette.swift`.
 *
 * To add a new coding agent: add a branch here AND register the agent in the
 * `CodingAgent` registry (shared with the server). No other UI file changes.
 *
 *  - `"claude"` → orange (`Color(0xFFFFA500)`, the Compose match for SwiftUI's
 *    `.orange` which renders as 1.0/0.5/0.0 sRGB).
 *  - `"codex"` → teal `Color(red = 84/255, green = 132/255, blue = 137/255)`.
 *  - anything else (incl. `null`) → the **same** teal as codex. This default ==
 *    codex equality is load-bearing and matches AgentColorPalette.swift:12-14
 *    where both the `"codex"` and `default` branches return the identical color.
 */
object AgentColorPalette {

    /** SwiftUI `.orange` is sRGB 1.0/0.5/0.0 → 0xFFFFA500 (255,165,0). */
    private val claudeOrange = Color(0xFFFFA500)

    /** The codex teal, also the default for unknown/null agents. */
    private val codexTeal = Color(red = 84 / 255f, green = 132 / 255f, blue = 137 / 255f)

    fun color(agentId: String?): Color = when (agentId) {
        "claude" -> claudeOrange
        "codex" -> codexTeal
        else -> codexTeal
    }
}

/** Free-function alias mirroring the task spec (`agentColor(agentId)`). */
fun agentColor(agentId: String?): Color = AgentColorPalette.color(agentId)
