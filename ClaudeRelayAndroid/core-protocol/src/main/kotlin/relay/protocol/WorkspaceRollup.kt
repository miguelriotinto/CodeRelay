package relay.protocol

import java.util.UUID

/**
 * Severity of a workspace group, lowest → highest (ordinal encodes severity).
 * Mirrors the Swift [RollupState]: blocked > finished-unseen > working >
 * unknown > seen.
 */
enum class RollupState { SEEN, UNKNOWN, WORKING, FINISHED_UNSEEN, BLOCKED }

/**
 * A group of sessions (one per working directory / git root) with an aggregate
 * state rolled up from its members. Pure value type; parity with Swift
 * `WorkspaceRollup`.
 */
data class WorkspaceRollup(
    val id: String,
    val title: String,
    val sessionIds: List<UUID>,
    val state: RollupState,
    val attentionCount: Int,
) {
    companion object {
        /**
         * Per-session severity. `blocked` always needs attention; a finished
         * (`idle`) agent needs attention only until seen. [liveState] (a fresher
         * observer event than the snapshot) wins over `session.agentState`.
         */
        fun rollupState(
            session: SessionInfo,
            unseen: Set<UUID>,
            liveState: AgentDetectedState? = null,
        ): RollupState {
            if (session.agent == null) return RollupState.SEEN
            return when (liveState ?: session.agentState) {
                AgentDetectedState.BLOCKED -> RollupState.BLOCKED
                AgentDetectedState.IDLE ->
                    if (session.id in unseen) RollupState.FINISHED_UNSEEN else RollupState.SEEN
                AgentDetectedState.WORKING -> RollupState.WORKING
                else -> RollupState.UNKNOWN
            }
        }

        /** Fold sessions into groups, worst-state first then title-ascending. */
        fun group(
            sessions: List<SessionInfo>,
            agentStates: Map<UUID, AgentDetectedState>,
            unseen: Set<UUID>,
            groupKey: (SessionInfo) -> String,
            title: (String) -> String,
        ): List<WorkspaceRollup> =
            sessions.groupBy(groupKey).map { (key, members) ->
                val states = members.map { rollupState(it, unseen, agentStates[it.id]) }
                WorkspaceRollup(
                    id = key,
                    title = title(key),
                    sessionIds = members.map { it.id },
                    state = states.maxByOrNull { it.ordinal } ?: RollupState.SEEN,
                    attentionCount = states.count {
                        it == RollupState.BLOCKED || it == RollupState.FINISHED_UNSEEN
                    },
                )
            }.sortedWith(
                compareByDescending<WorkspaceRollup> { it.state.ordinal }.thenBy { it.title }
            )
    }
}
