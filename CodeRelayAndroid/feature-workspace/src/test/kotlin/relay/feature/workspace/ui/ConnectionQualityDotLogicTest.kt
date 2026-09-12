package relay.feature.workspace.ui

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionQuality

/**
 * Verifies the quality dot color + blink decisions match
 * `ConnectionQualityDot.swift:20-30`. Green covers excellent AND good; yellow
 * covers poor AND veryPoor; red is disconnected. Blink is iff good OR veryPoor.
 */
class ConnectionQualityDotLogicTest {

    @Test
    fun `excellent and good are green`() {
        assertEquals(QualityGreen, qualityColor(ConnectionQuality.EXCELLENT))
        assertEquals(QualityGreen, qualityColor(ConnectionQuality.GOOD))
    }

    @Test
    fun `poor and veryPoor are yellow`() {
        assertEquals(QualityYellow, qualityColor(ConnectionQuality.POOR))
        assertEquals(QualityYellow, qualityColor(ConnectionQuality.VERY_POOR))
    }

    @Test
    fun `disconnected is red`() {
        assertEquals(QualityRed, qualityColor(ConnectionQuality.DISCONNECTED))
    }

    @Test
    fun `blink only on good and veryPoor`() {
        assertFalse(shouldBlink(ConnectionQuality.EXCELLENT))
        assertTrue(shouldBlink(ConnectionQuality.GOOD))
        assertFalse(shouldBlink(ConnectionQuality.POOR))
        assertTrue(shouldBlink(ConnectionQuality.VERY_POOR))
        assertFalse(shouldBlink(ConnectionQuality.DISCONNECTED))
    }
}
