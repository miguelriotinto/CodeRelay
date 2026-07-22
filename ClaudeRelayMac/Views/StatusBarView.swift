import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

struct StatusBarView: View {
    @ObservedObject var coordinator: SessionCoordinator

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                ConnectionQualityDot(quality: coordinator.connection.connectionQuality, size: 6)
                Text(connectionLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let id = coordinator.activeSessionId {
                if let info = coordinator.activeSessions.first(where: { $0.id == id }) {
                    SessionStatusDot(state: info.state, size: 6)
                }
                let agentId = coordinator.activeAgent(for: id)
                if let agentId, let friendly = AgentDisplayName.friendly(agentId),
                   let agentState = coordinator.agentState(for: id) {
                    Text(friendly)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    AgentStatePill(agentState: agentState, agentId: agentId, seen: !coordinator.isUnseen(id))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.black)
    }

    private var connectionLabel: String {
        if coordinator.isRecovering { return "Reconnecting..." }
        switch coordinator.connection.connectionQuality {
        case .excellent: return "Excellent"
        case .good:      return "Good"
        case .poor:      return "Poor"
        case .veryPoor:  return "Very Poor"
        case .disconnected: return "Disconnected"
        }
    }
}
