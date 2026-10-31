package relay.feature.workspace

import kotlin.math.abs

/**
 * Whether a one-finger drag is the left-edge swipe that opens the session list
 * (docs/superpowers/specs/2026-10-31-edge-swipe-sessions.md). Pure, in dp, so the
 * rule is unit-tested and the Compose strip only feeds it pointer deltas. The iOS
 * twin is `EdgeSwipeRule` (CodeRelayApp/Views/WorkspaceView.swift); keep the
 * numbers in step.
 *
 * Start is measured in the workspace's own coordinates: x from the left edge, y
 * from the top. Only the strip claims a touch; everything else stays the terminal's.
 */
object EdgeSwipeLogic {
    /** Width of the start strip along the left edge. */
    const val STRIP_WIDTH_DP = 20f

    /** Height of the strip, centred on the edge, so system Back keeps the rest. */
    const val BAND_HEIGHT_DP = 200f

    /** Minimum rightward travel. */
    const val MIN_TRAVEL_DP = 40f

    /** Horizontal travel must exceed this multiple of the vertical travel. */
    const val HORIZONTAL_DOMINANCE = 2f

    fun startsInStrip(startX: Float, startY: Float, viewportHeight: Float): Boolean {
        val bandTop = (viewportHeight - BAND_HEIGHT_DP) / 2f
        return startX >= 0f && startX <= STRIP_WIDTH_DP &&
            startY >= bandTop && startY <= bandTop + BAND_HEIGHT_DP
    }

    fun shouldOpen(
        startX: Float,
        startY: Float,
        dx: Float,
        dy: Float,
        viewportHeight: Float,
        listOpen: Boolean,
    ): Boolean =
        !listOpen &&
            startsInStrip(startX, startY, viewportHeight) &&
            dx >= MIN_TRAVEL_DP &&
            abs(dx) > HORIZONTAL_DOMINANCE * abs(dy)
}
