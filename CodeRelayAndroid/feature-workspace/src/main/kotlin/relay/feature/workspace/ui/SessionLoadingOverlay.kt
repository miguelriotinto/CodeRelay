package relay.feature.workspace.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import relay.session.SessionLoadPhase

/**
 * Only show the overlay once the wait has lasted this long. On a LAN the whole
 * connect → attach → replay sequence finishes well inside it, and an overlay
 * that appeared for two frames and vanished would read as a flicker on every
 * tab tap. Above it the pane has been black long enough that the user is
 * already wondering, and the narration is worth the paint.
 */
internal const val SESSION_LOADING_OVERLAY_DELAY_MS = 300L

/** Fade-in, once the delay has elapsed; short, the pane under it is black anyway. */
internal const val SESSION_LOADING_FADE_IN_MS = 150

/**
 * Fade-out, when the first frame lands. Slightly longer than the fade-in so the
 * freshly painted terminal is revealed rather than snapped to.
 */
internal const val SESSION_LOADING_FADE_OUT_MS = 200

/**
 * The session-loading overlay: spinner + phase label + replay byte counter +
 * session name, over the terminal pane while [phase] is non-null. Mirrors the
 * Swift `SessionLoadingOverlay`.
 *
 * Pure Compose — this file is also compiled by the Linux Compose Desktop build,
 * so no Android framework types and no `R` resources: every string comes from
 * [SessionLoadPhase] or the caller.
 *
 * Two deliberate details:
 *  - **Delayed appearance.** `visible` goes true only [SESSION_LOADING_OVERLAY_DELAY_MS]
 *    after the phase became non-null, and false the instant it goes null, so a
 *    fast load never shows anything.
 *  - **The last phase is kept through the fade-out.** [phase] is null while
 *    [AnimatedVisibility] is still fading, so the text is drawn from a
 *    remembered copy of the last non-null value; otherwise the label would blank
 *    mid-fade.
 *
 * Carries no `clickable`/`pointerInput` modifier on purpose: a plain background
 * never intercepts touches, so a tap or swipe during a slow replay still reaches
 * the terminal underneath.
 */
@Composable
fun SessionLoadingOverlay(
    phase: SessionLoadPhase?,
    sessionName: String?,
    modifier: Modifier = Modifier,
) {
    val isLoading = phase != null
    var visible by remember { mutableStateOf(false) }
    var shownPhase by remember { mutableStateOf<SessionLoadPhase?>(null) }
    // Remember the last non-null phase from an EFFECT, never inline in
    // composition: this composable also reads `shownPhase` below, and a write
    // to state that the same scope reads invalidates the scope again, so the
    // inline form recomposed in a tight loop for as long as a phase was set —
    // the main thread never got a frame out (Choreographer "Skipped 509
    // frames", an 8.5 s Davey) and the overlay it was meant to draw never
    // appeared. Found on the emulator against a 412 KB replay.
    LaunchedEffect(phase) {
        if (phase != null) shownPhase = phase
    }

    LaunchedEffect(isLoading) {
        if (isLoading) {
            delay(SESSION_LOADING_OVERLAY_DELAY_MS)
            visible = true
        } else {
            visible = false
        }
    }

    AnimatedVisibility(
        visible = visible,
        enter = fadeIn(tween(SESSION_LOADING_FADE_IN_MS)),
        exit = fadeOut(tween(SESSION_LOADING_FADE_OUT_MS)),
        modifier = modifier,
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.55f)),
            contentAlignment = Alignment.Center,
        ) {
            shownPhase?.let { current ->
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier
                        .padding(24.dp)
                        .semantics { liveRegion = LiveRegionMode.Polite },
                ) {
                    CircularProgressIndicator()
                    Text(
                        text = current.label,
                        style = MaterialTheme.typography.titleMedium,
                        color = Color.White,
                    )
                    current.detail?.let { detail ->
                        Text(
                            text = detail,
                            style = MaterialTheme.typography.bodyMedium,
                            color = Color.White.copy(alpha = 0.7f),
                        )
                    }
                    sessionName?.let { name ->
                        Text(
                            text = name,
                            style = MaterialTheme.typography.bodySmall,
                            color = Color.White.copy(alpha = 0.6f),
                        )
                    }
                }
            }
        }
    }
}
