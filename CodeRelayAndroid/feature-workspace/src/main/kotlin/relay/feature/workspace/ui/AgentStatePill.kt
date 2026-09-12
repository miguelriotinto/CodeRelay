package relay.feature.workspace.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import relay.protocol.AgentDetectedState
import relay.protocol.SessionState

/** Display word for the agent-state pill. IDLE is shown as "Waiting". */
fun agentStateWord(s: AgentDetectedState): String = when (s) {
    AgentDetectedState.IDLE -> "Waiting"
    AgentDetectedState.WORKING -> "Working"
    AgentDetectedState.BLOCKED -> "Blocked"
    AgentDetectedState.UNKNOWN -> "Unknown"
}

/** Pill color, parity with Swift AgentStatePillModel.color. */
fun agentStatePillColor(s: AgentDetectedState, agentId: String?, seen: Boolean): Color = when (s) {
    AgentDetectedState.BLOCKED -> QualityRed
    AgentDetectedState.WORKING -> agentColor(agentId)
    AgentDetectedState.IDLE -> if (seen) QualityGreen else IdleYellow
    AgentDetectedState.UNKNOWN -> UnknownGray
}

/** Left dot color for the session lifecycle/attachment state; null = not shown. */
fun sessionStatusDotColor(state: SessionState): Color? = when (state) {
    SessionState.ACTIVE_ATTACHED -> QualityGreen
    SessionState.ACTIVE_DETACHED, SessionState.CREATED,
    SessionState.STARTING, SessionState.RESUMING -> QualityYellow
    SessionState.EXITED, SessionState.FAILED,
    SessionState.TERMINATED, SessionState.EXPIRED -> null
}

@Composable
fun AgentStatePill(agentState: AgentDetectedState, agentId: String?, seen: Boolean) {
    val c = agentStatePillColor(agentState, agentId, seen)
    Text(
        text = agentStateWord(agentState),
        style = MaterialTheme.typography.labelSmall,
        color = c,
        modifier = Modifier
            .background(color = c.copy(alpha = 0.15f), shape = RoundedCornerShape(50))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

@Composable
fun SessionStatusDot(state: SessionState, size: Dp = 8.dp) {
    val color = sessionStatusDotColor(state) ?: return
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .background(color),
    )
}
