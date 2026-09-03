package relay.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import relay.protocol.AgentDetectedState
import relay.protocol.SessionInfo
import java.util.UUID

/**
 * What the tray menu shows for the live connection: one row per session with
 * its state, plus an attention count for the tooltip.
 *
 * Mirrors the macOS `MenuBarDropdown` — the per-session rollup is the reason
 * the tray exists once the window is hidden: it is how the user sees that an
 * agent finished or is waiting without bringing the window back.
 *
 * Pure data, built by [rows], so the labelling is unit-tested; the composable
 * [rememberTrayModel] only collects the coordinator's flows into it.
 */
data class TrayModel(
    val sessions: List<Row> = emptyList(),
) {
    data class Row(val id: UUID, val label: String, val needsAttention: Boolean)

    val attentionCount: Int get() = sessions.count { it.needsAttention }

    fun tooltip(serverName: String?): String = buildString {
        append(DISPLAY_NAME)
        if (serverName != null) append(" — ").append(serverName)
        if (attentionCount > 0) append(" · ").append(attentionCount).append(" waiting")
    }

    companion object {
        /**
         * Builds the rows. The glyph encodes the agent state the way the
         * sidebar's dot does, in the one place a menu can carry it: text.
         *
         *  - `●` working, `◐` needs input, `○` idle, and no glyph when no
         *    agent is detected.
         *  - The active session is marked with `✓`, as on macOS.
         */
        fun rows(
            sessions: List<SessionInfo>,
            names: Map<UUID, String>,
            agentStates: Map<UUID, AgentDetectedState>,
            awaitingInput: Set<UUID>,
            activeId: UUID?,
        ): TrayModel = TrayModel(
            sessions = sessions.map { info ->
                val name = names[info.id] ?: info.name ?: info.id.toString().take(8)
                val state = agentStates[info.id]
                val blocked = state == AgentDetectedState.BLOCKED || info.id in awaitingInput
                val glyph = when {
                    blocked -> "◐ "
                    state == AgentDetectedState.WORKING -> "● "
                    state == AgentDetectedState.IDLE -> "○ "
                    else -> ""
                }
                val check = if (info.id == activeId) " ✓" else ""
                Row(id = info.id, label = "$glyph$name$check", needsAttention = blocked)
            },
        )
    }
}

/** Collects the live connection's flows into a [TrayModel]; empty with no connection. */
@Composable
fun rememberTrayModel(session: ConnectionSession?): TrayModel {
    val coordinator = session?.coordinator ?: return remember { TrayModel() }
    val sessions by coordinator.activeSessions.collectAsState()
    val names by coordinator.sessionNames.collectAsState()
    val agentStates by coordinator.agentStates.collectAsState()
    val awaiting by coordinator.sessionsAwaitingInput.collectAsState()
    val activeId by coordinator.activeSessionId.collectAsState()
    return remember(sessions, names, agentStates, awaiting, activeId) {
        TrayModel.rows(sessions, names, agentStates, awaiting, activeId)
    }
}
