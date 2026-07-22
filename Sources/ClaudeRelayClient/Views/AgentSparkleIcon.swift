import SwiftUI
import ClaudeRelayKit

/// Small "sparkles" glyph shown before a coding agent's name in session rows.
/// Tinted with the agent's palette color and shimmering (variable-color
/// animation) only while the agent is `.working`; static otherwise.
///
/// Conforms to `Equatable` so SwiftUI can short-circuit redraws inside
/// `ForEach` session lists.
public struct AgentSparkleIcon: View, Equatable {
    public var agentId: String?
    public var agentState: AgentDetectedState?
    public var size: CGFloat

    public init(
        agentId: String? = nil,
        agentState: AgentDetectedState? = nil,
        size: CGFloat = 11
    ) {
        self.agentId = agentId
        self.agentState = agentState
        self.size = size
    }

    private var isWorking: Bool { agentState == .working }

    public var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size))
            .foregroundStyle(AgentColorPalette.color(for: agentId))
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isWorking)
            .accessibilityHidden(true)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agentId == rhs.agentId
            && lhs.agentState == rhs.agentState
            && lhs.size == rhs.size
    }
}
