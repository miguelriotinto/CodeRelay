package relay.feature.workspace.ui

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.pointerInput
import relay.feature.workspace.EdgeSwipeLogic

/**
 * The left-edge swipe that opens the session list. Apply to the workspace
 * container: it watches the Initial pass without consuming, so every touch still
 * reaches the terminal (or a sidebar row) unless the gesture fires, and only then
 * is the rest of that drag consumed. Touch only, so a mouse on the Linux desktop
 * is never involved; nothing is detected while the list is open. [EdgeSwipeLogic]
 * decides; coordinates are the container's, in dp.
 */
fun Modifier.edgeSwipeOpen(isListOpen: () -> Boolean, onOpen: () -> Unit): Modifier = composed {
    val listOpen = rememberUpdatedState(isListOpen)
    val open = rememberUpdatedState(onOpen)
    pointerInput(Unit) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
            if (down.type != PointerType.Touch) return@awaitEachGesture
            val viewportHeight = size.height / density
            val startX = down.position.x / density
            val startY = down.position.y / density
            if (listOpen.value() || !EdgeSwipeLogic.startsInStrip(startX, startY, viewportHeight)) {
                return@awaitEachGesture
            }
            var opened = false
            while (true) {
                val change = awaitPointerEvent(PointerEventPass.Initial).changes
                    .firstOrNull { it.id == down.id } ?: break
                // Once fired, swallow the release too so nothing reads it as a tap.
                if (opened) change.consume()
                if (!change.pressed) break
                if (!opened && EdgeSwipeLogic.shouldOpen(
                        startX = startX,
                        startY = startY,
                        dx = (change.position.x - down.position.x) / density,
                        dy = (change.position.y - down.position.y) / density,
                        viewportHeight = viewportHeight,
                        listOpen = false,
                    )
                ) {
                    opened = true
                    open.value()
                    change.consume()
                }
            }
        }
    }
}
