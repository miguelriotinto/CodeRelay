package relay.net

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionQuality

/**
 * Exercises the ping/pong bookkeeping (RTT window, consecutive-failure death
 * detection, quality computation) through the internal test seams so no test
 * waits on the real 10 s keepalive interval or 5 s pong timeout.
 */
class QualityMonitorTest {

    @Test
    fun `rtt window caps at six samples`() {
        val conn = RelayConnection()
        repeat(10) { conn.testRecordRtt(0.05) }
        assertEquals(6, conn.testRttWindowCount)
    }

    @Test
    fun `three consecutive failures fire onSendFailed`() {
        val conn = RelayConnection()
        var fired = 0
        conn.onSendFailed = { fired++ }

        conn.testRecordRtt(null)
        assertEquals(1, conn.testConsecutiveFailures)
        conn.testMarkDeadIfNeeded()
        assertEquals(0, fired) { "should not fire below threshold" }

        conn.testRecordRtt(null)
        conn.testRecordRtt(null)
        assertEquals(3, conn.testConsecutiveFailures)
        conn.testMarkDeadIfNeeded()
        assertEquals(1, fired) { "death detector fires once at three failures" }
    }

    @Test
    fun `healthy ping resets failures and reports onHealthyPing once`() {
        val conn = RelayConnection()
        var healthy = 0
        conn.onHealthyPing = { healthy++ }

        conn.testRecordRtt(null)
        conn.testRecordRtt(null)
        assertEquals(2, conn.testConsecutiveFailures)
        assertEquals(0, healthy)

        conn.testRecordRtt(0.05)
        assertEquals(0, conn.testConsecutiveFailures)
        assertEquals(1, healthy) { "exactly one onHealthyPing per healthy sample" }
    }

    @Test
    fun `six fast pings compute as EXCELLENT`() {
        val conn = RelayConnection()
        repeat(6) { conn.testRecordRtt(0.05) }
        assertEquals(ConnectionQuality.EXCELLENT, conn.testComputeQuality())
    }

    @Test
    fun `empty window is EXCELLENT`() {
        val conn = RelayConnection()
        assertEquals(ConnectionQuality.EXCELLENT, conn.testComputeQuality())
    }

    @Test
    fun `all-null window is VERY_POOR`() {
        val conn = RelayConnection()
        repeat(6) { conn.testRecordRtt(null) }
        assertEquals(ConnectionQuality.VERY_POOR, conn.testComputeQuality())
    }
}
