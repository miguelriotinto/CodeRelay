package relay.protocol

/**
 * Lifecycle state of a ClaudeRelay session.
 *
 * Ports `SessionState.swift`. The [raw] values are the hyphenated wire strings
 * (e.g. `active-attached`); decoding is done via [fromRaw], which falls back to
 * [CREATED] for unknown values, matching the resilient client behaviour.
 */
enum class SessionState(val raw: String) {
    CREATED("created"),
    STARTING("starting"),
    ACTIVE_ATTACHED("active-attached"),
    ACTIVE_DETACHED("active-detached"),
    RESUMING("resuming"),
    EXITED("exited"),
    FAILED("failed"),
    TERMINATED("terminated"),
    EXPIRED("expired");

    /** Whether this state is terminal (no further transitions allowed). */
    val isTerminal: Boolean
        get() = when (this) {
            EXITED, FAILED, TERMINATED, EXPIRED -> true
            else -> false
        }

    /** Returns whether a transition from this state to [target] is valid. */
    fun canTransition(target: SessionState): Boolean = when (this) {
        CREATED -> target == STARTING
        STARTING -> target in startingTransitions
        ACTIVE_ATTACHED -> target in attachedTransitions
        ACTIVE_DETACHED -> target in detachedTransitions
        RESUMING -> target in resumingTransitions
        EXITED, FAILED, TERMINATED, EXPIRED -> false
    }

    companion object {
        private val startingTransitions = setOf(ACTIVE_ATTACHED, FAILED)
        private val attachedTransitions = setOf(ACTIVE_DETACHED, EXITED, FAILED, TERMINATED)
        private val detachedTransitions =
            setOf(RESUMING, ACTIVE_ATTACHED, EXPIRED, EXITED, FAILED, TERMINATED)
        private val resumingTransitions = setOf(ACTIVE_ATTACHED, FAILED, TERMINATED)

        fun fromRaw(value: String): SessionState = entries.firstOrNull { it.raw == value } ?: CREATED
    }
}
