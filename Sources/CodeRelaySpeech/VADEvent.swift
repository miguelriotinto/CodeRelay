import Foundation

/// Events emitted by a voice activity detector per audio chunk.
public enum VADEvent: Equatable, Sendable {
    case speechStart         // first chunk of a speech segment
    case speechContinue      // subsequent speech chunk
    case silenceStart        // first chunk of silence after speech
    case silenceContinue     // ongoing silence

    public var isSpeech: Bool {
        switch self {
        case .speechStart, .speechContinue: return true
        case .silenceStart, .silenceContinue: return false
        }
    }

    /// True for start-of-segment events; callers usually only act on these.
    public var isEdge: Bool {
        switch self {
        case .speechStart, .silenceStart: return true
        case .speechContinue, .silenceContinue: return false
        }
    }
}

/// Protocol for voice activity detection — enables mock injection in tests.
public protocol VoiceActivityDetecting: AnyObject, Sendable {
    /// Process one audio chunk and return the resulting event.
    func process(chunk: [Float]) -> VADEvent

    /// Reset internal state (e.g., recurrent hidden state, debounce counters).
    func reset()
}
