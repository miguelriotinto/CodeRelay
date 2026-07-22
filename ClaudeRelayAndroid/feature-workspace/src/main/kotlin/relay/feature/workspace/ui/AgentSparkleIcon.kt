package relay.feature.workspace.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import relay.protocol.AgentDetectedState

/**
 * Small "sparkles" glyph shown before a coding agent's name in session rows.
 * Mirrors the Swift `AgentSparkleIcon`: tinted with the agent's palette color
 * and shimmering (alpha pulse) only while the agent is [AgentDetectedState.WORKING];
 * fully opaque and static otherwise.
 *
 * SF Symbols' variable-color animation has no Compose equivalent, so working
 * state is conveyed with an `infiniteRepeatable` alpha pulse instead.
 */
@Composable
fun AgentSparkleIcon(
    agentId: String?,
    agentState: AgentDetectedState?,
    size: Dp = 14.dp,
) {
    val working = agentState == AgentDetectedState.WORKING
    val alpha = if (working) {
        val transition = rememberInfiniteTransition(label = "agent-sparkle")
        val animated by transition.animateFloat(
            initialValue = 1f,
            targetValue = 0.35f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 700),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "agent-sparkle-alpha",
        )
        animated
    } else {
        1f
    }

    Icon(
        imageVector = Icons.Filled.AutoAwesome,
        contentDescription = null,
        tint = agentColor(agentId),
        modifier = Modifier
            .size(size)
            .alpha(alpha),
    )
}
