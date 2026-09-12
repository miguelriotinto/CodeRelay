/// Activity state of a terminal session, tracked by the server.
/// The server monitors PTY output continuously (even for detached sessions)
/// and pushes state changes to connected clients.
public enum ActivityState: String, Equatable, Sendable {
    /// Terminal output flowing, no coding agent detected.
    case active = "active"
    /// No terminal output for the silence threshold, no coding agent detected.
    case idle = "idle"
    /// A coding agent is running, terminal output flowing.
    case agentActive = "agent_active"
    /// A coding agent is running, no output for the silence threshold (awaiting input).
    case agentIdle = "agent_idle"

    /// Whether a coding agent is currently running in this session.
    public var isAgentRunning: Bool {
        switch self {
        case .agentActive, .agentIdle: return true
        case .active, .idle: return false
        }
    }

    /// Whether the session appears to be waiting for user input.
    public var isAwaitingInput: Bool {
        switch self {
        case .idle, .agentIdle: return true
        case .active, .agentActive: return false
        }
    }
}

// MARK: - Codable (backward-compatible)

extension ActivityState: Codable {
    /// Accepts the legacy `claude_active` / `claude_idle` raw values for
    /// backward compatibility with servers predating multi-agent support.
    /// Note the asymmetry: the synthesized `encode(to:)` (RawRepresentable)
    /// always emits the canonical modern names — we never *write* legacy
    /// values, so a v1+ server cannot talk to a v0 client that only
    /// understands legacy values. Keep `minProtocolVersion = 0` while that
    /// compatibility matters; re-evaluate the moment a breaking wire change
    /// forces the minimum up.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "active":                              self = .active
        case "idle":                                self = .idle
        case "agent_active", "claude_active":       self = .agentActive
        case "agent_idle", "claude_idle":           self = .agentIdle
        default:                                    self = .active
        }
    }
}
