import Foundation

/// Represents the lifecycle state of a CodeRelay session.
public enum SessionState: String, Codable, Sendable {
    case created = "created"
    case starting = "starting"
    case activeAttached = "active-attached"
    case activeDetached = "active-detached"
    case resuming = "resuming"
    case exited = "exited"
    case failed = "failed"
    case terminated = "terminated"
    case expired = "expired"

    /// Whether this state is terminal (no further transitions allowed).
    public var isTerminal: Bool {
        switch self {
        case .exited, .failed, .terminated, .expired:
            return true
        default:
            return false
        }
    }

    // Static transition sets — allocated once, not per call.
    private static let startingTransitions: Set<SessionState> = [.activeAttached, .failed]
    private static let attachedTransitions: Set<SessionState> = [.activeDetached, .exited, .failed, .terminated]
    private static let detachedTransitions: Set<SessionState> = [.resuming, .activeAttached, .expired, .exited, .failed, .terminated]
    private static let resumingTransitions: Set<SessionState> = [.activeAttached, .failed, .terminated]

    /// Returns whether a transition from this state to the given target state is valid.
    public func canTransition(to target: SessionState) -> Bool {
        switch self {
        case .created:
            return target == .starting
        case .starting:
            return Self.startingTransitions.contains(target)
        case .activeAttached:
            return Self.attachedTransitions.contains(target)
        case .activeDetached:
            return Self.detachedTransitions.contains(target)
        case .resuming:
            return Self.resumingTransitions.contains(target)
        case .exited, .failed, .terminated, .expired:
            return false
        }
    }
}
