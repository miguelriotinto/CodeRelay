package relay.protocol

import java.util.UUID

/**
 * Severity of a workspace group, lowest → highest (ordinal encodes severity).
 * Mirrors the Swift [RollupState]: blocked > finished-unseen > working >
 * unknown > seen.
 *
 * Drives the group badge colour, **not** the sidebar order — see
 * [WorkspaceRollup.group].
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
         * Group key for sessions with no working directory. Callers map it to
         * [OTHER_TITLE]; [group] pins it last.
         *
         * The pin is keyed on this rather than on the title, so a repo that
         * happens to be named "Other" still sorts alphabetically among peers.
         */
        const val OTHER_GROUP_KEY = "~"

        /** Display title for the [OTHER_GROUP_KEY] catch-all group. */
        const val OTHER_TITLE = "Other"

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
            // A fresh live state implies an agent even if the snapshot's `agent`
            // hasn't caught up; only "no live state AND no snapshot agent" → seen.
            if (session.agent == null && liveState == null) return RollupState.SEEN
            return when (liveState ?: session.agentState) {
                AgentDetectedState.BLOCKED -> RollupState.BLOCKED
                AgentDetectedState.IDLE ->
                    if (session.id in unseen) RollupState.FINISHED_UNSEEN else RollupState.SEEN
                AgentDetectedState.WORKING -> RollupState.WORKING
                else -> RollupState.UNKNOWN
            }
        }

        /**
         * Fold sessions into groups, ordered by title alone.
         *
         * Order is **independent of [state]** by design. Worst-state-first
         * auto-surfaced blocked groups, but it also moved a group every time an
         * agent changed state, reshuffling the sidebar under the user's finger.
         * Attention is signalled by the badge colour and unread count instead.
         *
         * Parity with Swift `WorkspaceRollup.group`.
         */
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
            }.sortedWith(ORDER)

        /**
         * Title-ascending with the catch-all group pinned last, matching Swift's
         * `localizedStandardCompare`: case-insensitive and natural-numeric, so
         * `repo2` precedes `repo10` and `Zebra` follows `apple`. The JVM has no
         * single comparator for that pair, hence [compareNaturally].
         *
         * `id` is the final tiebreak to make the order **total**: `groupBy`
         * yields hash order and `sortedWith` is stable only with respect to the
         * input, so without it two same-titled groups could swap between calls.
         */
        private val ORDER: Comparator<WorkspaceRollup> =
            compareBy<WorkspaceRollup> { it.id == OTHER_GROUP_KEY }
                .thenComparator { lhs, rhs -> compareNaturally(lhs.title, rhs.title) }
                .thenBy { it.id }

        /**
         * Case-insensitive comparison that orders embedded digit runs by numeric
         * value rather than lexically.
         */
        internal fun compareNaturally(lhs: String, rhs: String): Int {
            var i = 0
            var j = 0
            while (i < lhs.length && j < rhs.length) {
                val a = lhs[i]
                val b = rhs[j]
                if (a.isDigit() && b.isDigit()) {
                    // Compare whole digit runs, ignoring leading zeros, so "9"
                    // sorts before "10" instead of after it.
                    val endA = lhs.digitRunEnd(i)
                    val endB = rhs.digitRunEnd(j)
                    val runA = lhs.substring(i, endA).trimStart('0')
                    val runB = rhs.substring(j, endB).trimStart('0')
                    if (runA.length != runB.length) return runA.length - runB.length
                    if (runA != runB) return runA.compareTo(runB)
                    i = endA
                    j = endB
                    continue
                }
                val cmp = a.lowercaseChar().compareTo(b.lowercaseChar())
                if (cmp != 0) return cmp
                i++
                j++
            }
            return (lhs.length - i) - (rhs.length - j)
        }

        private fun String.digitRunEnd(from: Int): Int {
            var end = from
            while (end < length && this[end].isDigit()) end++
            return end
        }
    }
}
