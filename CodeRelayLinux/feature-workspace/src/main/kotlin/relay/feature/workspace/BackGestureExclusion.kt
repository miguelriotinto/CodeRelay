package relay.feature.workspace

import androidx.compose.ui.Modifier

/** Desktop has no system Back gesture to exclude; the touch-only edge swipe needs nothing here. */
fun Modifier.backGestureExclusion(): Modifier = this
