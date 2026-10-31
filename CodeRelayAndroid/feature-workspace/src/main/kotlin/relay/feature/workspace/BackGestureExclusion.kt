package relay.feature.workspace

import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.ui.Modifier

/**
 * Keeps the system Back gesture off this region so the edge swipe that opens the
 * session list can start there. Android-only; the Linux build supplies a no-op
 * with the same name.
 */
fun Modifier.backGestureExclusion(): Modifier = systemGestureExclusion()
