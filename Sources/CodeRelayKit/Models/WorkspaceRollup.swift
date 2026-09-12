import Foundation

/// Severity of a workspace group, lowest → highest. Drives the group's badge
/// colour and which groups raise attention. Mirrors ActivityCoordinator's
/// unseen logic: `blocked` > finished-but-unseen > working > unknown > seen.
///
/// Deliberately *not* the sidebar sort key — see `WorkspaceRollup.group`.
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
    /// Group key for sessions with no working directory. Callers map it to the
    /// `otherTitle` display string; `group` pins it last.
    ///
    /// The pin is keyed on this, not on the title, so a repo that happens to be
    /// named "Other" still sorts alphabetically among its peers.
    public static let otherGroupKey = "~"

    /// Display title for the `otherGroupKey` catch-all group.
    public static let otherTitle = "Other"

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
        // A fresh live state implies an agent is present even if the snapshot's
        // `agent` field hasn't caught up yet, so it must not be gated behind
        // `session.agent`. Only when there's neither a live state nor a snapshot
        // agent do we treat the session as "no agent" → seen.
        guard session.agent != nil || liveState != nil else { return .seen }
        switch liveState ?? session.agentState {
        case .blocked: return .blocked
        case .idle:    return unseen.contains(session.id) ? .finishedUnseen : .seen
        case .working: return .working
        case .unknown, .none: return .unknown
        }
    }

    /// Fold a session list into groups, ordered by title alone.
    /// `agentStates` is the live per-session state map (leads the snapshot), so
    /// an observer event that arrived ahead of a refreshed list still wins.
    ///
    /// Order is **independent of `state`** by design. Sorting worst-state-first
    /// auto-surfaced blocked groups, but it also meant a group jumped position
    /// every time an agent changed state — so the sidebar reshuffled under the
    /// user's finger while they were reaching for a row. Attention is signalled
    /// by the badge colour and the unread count instead, which don't move.
    ///
    /// The comparator must be a **total** order, not merely severity-free:
    /// `buckets` is a `Dictionary`, so `map` yields groups in hash order, and
    /// `sorted(by:)` is not guaranteed stable — two rollups the comparator
    /// calls equal may swap between calls. `id` (the group key, unique by
    /// construction) is the final tiebreak so no such pair exists.
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
        return rollups.sorted(by: orderedBefore)
    }

    /// Title-ascending order with the catch-all group pinned last.
    ///
    /// `localizedStandardCompare` rather than `<`: `<` is codepoint ordering, so
    /// `Zebra` would sort before `apple`. This is the Finder comparison —
    /// case-insensitive plus natural numeric ordering, so `repo2` precedes
    /// `repo10`.
    static func orderedBefore(_ lhs: WorkspaceRollup, _ rhs: WorkspaceRollup) -> Bool {
        let lhsIsOther = lhs.id == otherGroupKey
        let rhsIsOther = rhs.id == otherGroupKey
        if lhsIsOther != rhsIsOther { return rhsIsOther }
        switch lhs.title.localizedStandardCompare(rhs.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        // Same displayed title from two different directories (e.g. two clones
        // of one repo). Fall through to the unique key so the order is total.
        case .orderedSame: return lhs.id < rhs.id
        }
    }
}
