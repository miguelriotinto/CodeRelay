/// Fine-grained coding-agent state detected by parsing the session's terminal
/// screen (Phase 2) — distinct from `ActivityState`, which only tracks whether
/// output is flowing. Mirrors herdr's `AgentState`.
///
/// Wire raw values are lowercase and stable. The decoder is deliberately
/// tolerant: an unrecognized value from a newer server decodes to `.unknown`
/// rather than throwing, so an older client never fails to parse a
/// `session_activity` message. This mirrors `ActivityState.init(from:)`.
public enum AgentDetectedState: String, Equatable, Sendable {
    /// Agent is running and waiting for user input (herdr "idle"/"done").
    case idle
    /// Agent is actively producing output / thinking.
    case working
    /// Agent is asking the user a question / permission prompt — needs attention.
    case blocked
    /// State could not be determined (no agent, or an ambiguous screen).
    case unknown

    /// Whether this state should raise a "needs attention" affordance in the UI.
    /// Only `.blocked` demands the user act; `.idle` merely means "done, no rush".
    public var needsAttention: Bool {
        self == .blocked
    }
}

extension AgentDetectedState: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentDetectedState(rawValue: raw) ?? .unknown
    }
}
