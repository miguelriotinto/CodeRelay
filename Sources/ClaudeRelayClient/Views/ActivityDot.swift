import SwiftUI
import ClaudeRelayKit

/// Small colored dot visualizing a session's state. When Phase-2 `agentState`
/// is present it drives the color/blink (herdr parity); otherwise the dot
/// falls back to the legacy `ActivityState`-based rendering so older servers
/// look unchanged.
///
/// Conforms to `Equatable` so SwiftUI can short-circuit redraws inside
/// loops such as `ForEach` and `TimelineView`.
public struct ActivityDot: View, Equatable {
    public let activity: ActivityState
    public var agentId: String?
    public var agentState: AgentDetectedState?
    public var seen: Bool
    public var size: CGFloat

    public init(
        activity: ActivityState,
        agentId: String? = nil,
        agentState: AgentDetectedState? = nil,
        seen: Bool = true,
        size: CGFloat = 8
    ) {
        self.activity = activity
        self.agentId = agentId
        self.agentState = agentState
        self.seen = seen
        self.size = size
    }

    @State private var blinkOpacity: Double = 1.0

    /// Whether the dot should pulse: a blocked agent (needs attention) or,
    /// in legacy mode, an agent awaiting input.
    private var shouldBlink: Bool {
        if let agentState { return agentState == .blocked }
        return activity == .agentIdle
    }

    private var color: Color {
        if let agentState {
            switch agentState {
            case .blocked: return .red
            case .working: return AgentColorPalette.color(for: agentId)
            case .idle:    return seen ? .green : .yellow
            case .unknown: return .gray
            }
        }
        // Legacy fallback (no Phase-2 state reported).
        switch activity {
        case .active, .idle: return .green
        case .agentActive, .agentIdle: return AgentColorPalette.color(for: agentId)
        }
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .fixedSize()
            .opacity(shouldBlink ? blinkOpacity : 1.0)
            .onChange(of: shouldBlink) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                } else {
                    withAnimation(.default) { blinkOpacity = 1.0 }
                }
            }
            .onAppear {
                if shouldBlink {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                }
            }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.activity == rhs.activity
            && lhs.agentId == rhs.agentId
            && lhs.agentState == rhs.agentState
            && lhs.seen == rhs.seen
            && lhs.size == rhs.size
    }
}
