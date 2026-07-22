import Foundation

/// Severity of a workspace group, lowest → highest. Drives the sidebar sort
/// order and which groups raise attention. Mirrors ActivityCoordinator's
/// unseen logic: `blocked` > finished-but-unseen > working > unknown > seen.
public enum RollupState: Int, Comparable, Sendable {
    case seen = 0
    case unknown = 1
    case working = 2
    case finishedUnseen = 3
    case blocked = 4
    public static func < (lhs: RollupState, rhs: RollupState) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A group of sessions (default: one per working directory / git root) with an
/// aggregate state rolled up from its members. Pure value type — no I/O, fully
/// testable. Consumed by the client sidebars and by the server push dispatcher's
/// coalescing.
public struct WorkspaceRollup: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let sessionIds: [UUID]
    public let state: RollupState
    public let attentionCount: Int

    public init(id: String, title: String, sessionIds: [UUID], state: RollupState, attentionCount: Int) {
        self.id = id
        self.title = title
        self.sessionIds = sessionIds
        self.state = state
        self.attentionCount = attentionCount
    }

    /// Per-session severity. `blocked` always needs attention; a finished
    /// (`idle`) agent needs attention only until the user has seen it. When
    /// `liveState` is supplied (a fresher observer event than the session-list
    /// snapshot carries) it wins over `session.agentState`.
    public static func rollupState(for session: SessionInfo, unseen: Set<UUID>,
                                   liveState: AgentDetectedState? = nil) -> RollupState {
        guard session.agent != nil else { return .seen }
        switch liveState ?? session.agentState {
        case .blocked: return .blocked
        case .idle:    return unseen.contains(session.id) ? .finishedUnseen : .seen
        case .working: return .working
        case .unknown, .none: return .unknown
        }
    }

    /// Fold a session list into groups, worst-state-first then title-ascending.
    /// `agentStates` is the live per-session state map (leads the snapshot), so
    /// an observer event that arrived ahead of a refreshed list still wins.
    public static func group(
        sessions: [SessionInfo],
        agentStates: [UUID: AgentDetectedState],
        unseen: Set<UUID>,
        groupKey: (SessionInfo) -> String,
        title: (String) -> String
    ) -> [WorkspaceRollup] {
        var buckets: [String: [SessionInfo]] = [:]
        for session in sessions { buckets[groupKey(session), default: []].append(session) }
        let rollups = buckets.map { key, members -> WorkspaceRollup in
            let states = members.map { rollupState(for: $0, unseen: unseen, liveState: agentStates[$0.id]) }
            return WorkspaceRollup(
                id: key,
                title: title(key),
                sessionIds: members.map(\.id),
                state: states.max() ?? .seen,
                attentionCount: states.filter { $0 == .blocked || $0 == .finishedUnseen }.count)
        }
        return rollups.sorted { $0.state != $1.state ? $0.state > $1.state : $0.title < $1.title }
    }
}
