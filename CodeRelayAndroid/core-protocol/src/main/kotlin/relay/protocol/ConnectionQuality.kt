package relay.protocol

/**
 * Connection quality bucket derived from median ping RTT and ping success rate.
 *
 * Ports `ConnectionQuality.swift`. The bucketing in [of] mirrors the Swift
 * `init(medianRTT:successRate:)` ordering exactly. [DISCONNECTED] is not
 * produced by [of] — it is set by transport-level logic, matching Swift where
 * the initializer never returns `.disconnected`.
 */
enum class ConnectionQuality {
    EXCELLENT,
    GOOD,
    POOR,
    VERY_POOR,
    DISCONNECTED;

    companion object {
        // RTT thresholds in seconds. 83% success = 5 of 6 pings; perfect required for excellent.
        private const val EXCELLENT_RTT = 0.1
        private const val GOOD_RTT = 0.3
        private const val POOR_RTT = 0.8
        private const val MIN_SUCCESS_RATE = 0.5
        private const val GOOD_SUCCESS_RATE = 0.83
        private const val PERFECT_SUCCESS_RATE = 1.0

        fun of(medianRttSec: Double, successRate: Double): ConnectionQuality = when {
            successRate < MIN_SUCCESS_RATE -> VERY_POOR
            medianRttSec < EXCELLENT_RTT && successRate >= PERFECT_SUCCESS_RATE -> EXCELLENT
            medianRttSec < GOOD_RTT && successRate >= GOOD_SUCCESS_RATE -> GOOD
            medianRttSec < POOR_RTT && successRate >= MIN_SUCCESS_RATE -> POOR
            else -> VERY_POOR
        }
    }
}
