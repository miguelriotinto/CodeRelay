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

/**
 * Pure color mapping for an [ActivityState] dot, ported from
 * `ActivityDot.swift:22-28`:
 *  - active / idle → green
 *  - agentActive / agentIdle → [agentColor] for the running agent
 */
fun activityDotColor(activity: ActivityState, agentId: String?): Color = when (activity) {
    ActivityState.ACTIVE, ActivityState.IDLE -> QualityGreen
    ActivityState.AGENT_ACTIVE, ActivityState.AGENT_IDLE -> agentColor(agentId)
}

/**
 * Whether the dot blinks for [activity]. Ported from `ActivityDot.swift:35` /
 * `:38`: blink iff `agentIdle` (the "agent running but awaiting input" state).
 * Plain `idle` does NOT blink.
 */
fun activityDotShouldBlink(activity: ActivityState): Boolean =
    activity == ActivityState.AGENT_IDLE

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
) {
    val blink = activityDotShouldBlink(activity)
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
            .background(activityDotColor(activity, agentId)),
    )
}

@Preview
@Composable
private fun ActivityDotPreview() {
    ActivityDot(activity = ActivityState.AGENT_IDLE, agentId = "claude")
}
