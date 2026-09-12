import Foundation

/// Result of running a raw transcript through `SpeechPostProcessor`.
/// Callers use `deliverableText` to get the string to send to the terminal,
/// treating `nil` as "emit nothing".
public enum ProcessedText: Equatable, Sendable {
    case passthrough(String)
    case cleaned(String)
    case enhanced(String)
    case refused(original: String)
    case empty

    public var deliverableText: String? {
        switch self {
        case .passthrough(let t), .cleaned(let t), .enhanced(let t): return t
        case .refused(let original): return original
        case .empty: return nil
        }
    }
}
