package relay.app

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

/**
 * Animated splash, ported from `SplashScreenView.swift`.
 *
 * The brand background and three-phase animation match iOS:
 *  1. Logo scales 0.6 → 1.0 + fades in (spring, ~0.8 s) — driven by an
 *     [Animatable] in a [LaunchedEffect], the SwiftUI `withAnimation(.spring…)`
 *     analog.
 *  2. The title fades in (ease-out, ~0.5 s) after a 0.6 s delay.
 *  3. Everything fades out (~0.7 s), then [onComplete] fires to advance the nav
 *     graph to Servers.
 *
 * The brand color is black, the same value the iOS splash uses
 * (SplashScreenView.swift:14). There is no bundled `SplashLogo` raster in this
 * module, so the "logo" is a rounded brand square with the app initial — a
 * deliberate placeholder; swapping in a drawable later is a one-line `Image` change.
 *
 * @param appVersion shown small under the title (matches the iOS version line)
 * @param onComplete advance past the splash (nav-to-Servers)
 */
@Composable
fun SplashScreen(appVersion: String, onComplete: () -> Unit) {
    val logoScale = remember { Animatable(0.6f) }
    val logoOpacity = remember { Animatable(0f) }
    val textOpacity = remember { Animatable(0f) }
    val rootOpacity = remember { Animatable(1f) }

    LaunchedEffect(Unit) {
        // Phase 1: logo scales up + fades in (spring).
        val spring = spring<Float>(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessLow)
        logoOpacity.animateTo(1f, animationSpec = tween(durationMillis = 400))
        logoScale.animateTo(1f, animationSpec = spring)
        delay(200)

        // Phase 2: title fades in.
        textOpacity.animateTo(1f, animationSpec = tween(durationMillis = 500))
        delay(1_400)

        // Phase 3: fade everything out, then complete.
        rootOpacity.animateTo(0f, animationSpec = tween(durationMillis = 700))
        delay(50)
        onComplete()
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .alpha(rootOpacity.value)
            .background(BRAND_COLOR),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            // The "CR" mark — same artwork as the launcher icon and the iOS
            // splash logo. White glyph on a transparent background (no opaque
            // box), so nothing dark is revealed as the splash fades out.
            Image(
                painter = painterResource(R.drawable.splash_logo),
                contentDescription = "Code Relay",
                modifier = Modifier
                    .size(120.dp)
                    .scale(logoScale.value)
                    .alpha(logoOpacity.value),
            )

            Text(
                text = "Code Relay",
                color = Color.White,
                fontSize = 24.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.alpha(textOpacity.value),
            )

            Text(
                text = "Version $appVersion",
                color = Color.White.copy(alpha = 0.6f),
                fontSize = 8.sp,
                modifier = Modifier.alpha(textOpacity.value),
            )
        }
    }
}

/** Brand color black, matching the iOS splash (SplashScreenView.swift:14). */
private val BRAND_COLOR = Color.Black
