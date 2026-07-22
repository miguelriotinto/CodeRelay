import SwiftUI
import ClaudeRelayKit

/// Color bucket for the session lifecycle/attachment dot shown left of the
/// session name. Replaces the old lifecycle text pill.
public enum SessionStatusColor: Equatable {
    case green   // activeAttached
    case yellow  // activeDetached / transitional
    case none    // terminal — not shown in the session list

    public static func bucket(_ state: SessionState) -> SessionStatusColor {
        switch state {
        case .activeAttached: return .green
        case .activeDetached, .created, .starting, .resuming: return .yellow
        case .exited, .failed, .terminated, .expired: return .none
        }
    }
}

/// Small lifecycle/attachment dot: green = attached, yellow = detached/transitional.
public struct SessionStatusDot: View {
    public let state: SessionState
    public let size: CGFloat

    public init(state: SessionState, size: CGFloat = 8) {
        self.state = state
        self.size = size
    }

    private var color: Color {
        switch SessionStatusColor.bucket(state) {
        case .green: return .green
        case .yellow: return .yellow
        case .none: return .clear
        }
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .fixedSize()
    }
}
