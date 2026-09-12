import Foundation

/// Result of predicting whether a speaker is finished with their turn.
public enum TurnEndResult: Equatable, Sendable {
    case speakerDone(confidence: Float)
    case speakerContinuing(confidence: Float)

    public var isDone: Bool {
        if case .speakerDone = self { return true }
        return false
    }
}

/// Protocol for turn-end detection — enables swapping heuristic ↔ ML model.
public protocol TurnEndDetecting: AnyObject, Sendable {
    /// Predict whether the speaker has finished their turn.
    /// The audio should be 16 kHz mono. Up to the last 8 seconds are used.
    func predict(utteranceAudio: [Float]) async -> TurnEndResult
}

/// Fallback turn-end detector that always signals "speaker done".
///
/// Used when the Smart-Turn CoreML model is not bundled or fails to load.
/// The orchestrator's hard silence timeout still bounds recording length,
/// so this degrades gracefully to "stop after N seconds of silence".
public final class HeuristicTurnEndDetector: TurnEndDetecting, @unchecked Sendable {

    public init() {}

    public func predict(utteranceAudio: [Float]) async -> TurnEndResult {
        .speakerDone(confidence: 1.0)
    }
}
