import Foundation
import Combine
import ClaudeRelayKit

/// Activity-state facet extracted from `SharedSessionCoordinator`.
///
/// Holds the live agent/awaiting-input state plus the "session stolen" UI
/// flags. The parent coordinator keeps `@Published` read-through forwarders
/// and republishes this object's `objectWillChange` so existing SwiftUI
/// bindings (`$coordinator.showSessionStolen`, `coordinator.agentSessions`)
/// keep working without view changes.
///
/// Why separated: this cluster has a tight, well-defined surface
/// (server activity events → published UI state) and is the most
/// independently testable slice of `SharedSessionCoordinator`. Keeping it
/// together here also lets the activity-persistence concern stay in one
/// place, next to the `SessionOwnershipStore` writes that back it.
@MainActor
public final class ActivityCoordinator: ObservableObject {

    // MARK: - Published State

    /// Session IDs mapped to the coding agent currently running in them.
    /// Server-reported via `sessionActivity` WebSocket messages; the mirror
    /// is persisted to `UserDefaults` (via `SessionOwnershipStore`) so the
    /// sidebar can render the agent badge while waiting for the first event
    /// after reconnect.
    @Published public var agentSessions: [UUID: String]

    /// Session IDs whose coding agent is currently idle (awaiting user
    /// input). Drives the "needs attention" dot in the sidebar. Derived
    /// state — cleared automatically when the agent exits (see
    /// `handleActivityUpdate`).
    @Published public var sessionsAwaitingInput: Set<UUID> = []

    /// Fine-grained agent state per session (Phase 2 screen detection).
    /// Nil-absent when the server doesn't report it (older server / no agent).
    @Published public var agentStates: [UUID: AgentDetectedState] = [:]

    /// Latest window title per session, surfaced under the session name.
    @Published public var sessionTitles: [UUID: String] = [:]

    /// Sessions with an unacknowledged blocked/done state — drives the
    /// "needs attention" affordance. Cleared by `markSeen` when the user
    /// activates the session. Mirrors herdr's client-side `seen` bit.
    @Published public var unseenSessions: Set<UUID> = []

    /// UI-facing flags for the "Session Moved" alert. Presented by
    /// `WorkspaceView` / macOS equivalent when another device attaches to a
    /// session currently attached here.
    @Published public var stolenSessionName: String?
    @Published public var stolenSessionShortId: String?
    @Published public var showSessionStolen = false

    // MARK: - Dependencies

    private let ownershipStore: SessionOwnershipStore

    // MARK: - Init

    /// - Parameters:
    ///   - ownershipStore: UserDefaults-backed persistence. `saveAgents` is
    ///     called when the agent map changes so the sidebar can repaint
    ///     with the correct badges right after reconnect.
    ///   - initialAgents: seed value, typically loaded via
    ///     `ownershipStore.loadAgents()` at coordinator init.
    public init(
        ownershipStore: SessionOwnershipStore,
        initialAgents: [UUID: String]
    ) {
        self.ownershipStore = ownershipStore
        self.agentSessions = initialAgents
    }

    // MARK: - Activity

    /// Returns the agent id running in this session, or nil.
    public func activeAgent(for sessionId: UUID) -> String? {
        agentSessions[sessionId]
    }

    /// Whether any coding agent is currently running in the given session.
    public func isRunningAgent(sessionId: UUID) -> Bool {
        agentSessions[sessionId] != nil
    }

    /// Derive the `ActivityState` for a session. The sidebar views call this
    /// to pick between active/idle/agent-active/agent-idle — the lookup
    /// order lives here so both platforms stay in sync.
    public func activityState(for sessionId: UUID) -> ActivityState {
        if isRunningAgent(sessionId: sessionId) {
            return sessionsAwaitingInput.contains(sessionId) ? .agentIdle : .agentActive
        }
        return sessionsAwaitingInput.contains(sessionId) ? .idle : .active
    }

    /// The fine-grained agent state for a session, or nil.
    public func agentState(for sessionId: UUID) -> AgentDetectedState? {
        agentStates[sessionId]
    }

    /// The window title for a session, or nil.
    public func title(for sessionId: UUID) -> String? {
        sessionTitles[sessionId]
    }

    /// Mark a session's state as seen — clears its "needs attention" flag.
    /// Called by the coordinator when the session becomes active.
    public func markSeen(_ sessionId: UUID) {
        unseenSessions.remove(sessionId)
    }

