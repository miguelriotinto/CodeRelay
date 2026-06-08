package relay.feature.workspace.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
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
import androidx.compose.animation.core.rememberInfiniteTransition
import relay.protocol.ConnectionQuality

/**
 * Pure color mapping for a [ConnectionQuality], ported from
 * `ConnectionQualityDot.swift:20-26`:
 *  - excellent / good → green
 *  - poor / veryPoor → yellow
 *  - disconnected → red
 *
 * Note green covers BOTH excellent and good; the blink (below) is what
 * distinguishes good from excellent visually.
 */
fun qualityColor(quality: ConnectionQuality): Color = when (quality) {
    ConnectionQuality.EXCELLENT, ConnectionQuality.GOOD -> QualityGreen
    ConnectionQuality.POOR, ConnectionQuality.VERY_POOR -> QualityYellow
    ConnectionQuality.DISCONNECTED -> QualityRed
}

/**
 * Whether the dot blinks for [quality]. Ported from
 * `ConnectionQualityDot.swift:28-30`: blink iff `.good || .veryPoor`. This is
 * deliberately NOT "all yellow" — `good` is green-but-blinking and `veryPoor`
 * is yellow-but-blinking, while `poor` (also yellow) is steady.
 */
fun shouldBlink(quality: ConnectionQuality): Boolean =
    quality == ConnectionQuality.GOOD || quality == ConnectionQuality.VERY_POOR

internal val QualityGreen = Color(0xFF4CAF50)
internal val QualityYellow = Color(0xFFFFC107)
internal val QualityRed = Color(0xFFF44336)

/**
 * Small colored dot visualizing the current [ConnectionQuality], shown in the
 * workspace status bar. Mirrors `ConnectionQualityDot.swift`:
 *  - color via [qualityColor]
 *  - a 0.5 s ease-in-out blink (opacity 1.0 ⇄ 0.3) via
 *    [rememberInfiniteTransition] when [shouldBlink] is true.
 */
@Composable
fun ConnectionQualityDot(
    quality: ConnectionQuality,
    modifier: Modifier = Modifier,
    size: Dp = 8.dp,
) {
    val blink = shouldBlink(quality)
    val transition = rememberInfiniteTransition(label = "qualityBlink")
    val animatedAlpha by transition.animateFloat(
        initialValue = 1.0f,
        targetValue = 0.3f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 500),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "qualityBlinkAlpha",
    )
    Box(
        modifier = modifier
            .size(size)
            .alpha(if (blink) animatedAlpha else 1.0f)
            .clip(CircleShape)
            .background(qualityColor(quality)),
    )
}

@Preview
@Composable
private fun ConnectionQualityDotPreview() {
    ConnectionQualityDot(quality = ConnectionQuality.VERY_POOR)
}
