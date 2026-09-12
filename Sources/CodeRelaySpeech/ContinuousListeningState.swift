import Foundation

/// State machine for the continuous listening pipeline.
///
/// UX contract: the UI shows three color buckets to the user.
///   • Blue  — waiting for wake word (`listening`, `detectingWakeWord`)
///   • Red   — armed / recording the command (`armed`, `recording`, `detectingTurnEnd`)
///   • Yellow — processing the captured utterance (`transcribing`, `cleaning`, `outputting`)
public enum ContinuousListeningState: Equatable, Sendable {
    case idle
    case listening              // mic open, waiting for speech (blue)
    case detectingWakeWord      // speech heard, checking if it's the wake word (blue)
    case armed                  // wake word heard, waiting for command speech (red)
    case recording              // capturing command utterance (red)
    case detectingTurnEnd       // checking if speaker is done (red)
    case transcribing           // running WhisperKit on full utterance (yellow)
    case cleaning               // text cleanup / prompt enhancement (yellow)
    case outputting             // delivering to terminal (yellow)
    case error(String)

    /// True when the engine is doing anything (opposite of idle/error).
    public var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }

    /// True when we are actively accumulating the user's command audio.
    public var isCapturing: Bool {
        switch self {
        case .recording, .detectingTurnEnd: return true
        default: return false
        }
    }

    /// True when the UI should show "armed" red (wake word was heard,
    /// we're listening to the user's command).
    public var isArmed: Bool {
        switch self {
        case .armed, .recording, .detectingTurnEnd: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .idle:                 return "Idle"
        case .listening:            return "Listening"
        case .detectingWakeWord:    return "Checking wake word"
        case .armed:                return "Ready"
        case .recording:            return "Recording"
        case .detectingTurnEnd:     return "Checking turn end"
        case .transcribing:         return "Transcribing"
        case .cleaning:             return "Cleaning"
        case .outputting:           return "Outputting"
        case .error(let msg):       return "Error: \(msg)"
        }
    }
}
