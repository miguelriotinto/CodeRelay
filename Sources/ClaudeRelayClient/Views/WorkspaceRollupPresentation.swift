import SwiftUI
import ClaudeRelayKit

/// Tracks which workspace-rollup groups are collapsed in the sidebar. A plain
/// value type so the toggle logic is unit-testable independent of SwiftUI.
public struct SidebarCollapseModel: Equatable {
    private var collapsed: Set<String> = []
    public init() {}
    /// Seed from persisted state (F3). Kept UI-agnostic: the caller (a view)
    /// loads the set from the coordinator's store and hands it in.
    public init(collapsed: Set<String>) { self.collapsed = collapsed }
    public func isCollapsed(_ groupId: String) -> Bool { collapsed.contains(groupId) }
    /// The current collapsed set, for persisting after a toggle (F3).
    public var collapsedGroupIds: Set<String> { collapsed }
    public mutating func toggle(_ groupId: String) {
        if collapsed.contains(groupId) { collapsed.remove(groupId) } else { collapsed.insert(groupId) }
    }
}

public extension RollupState {
    /// The badge/dot color for a group's aggregate state. Mirrors the
    /// per-session ActivityDot palette (blocked=red, finished-unseen=yellow,
    /// working=teal, unknown=gray, seen=green).
    var badgeColor: Color {
        switch self {
        case .blocked:        return .red
        case .finishedUnseen: return .yellow
        case .working:        return .teal
        case .unknown:        return .gray
        case .seen:           return .green
        }
    }
}
