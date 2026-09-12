import Foundation

/// Pipeline states for the on-device speech engine.
/// UI observes this to drive mic button color and indicators.
public enum SpeechEngineState: Equatable, Sendable {
    case idle
    case loadingModel   // Whisper model loading into memory (first use after launch)
    case recording
    case transcribing
    case cleaning       // Smart cleanup (local LLM) or prompt enhancement (cloud)
    case error(String)

    public var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }

    public var description: String {
        switch self {
        case .idle:         return "Idle"
        case .loadingModel: return "Loading model..."
        case .recording:    return "Recording..."
        case .transcribing: return "Transcribing..."
        case .cleaning:     return "Processing..."
        case .error(let msg): return "Error: \(msg)"
        }
    }
}