    /// Group the given sessions into workspace rollups (one per working
    /// directory / git root), worst-state first. Uses the live `agentStates`
    /// map — which leads the session-list snapshot — so a fresh observer event
    /// wins over stale snapshot state. `unseenSessions` (@Published) drives the
    /// view refresh; the caller passes its current session list.
    public func rollups(for sessions: [SessionInfo]) -> [WorkspaceRollup] {
        WorkspaceRollup.group(
            sessions: sessions,
            agentStates: agentStates,
            unseen: unseenSessions,
            groupKey: { $0.workingDir ?? "~" },
            title: { $0 == "~" ? "Other" : ($0 as NSString).lastPathComponent })
    }

    // MARK: - Server-event handlers

    /// Apply an activity update reported by the server. Mutates
    /// `agentSessions` / `sessionsAwaitingInput` and, when the agent map
    /// changes, writes through to `UserDefaults` via the ownership store.
    ///
    /// The caller passes a closure so the parent coordinator can flip the
    /// matching `TerminalViewModel.isAgentActive` flag without this type
    /// needing to know about the TerminalViewModel cache.
    public func handleActivityUpdate(
        sessionId: UUID,
        activity: ActivityState,
        agent: String?,
        agentState: AgentDetectedState? = nil,
        title: String? = nil,
        isActiveSession: Bool = false,
        onAgentActiveChange: (UUID, Bool) -> Void = { _, _ in }
    ) {
        // Only persist to UserDefaults on actual state transitions, not redundant updates
        var changed = false
        if activity.isAgentRunning, let agentId = agent {
            if agentSessions[sessionId] != agentId {
                agentSessions[sessionId] = agentId
                onAgentActiveChange(sessionId, true)
                changed = true
            }
        } else {
            if agentSessions.removeValue(forKey: sessionId) != nil {
                onAgentActiveChange(sessionId, false)
                changed = true
            }
        }
        if changed { ownershipStore.saveAgents(agentSessions) }

        // Fine-grained state + title mirror the agent-running lifecycle: when no
        // agent runs, clear them so a stale "blocked" never lingers.
        if agent != nil {
            if let agentState { agentStates[sessionId] = agentState } else { agentStates.removeValue(forKey: sessionId) }
            if let title, !title.isEmpty { sessionTitles[sessionId] = title } else { sessionTitles.removeValue(forKey: sessionId) }
        } else {
            agentStates.removeValue(forKey: sessionId)
            sessionTitles.removeValue(forKey: sessionId)
        }

        // "Needs attention" bucket: a blocked prompt or a just-finished (idle-
        // after-working "done") agent is worth surfacing until the user looks.
        // Working is in-progress — not attention-worthy on its own. The session
        // the user is CURRENTLY viewing is by definition seen: never flag it,
        // and clear any stale flag if an update arrives while it is on screen.
        if isActiveSession {
            unseenSessions.remove(sessionId)
        } else if agent != nil, let agentState, agentState == .blocked || agentState == .idle {
            unseenSessions.insert(sessionId)
        } else if agentState == .working || agent == nil {
            unseenSessions.remove(sessionId)
        }

        if activity == .agentIdle, agentSessions[sessionId] != nil {
            sessionsAwaitingInput.insert(sessionId)
        } else {
            sessionsAwaitingInput.remove(sessionId)
        }
    }

    /// Cleanup summary returned from `handleSessionStolen`. The parent
    /// coordinator owns the active-session slot and the terminal cache, so
    /// Raise the "Session Moved" alert for a session lost to another device.
    /// The coordinator handles the sidebar/tab/terminal cleanup separately (and
    /// before this call); this only flips the @Published alert flags so the UI
    /// presents the OK-only popup. Used for BOTH active and sidebar-only lost
    /// sessions so the user always gets the notice.
    public func presentStolenAlert(sessionId: UUID, name: String) {
        stolenSessionName = name
        stolenSessionShortId = String(sessionId.uuidString.prefix(8))
        showSessionStolen = true
    }

    /// Clear activity state for a locally terminated session.
    public func forgetSession(_ sessionId: UUID) {
        agentSessions.removeValue(forKey: sessionId)
        sessionsAwaitingInput.remove(sessionId)
        agentStates.removeValue(forKey: sessionId)
        sessionTitles.removeValue(forKey: sessionId)
        unseenSessions.remove(sessionId)
    }

    /// Apply the server's pruned-agents set so
    /// `sessionsAwaitingInput` doesn't keep dangling entries for sessions
    /// the server no longer knows about.
    public func applyPrunedAgents(_ removedAgents: Set<UUID>) {
        if !removedAgents.isEmpty {
            sessionsAwaitingInput.subtract(removedAgents)
            unseenSessions.subtract(removedAgents)
            for id in removedAgents {
                agentStates.removeValue(forKey: id)
                sessionTitles.removeValue(forKey: id)
            }
        }
    }
}
