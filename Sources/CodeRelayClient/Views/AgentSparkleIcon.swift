import SwiftUI
import CodeRelayKit

/// Small "sparkles" glyph shown before a coding agent's name in session rows.
/// Tinted with the agent's palette color; on iOS it also shimmers
/// (variable-color animation) while the agent is `.working`.
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

    /// Shimmer only on iOS. On macOS a repeating symbolEffect re-renders its
    /// RBLayer every frame, and each frame blocks the MAIN thread in
    /// `SharedSurfaceGroup::wait_for_allocations` (a synchronous wait on
    /// WindowServer). With a few Working sessions that was ~60% of main-thread
    /// time; the main-actor socket callbacks starved behind it, so auth took
    /// 5 s, RPCs hit their 10 s timeout and recovery tore the socket down in a
    /// loop. The "Working" badge already carries the state.
    private var shimmers: Bool {
        #if os(macOS)
        return false
        #else
        return agentState == .working
        #endif
    }

    public var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size))
            .foregroundStyle(AgentColorPalette.color(for: agentId))
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: shimmers)
            .accessibilityHidden(true)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agentId == rhs.agentId
            && lhs.agentState == rhs.agentState
            && lhs.size == rhs.size
    }
}
