package relay.feature.workspace.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import relay.protocol.ActivityState
import relay.protocol.AgentDetectedState

/**
 * Pure color mapping for the dot, ported from `ActivityDot.swift` (Task 10).
 * When [agentState] is non-null it drives the color (herdr parity); when null
 * the dot falls back to the legacy [ActivityState]-based color so older servers
 * look unchanged.
 *  - blocked → red
 *  - working → agentColor(agentId)
 *  - idle && !seen → yellow (waiting)
 *  - idle && seen  → green
 *  - unknown → gray
 *  - agentState == null → legacy: active/idle → green; agent* → agentColor
 */
fun activityDotColor(
    activity: ActivityState,
    agentId: String?,
    agentState: AgentDetectedState? = null,
    seen: Boolean = true,
): Color = when (agentState) {
    AgentDetectedState.BLOCKED -> QualityRed
    AgentDetectedState.WORKING -> agentColor(agentId)
    AgentDetectedState.IDLE -> if (seen) QualityGreen else IdleYellow
    AgentDetectedState.UNKNOWN -> UnknownGray
    null -> when (activity) {
        ActivityState.ACTIVE, ActivityState.IDLE -> QualityGreen
        ActivityState.AGENT_ACTIVE, ActivityState.AGENT_IDLE -> agentColor(agentId)
    }
}

/**
 * Whether the dot blinks. Ported from `ActivityDot.swift` (Task 10): when
 * [agentState] is present, blink iff blocked (needs attention); otherwise the
 * legacy rule — blink iff agentIdle.
 */
fun activityDotShouldBlink(
    activity: ActivityState,
    agentState: AgentDetectedState? = null,
): Boolean = if (agentState != null) {
    agentState == AgentDetectedState.BLOCKED
} else {
    activity == ActivityState.AGENT_IDLE
}

/**
 * Small colored dot visualizing a session's [ActivityState]. When an agent is
 * running the color resolves via [agentColor]; `agentIdle` blinks (0.5 s
 * ease-in-out, opacity 1.0 ⇄ 0.3). Mirrors `ActivityDot.swift`.
 */
@Composable
fun ActivityDot(
    activity: ActivityState,
    agentId: String?,
    modifier: Modifier = Modifier,
    size: Dp = 8.dp,
    agentState: AgentDetectedState? = null,
    seen: Boolean = true,
) {
    val blink = activityDotShouldBlink(activity, agentState)
    val transition = rememberInfiniteTransition(label = "activityBlink")
    val animatedAlpha by transition.animateFloat(
        initialValue = 1.0f,
        targetValue = 0.3f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 500),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "activityBlinkAlpha",
    )
    Box(
        modifier = modifier
            .size(size)
            .alpha(if (blink) animatedAlpha else 1.0f)
            .clip(CircleShape)
            .background(activityDotColor(activity, agentId, agentState, seen)),
    )
}

@Preview
@Composable
private fun ActivityDotPreview() {
    ActivityDot(activity = ActivityState.AGENT_IDLE, agentId = "claude")
}
