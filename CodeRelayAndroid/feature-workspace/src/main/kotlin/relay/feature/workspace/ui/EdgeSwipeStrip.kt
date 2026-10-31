package relay.feature.workspace.ui

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import relay.feature.workspace.EdgeSwipeLogic
import relay.feature.workspace.backGestureExclusion

/**
 * The left-edge swipe that opens the session list: a 20 dp x 200 dp touch target
 * centred on the left edge (the rest of the edge stays the system Back gesture's,
 * via [backGestureExclusion]). It is the only thing that sees a touch starting
 * there; everything else on screen goes to the terminal untouched. Touch only, so
 * a mouse drag on the Linux desktop never triggers it. [EdgeSwipeLogic] decides.
 */
@Composable
fun EdgeSwipeStrip(
    viewportHeight: Dp,
    listOpen: Boolean,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val bandTop = (viewportHeight.value - EdgeSwipeLogic.BAND_HEIGHT_DP) / 2f
    Box(
        modifier = modifier
            .width(EdgeSwipeLogic.STRIP_WIDTH_DP.dp)
            .height(EdgeSwipeLogic.BAND_HEIGHT_DP.dp)
            .backGestureExclusion()
            .pointerInput(listOpen, viewportHeight) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    if (down.type != PointerType.Touch) return@awaitEachGesture
                    // Local px -> dp in workspace coordinates (the band is centred).
                    val startX = down.position.x / density
                    val startY = down.position.y / density + bandTop
                    var opened = false
                    while (true) {
                        val change = awaitPointerEvent(PointerEventPass.Initial).changes
                            .firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) break
                        if (!opened && EdgeSwipeLogic.shouldOpen(
                                startX = startX,
                                startY = startY,
                                dx = (change.position.x - down.position.x) / density,
                                dy = (change.position.y - down.position.y) / density,
                                viewportHeight = viewportHeight.value,
                                listOpen = listOpen,
                            )
                        ) {
                            opened = true
                            onOpen()
                        }
                        if (opened) change.consume()
                    }
                }
            },
    )
}
