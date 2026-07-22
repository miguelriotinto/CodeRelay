import Foundation

/// Contains metadata about a ClaudeRelay session.
public struct SessionInfo: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let state: SessionState
    public let tokenId: String
    public let createdAt: Date
    public let cols: UInt16
    public let rows: UInt16
    public let activity: ActivityState?
    /// The coding agent currently running in this session, if any.
    /// Nil when no agent is running or when the server predates multi-agent support.
    public let agent: String?
    /// Fine-grained agent state detected from the terminal screen (Phase 2).
    /// Nil when no agent is running or when the server predates screen detection.
    public let agentState: AgentDetectedState?
    /// The session's current window title (OSC 0/2), if any. Surfaced in the sidebar.
    public let title: String?

    public init(
        id: UUID,
        name: String? = nil,
        state: SessionState,
        tokenId: String,
        createdAt: Date,
        cols: UInt16,
        rows: UInt16,
        activity: ActivityState? = nil,
        agent: String? = nil,
        agentState: AgentDetectedState? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.tokenId = tokenId
        self.createdAt = createdAt
        self.cols = cols
        self.rows = rows
        self.activity = activity
        self.agent = agent
        self.agentState = agentState
        self.title = title
    }

    // MARK: - Copy Helpers

    // Immutable-update helpers — produce a new SessionInfo with targeted field changes.
    public func transitioning(to newState: SessionState) -> SessionInfo {
        SessionInfo(id: id, name: name, state: newState, tokenId: tokenId,
                    createdAt: createdAt, cols: cols, rows: rows,
                    activity: activity, agent: agent, agentState: agentState, title: title)
    }

    public func with(name newName: String?) -> SessionInfo {
        SessionInfo(id: id, name: newName, state: state, tokenId: tokenId,
                    createdAt: createdAt, cols: cols, rows: rows,
                    activity: activity, agent: agent, agentState: agentState, title: title)
    }

    public func with(tokenId newTokenId: String) -> SessionInfo {
        SessionInfo(id: id, name: name, state: state, tokenId: newTokenId,
                    createdAt: createdAt, cols: cols, rows: rows,
                    activity: activity, agent: agent, agentState: agentState, title: title)
    }

    public func enriched(
        activity: ActivityState?,
        agent: String?,
        agentState: AgentDetectedState? = nil,
        title: String? = nil
    ) -> SessionInfo {
        SessionInfo(id: id, name: name, state: state, tokenId: tokenId,
                    createdAt: createdAt, cols: cols, rows: rows,
                    activity: activity, agent: agent, agentState: agentState, title: title)
    }
}
