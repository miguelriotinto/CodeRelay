package relay.protocol

/**
 * Activity state of a terminal session, tracked by the server.
 *
 * Ports `ActivityState.swift`. [fromRaw] accepts the legacy `claude_active` /
 * `claude_idle` raw values for backward compatibility with servers predating
 * multi-agent support, and falls back to [ACTIVE] for unknown values. Encoding
 * always uses the canonical modern [raw] names — legacy values are never written.
 */
enum class ActivityState(val raw: String) {
    /** Terminal output flowing, no coding agent detected. */
    ACTIVE("active"),

    /** No terminal output for the silence threshold, no coding agent detected. */
    IDLE("idle"),

    /** A coding agent is running, terminal output flowing. */
    AGENT_ACTIVE("agent_active"),

    /** A coding agent is running, no output for the silence threshold (awaiting input). */
    AGENT_IDLE("agent_idle");

    /** Whether a coding agent is currently running in this session. */
    val isAgentRunning: Boolean
        get() = when (this) {
            AGENT_ACTIVE, AGENT_IDLE -> true
            ACTIVE, IDLE -> false
        }

    /** Whether the session appears to be waiting for user input. */
    val isAwaitingInput: Boolean
        get() = when (this) {
            IDLE, AGENT_IDLE -> true
            ACTIVE, AGENT_ACTIVE -> false
        }

    companion object {
        fun fromRaw(value: String): ActivityState = when (value) {
            "active" -> ACTIVE
            "idle" -> IDLE
            "agent_active", "claude_active" -> AGENT_ACTIVE
            "agent_idle", "claude_idle" -> AGENT_IDLE
            else -> ACTIVE
        }
    }
}
