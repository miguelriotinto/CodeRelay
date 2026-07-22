import SwiftUI
import ClaudeRelayKit

/// Pure color/word mapping for the agent-state pill. "Waiting" is the display
/// label for `.idle` (agent running, awaiting input).
public enum AgentStatePillModel {
    public static func word(_ s: AgentDetectedState) -> String {
        switch s {
        case .idle: return "Waiting"
        case .working: return "Working"
        case .blocked: return "Blocked"
        case .unknown: return "Unknown"
        }
    }

    public static func color(_ s: AgentDetectedState, agentId: String?, seen: Bool) -> Color {
        switch s {
        case .blocked: return .red
        case .working: return AgentColorPalette.color(for: agentId)
        case .idle: return seen ? .green : .yellow
        case .unknown: return .gray
        }
    }
}

/// Colored capsule + text word for a running agent's state.
public struct AgentStatePill: View {
    public let agentState: AgentDetectedState
    public let agentId: String?
    public let seen: Bool

    public init(agentState: AgentDetectedState, agentId: String?, seen: Bool) {
        self.agentState = agentState
        self.agentId = agentId
        self.seen = seen
    }

    public var body: some View {
        let c = AgentStatePillModel.color(agentState, agentId: agentId, seen: seen)
        Text(AgentStatePillModel.word(agentState))
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(c.opacity(0.15))
            .foregroundStyle(c)
            .clipShape(Capsule())
    }
}
