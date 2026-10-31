package relay.feature.workspace

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** The edge-swipe decision: strip + band start, travel threshold, dominance, list state. */
class EdgeSwipeLogicTest {
    private val height = 800f // band spans y 300..500

    private fun open(
        x: Float = 5f, y: Float = 400f, dx: Float = 60f, dy: Float = 0f, listOpen: Boolean = false,
    ) = EdgeSwipeLogic.shouldOpen(x, y, dx, dy, height, listOpen)

    @Test fun clearRightwardSwipeFromStripOpens() = assertTrue(open())

    @Test fun startInsideStripOpensAtBoundary() = assertTrue(open(x = 20f))

    @Test fun startOutsideStripDoesNot() = assertFalse(open(x = 21f))

    @Test fun startLeftOfScreenDoesNot() = assertFalse(open(x = -1f))

    @Test fun belowThresholdDoesNot() = assertFalse(open(dx = 39.9f))

    @Test fun exactlyAtThresholdOpens() = assertTrue(open(dx = 40f))

    @Test fun tooVerticalDoesNot() = assertFalse(open(dx = 60f, dy = 30f))

    @Test fun exactlyTwiceVerticalDoesNot() = assertFalse(open(dx = 60f, dy = 30f))

    @Test fun justUnderTwiceVerticalOpens() = assertTrue(open(dx = 60f, dy = 29f))

    @Test fun upwardDominantEnoughStillOpens() = assertTrue(open(dx = 60f, dy = -29f))

    @Test fun leftwardDoesNot() = assertFalse(open(dx = -60f))

    @Test fun listAlreadyOpenDoesNothing() = assertFalse(open(listOpen = true))

    @Test fun startAboveBandDoesNot() = assertFalse(open(y = 299f))

    @Test fun startBelowBandDoesNot() = assertFalse(open(y = 501f))

    @Test fun bandEdgesAreInclusive() {
        assertTrue(open(y = 300f))
        assertTrue(open(y = 500f))
    }
}
