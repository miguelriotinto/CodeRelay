import Foundation

public enum ConnectionQuality: String, Sendable, Equatable {
    case excellent
    case good
    case poor
    case veryPoor
    case disconnected

    // RTT thresholds in seconds. 83% success = 5 of 6 pings; perfect required for excellent.
    private static let excellentRTT: TimeInterval = 0.1
    private static let goodRTT: TimeInterval = 0.3
    private static let poorRTT: TimeInterval = 0.8
    private static let minSuccessRate: Double = 0.5
    private static let goodSuccessRate: Double = 0.83
    private static let perfectSuccessRate: Double = 1.0

    public init(medianRTT: TimeInterval, successRate: Double) {
        if successRate < Self.minSuccessRate {
            self = .veryPoor
        } else if medianRTT < Self.excellentRTT && successRate >= Self.perfectSuccessRate {
            self = .excellent
        } else if medianRTT < Self.goodRTT && successRate >= Self.goodSuccessRate {
            self = .good
        } else if medianRTT < Self.poorRTT && successRate >= Self.minSuccessRate {
            self = .poor
        } else {
            self = .veryPoor
        }
    }
}
