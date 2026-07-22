package relay.feature.workspace.ui

/**
 * Presentation-only friendly names for coding agents. Mirrors the Swift
 * `AgentDisplayName.friendly` (opencode → "Open Code"). Kept in lockstep with
 * the `CodingAgent` registry display names.
 */
fun friendlyAgentName(agentId: String?): String? = when (agentId) {
    null -> null
    "claude" -> "Claude Code"
    "codex" -> "Codex"
    "opencode" -> "Open Code"
    else -> agentId
}
