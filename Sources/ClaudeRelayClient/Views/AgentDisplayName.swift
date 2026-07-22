import ClaudeRelayKit

/// Presentation-only friendly names for coding agents, layered over the
/// `CodingAgent` registry. The registry stays the data source; this only
/// prettifies for display (e.g. "opencode" → "Open Code").
public enum AgentDisplayName {
    public static func friendly(_ agentId: String?) -> String? {
        guard let agentId else { return nil }
        switch agentId {
        case "opencode": return "Open Code"
        default: return CodingAgent.find(id: agentId)?.displayName ?? agentId
        }
    }
}
