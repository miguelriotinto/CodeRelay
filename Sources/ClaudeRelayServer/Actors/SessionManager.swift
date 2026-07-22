import Foundation
import ClaudeRelayKit

// MARK: - SessionError

public enum SessionError: Error {
    case notFound(UUID)
    case ownershipViolation
    case invalidTransition(SessionState, SessionState)
    case sessionLimitExceeded(limit: Int)
}

// MARK: - SessionManager Actor

public actor SessionManager {
    public typealias PTYFactory = @Sendable (UUID, UInt16, UInt16, Int) throws -> any PTYSessionProtocol

    public let config: RelayConfig
    public let tokenStore: TokenStore
    private let ptyFactory: PTYFactory
    private var sessions: [UUID: ManagedSession] = [:]
    private var detachTimers: [UUID: Task<Void, Never>] = [:]
    public typealias ActivityObserver =
        @Sendable (UUID, ActivityState, String?, AgentDetectedState?, String?) -> Void
    private var activityObservers = ObserverRegistry<ActivityObserver>()
    public typealias StealObserver = @Sendable (UUID) -> Void
    private var stealObservers = ObserverRegistry<StealObserver>()
    public typealias RenameObserver = @Sendable (UUID, String) -> Void
    private var renameObservers = ObserverRegistry<RenameObserver>()

    struct ManagedSession {
        var info: SessionInfo
        var ptySession: (any PTYSessionProtocol)?
        var terminalSince: Date?
        /// Latest activity reported by the PTY's monitor. Updated from
        /// `reportActivityChange` so `listSessionsForToken` can return a
        /// snapshot without hopping into each PTY actor.
        var latestActivity: ActivityState = .active
        /// The coding agent detected in this session, if any.
        var latestAgent: String?
        /// Latest fine-grained agent state (Phase 2 screen detection).
        var latestAgentState: AgentDetectedState?
        /// Latest window title (OSC 0/2).
        var latestTitle: String?
        /// Latest working directory (git root), resolved from the PTY's cwd on
        /// the foreground poll. Sticky — a later update without a cwd keeps it.
        var latestWorkingDir: String?
        /// Monotonic revision of the last activity update we accepted.
        /// `reportActivityChange` drops updates whose revision is not
        /// strictly greater (see C-03).
        var activityRevision: UInt64 = 0
    }

    // MARK: - Init

    private let gitRootResolver: GitRootResolver

    public init(config: RelayConfig, tokenStore: TokenStore, ptyFactory: PTYFactory? = nil,
                gitRootResolver: GitRootResolver = GitRootResolver()) {
        self.config = config
        self.tokenStore = tokenStore
        self.gitRootResolver = gitRootResolver
        self.ptyFactory = ptyFactory ?? { id, cols, rows, scrollback in
            try PTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        }
    }

    // MARK: - Public API

    /// Create a new session bound to the given token.
    public func createSession(
        tokenId: String,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        name: String? = nil
    ) async throws -> SessionInfo {
        let limit = config.maxSessionsPerToken
        if limit > 0 {
            let active = sessions.values.lazy.filter {
                $0.info.tokenId == tokenId && !$0.info.state.isTerminal
            }.count
            if active >= limit {
                throw SessionError.sessionLimitExceeded(limit: limit)
            }
        }
        let id = UUID()
        let now = Date()

        // Create PTY session and activate its read source
        let pty = try ptyFactory(id, cols, rows, config.scrollbackSize)
        await pty.startReading()

        // Transition starting -> activeAttached
        let activeInfo = SessionInfo(
            id: id,
            name: name,
            state: .activeAttached,
            tokenId: tokenId,
            createdAt: now,
            cols: cols,
            rows: rows
        )

        var managed = ManagedSession(info: activeInfo, ptySession: pty)
        managed.latestActivity = .active

        // Set up exit handler BEFORE storing — guarantees handler is in place
        // before any EOF from the read source can fire handleExit().
        let manager = self
        await pty.setExitHandler {
            Task {
                await manager.handlePTYExit(sessionId: id)
            }
        }

        let sessionId = id
        await pty.setActivityHandler { [weak self] newState, agent, agentState, title, revision in
            Task {
                await self?.reportActivityChange(
                    sessionId: sessionId, activity: newState, agent: agent?.id,
                    agentState: agentState, title: title, revision: revision
                )
            }
        }
        await pty.setWorkingDirHandler { [weak self] cwd in
            Task { await self?.handleWorkingDir(sessionId: sessionId, cwd: cwd) }
        }

        // Store session
        sessions[id] = managed

        return activeInfo
    }

    /// Attach to a session (wire up I/O).
    /// - Parameter excludeObserver: Observer ID to exclude from steal notifications
    ///   (the connection doing the attach should not receive its own stolen push).
    /// Supports cross-token attach: if the session belongs to a different token,
    /// ownership is transferred and the old token's observers are notified.
    public func attachSession(
        id: UUID,
        tokenId: String,
        excludeObserver: UUID? = nil
    ) async throws -> (SessionInfo, any PTYSessionProtocol) {
        guard var managed = sessions[id] else {
            throw SessionError.notFound(id)
        }
        guard let pty = managed.ptySession else {
            throw SessionError.notFound(id)
        }

        let currentState = managed.info.state
        let newState: SessionState = .activeAttached

        // attachSession is a cross-device takeover: allow from any non-terminal state.
        // Steal notification is only relevant when a live attachment is being displaced.
        guard !currentState.isTerminal else {
            throw SessionError.invalidTransition(currentState, newState)
        }

        let oldTokenId = managed.info.tokenId

        if currentState == .activeAttached {
            // Clear the PTY's output handler before returning so the displaced
            // device stops receiving output. The new attacher's wirePTYOutput
            // will install its own handler on the next actor turn. Without
            // this await the old handler could keep firing — the PTY read
            // source runs on its own dispatch queue, not serialized with the
            // unstructured Task that wirePTYOutput uses to call setOutputHandler.
            await pty.clearOutputHandler()
        }

        // Always notify the old token's observers so that the source device
        // removes the session from its sidebar — not just when displacing a
        // live attachment.
        reportSessionStolen(sessionId: id, tokenId: oldTokenId, excludeObserver: excludeObserver)

        // Transfer ownership to the attaching token (enables cross-device attach).
        let newInfo = managed.info.with(tokenId: tokenId).transitioning(to: newState)
        managed.info = newInfo
        sessions[id] = managed

        // Attached: bump to the fast poll cadence for responsive Claude entry/exit.
        Task { await pty.setPollCadence(PTYSession.attachedPollCadence) }

        return (newInfo, pty)
    }

    /// Detach a session (client disconnected, session stays alive).
    public func detachSession(id: UUID) throws {
        guard var managed = sessions[id] else {
            throw SessionError.notFound(id)
        }

        let currentState = managed.info.state
        let newState: SessionState = .activeDetached
        guard currentState.canTransition(to: newState) else {
            throw SessionError.invalidTransition(currentState, newState)
        }

        managed.info = managed.info.transitioning(to: newState)
        sessions[id] = managed

        // Clear output handler so output goes to ring buffer
        if let pty = managed.ptySession {
            Task {
                await pty.clearOutputHandler()
            }
            // Detached: slow the poll — we still need activity for background
            // iOS tabs, but 1 s resolution is only needed for the user's foreground session.
            Task { await pty.setPollCadence(PTYSession.detachedPollCadence) }
        }

        // Start detach timeout timer (0 = never expire).
        let timeoutSeconds = config.detachTimeout
        if timeoutSeconds > 0 {
            let manager = self
            let timer = Task<Void, Never> {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                if !Task.isCancelled {
                    await manager.handleDetachTimeout(sessionId: id)
                }
            }
            detachTimers[id]?.cancel()
            detachTimers[id] = timer
        }
    }

    /// Resume a detached session.
    /// - Parameter excludeObserver: Observer ID to exclude from steal
    ///   notifications (the connection doing the resume should not receive its
    ///   own stolen push). Only relevant when the resume displaces another
    ///   connection that currently holds the session live.
    public func resumeSession(
        id: UUID,
        tokenId: String,
        excludeObserver: UUID? = nil
    ) async throws -> (SessionInfo, Data, any PTYSessionProtocol) {
        guard var managed = sessions[id] else {
            throw SessionError.notFound(id)
        }
        guard managed.info.tokenId == tokenId else {
            throw SessionError.ownershipViolation
        }
        guard let pty = managed.ptySession else {
            throw SessionError.notFound(id)
        }

        var currentState = managed.info.state

        // If still attached, another connection holds this session live.
        // Resuming displaces it — exactly like a cross-device attach — so we
        // must tear down the old handler and notify the displaced connection.
        // Without this, a device sharing the same token keeps showing (and can
        // keep driving) a session it no longer owns. Same-device tab switches
        // resume from .activeDetached and skip this path entirely.
        if currentState == .activeAttached {
            // Clear the displaced connection's output handler before the new
            // one wires up, mirroring attachSession. The PTY read source runs
            // on its own queue, so awaiting here serializes the handover.
            await pty.clearOutputHandler()
            reportSessionStolen(sessionId: id, tokenId: tokenId, excludeObserver: excludeObserver)

            managed.info = managed.info.transitioning(to: .activeDetached)
            currentState = .activeDetached
        }

        guard currentState.canTransition(to: .resuming) else {
            throw SessionError.invalidTransition(currentState, .resuming)
        }

        // Transition through resuming -> activeAttached
        managed.info = managed.info.transitioning(to: .resuming)
        let attachedInfo = managed.info.transitioning(to: .activeAttached)
        managed.info = attachedInfo
        sessions[id] = managed

        // Cancel detach timer
        detachTimers[id]?.cancel()
        detachTimers[id] = nil

        // Buffer reading requires awaiting the PTYSession actor, so return
        // empty data here — the caller reads the buffer via pty.readBuffer().
        return (attachedInfo, Data(), pty)
    }

    /// Terminate a session.
    public func terminateSession(id: UUID, tokenId: String? = nil) throws {
        guard var managed = sessions[id] else {
            throw SessionError.notFound(id)
        }

        // Ownership check (skip if admin / nil tokenId)
        if let tokenId = tokenId {
            guard managed.info.tokenId == tokenId else {
                throw SessionError.ownershipViolation
            }
        }

        let currentState = managed.info.state
        let newState: SessionState = .terminated

        // If already terminal, no-op
        guard !currentState.isTerminal else {
            return
        }

        guard currentState.canTransition(to: newState) else {
            throw SessionError.invalidTransition(currentState, newState)
        }

        managed.info = managed.info.transitioning(to: newState)
        managed.terminalSince = Date()
        sessions[id] = managed

        // Terminate PTY
        if let pty = managed.ptySession {
            Task {
                await pty.terminate()
            }
        }

        // Cancel detach timer
        detachTimers[id]?.cancel()
        detachTimers[id] = nil

        purgeTerminalSessions()
    }

    /// Rename a session. Validates ownership and broadcasts to observers.
    public func renameSession(id: UUID, tokenId: String, name: String) throws {
        guard var managed = sessions[id] else {
            throw SessionError.notFound(id)
        }
        guard managed.info.tokenId == tokenId else {
            throw SessionError.ownershipViolation
        }

        managed.info = managed.info.with(name: name)
        sessions[id] = managed

        // Broadcast rename to all observers for this token
        for (_, callback) in renameObservers.forToken(tokenId) {
            callback(id, name)
        }
    }

    /// List all sessions.
    public func listSessions() -> [SessionInfo] {
        return sessions.values.map { $0.info }
    }

    /// Inspect a single session.
    public func inspectSession(id: UUID) throws -> SessionInfo {
        guard let managed = sessions[id] else {
            throw SessionError.notFound(id)
        }
        return managed.info
    }

    /// List sessions for a specific token. Uses the cached activity state
    /// maintained via `reportActivityChange` — no PTY actor hops.
    public func listSessionsForToken(tokenId: String) -> [SessionInfo] {
        sessions.values
            .filter { $0.info.tokenId == tokenId }
            .map { $0.info.enriched(activity: $0.latestActivity, agent: $0.latestAgent,
                                    agentState: $0.latestAgentState, title: $0.latestTitle,
                                    workingDir: $0.latestWorkingDir) }
    }

    /// List all sessions across all tokens, enriched with cached activity state.
    /// Used for cross-device attach — lets a device see sessions from other tokens.
    public func listAllSessions() -> [SessionInfo] {
        sessions.values.map { $0.info.enriched(activity: $0.latestActivity, agent: $0.latestAgent,
                                               agentState: $0.latestAgentState, title: $0.latestTitle,
                                               workingDir: $0.latestWorkingDir) }
    }

    // MARK: - Activity Observers

    @discardableResult
    public func addActivityObserver(
        tokenId: String,
        callback: @escaping ActivityObserver
    ) -> UUID {
        let observerId = activityObservers.add(tokenId: tokenId, callback: callback)

        // Push current (cached) activity state for this token's sessions so the
        // client doesn't wait for a change event to render correct state.
        for managed in sessions.values where managed.info.tokenId == tokenId {
            guard !managed.info.state.isTerminal else { continue }
            callback(managed.info.id, managed.latestActivity, managed.latestAgent,
                     managed.latestAgentState, managed.latestTitle)
        }
        return observerId
    }

    public func removeActivityObserver(id: UUID) {
        activityObservers.remove(id: id)
    }

    /// Apply an activity update reported by a PTY's monitor. The `revision`
    /// is monotonic within a single `SessionActivityMonitor`; if a later
    /// update has already been applied (as can happen when the PTY actor and
    /// the manager actor schedule work at different rates), this call is
    /// dropped rather than rewinding the cached state.
    ///
    /// `revision` defaults to `.max` so tests / admin tooling can force an
    /// update without having to mint a fresh sequence.
    /// Resolve a raw cwd from the PTY poll to its git root, then report it.
    private func handleWorkingDir(sessionId: UUID, cwd: String) async {
        let root = await gitRootResolver.root(for: cwd)
        reportWorkingDir(sessionId: sessionId, workingDir: root)
    }

    /// Update a session's cached working directory (already resolved to a git
    /// root) and refresh observers with the current activity so grouped clients
    /// repaint — even when no activity state changed (a plain `cd`).
    public func reportWorkingDir(sessionId: UUID, workingDir: String) {
        guard var managed = sessions[sessionId] else { return }
        guard !managed.info.state.isTerminal else { return }
        guard managed.latestWorkingDir != workingDir else { return }
        managed.latestWorkingDir = workingDir
        sessions[sessionId] = managed
        let tokenId = managed.info.tokenId
        for (_, callback) in activityObservers.forToken(tokenId) {
            callback(sessionId, managed.latestActivity, managed.latestAgent,
                     managed.latestAgentState, managed.latestTitle)
        }
    }

    public func reportActivityChange(
        sessionId: UUID,
        activity: ActivityState,
        agent: String? = nil,
        agentState: AgentDetectedState? = nil,
        title: String? = nil,
        workingDir: String? = nil,
        revision: UInt64 = .max
    ) {
        guard var managed = sessions[sessionId] else { return }
        guard !managed.info.state.isTerminal else { return }
        // Drop strictly older updates. Equal revisions pass — the monitor
        // never re-emits the same revision, but test harnesses sometimes
        // replay the same fixed value.
        if revision < managed.activityRevision { return }
        managed.activityRevision = revision
        managed.latestActivity = activity
        managed.latestAgent = agent
        managed.latestAgentState = agentState
        managed.latestTitle = title
        // Sticky: a resolved cwd persists until a newer one arrives, so an
        // activity update that carries no cwd doesn't wipe the group.
        if let workingDir { managed.latestWorkingDir = workingDir }
        sessions[sessionId] = managed
        let tokenId = managed.info.tokenId
        for (_, callback) in activityObservers.forToken(tokenId) {
            callback(sessionId, activity, agent, agentState, title)
        }
    }

    // MARK: - Steal Observers

    @discardableResult
    public func addStealObserver(
        tokenId: String,
        callback: @escaping StealObserver
    ) -> UUID {
        stealObservers.add(tokenId: tokenId, callback: callback)
    }

    public func removeStealObserver(id: UUID) {
        stealObservers.remove(id: id)
    }

    private func reportSessionStolen(sessionId: UUID, tokenId: String, excludeObserver: UUID?) {
        for (observerId, callback) in stealObservers.forToken(tokenId) {
            if observerId != excludeObserver {
                callback(sessionId)
            }
        }
    }

    // MARK: - Rename Observers

    @discardableResult
    public func addRenameObserver(
        tokenId: String,
        callback: @escaping RenameObserver
    ) -> UUID {
        renameObservers.add(tokenId: tokenId, callback: callback)
    }

    public func removeRenameObserver(id: UUID) {
        renameObservers.remove(id: id)
    }

    // MARK: - Periodic Cleanup

    /// Evict observers older than `olderThan` seconds. Called periodically from
    /// main.swift to prevent unbounded growth when handlers die without running
    /// `cleanupSession()` (crash, panic, network partition).
    public func purgeStaleObservers(olderThan seconds: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-seconds)
        let purged = activityObservers.purgeStale(olderThan: cutoff)
            + stealObservers.purgeStale(olderThan: cutoff)
            + renameObservers.purgeStale(olderThan: cutoff)
        if purged > 0 {
            RelayLogger.log(.info, category: "session",
                            "Purged \(purged) stale observer(s)")
        }
    }

    /// Exposed only for tests. Do not call from production code.
    public var _testOnly_observerCount: Int {
        activityObservers.count + stealObservers.count + renameObservers.count
    }

    // MARK: - Shutdown

    /// Terminates all active sessions. Called during graceful server shutdown.
    public func shutdown() async {
        // Collect PTYs to terminate
        var ptysToTerminate: [any PTYSessionProtocol] = []
        for (id, managed) in sessions where !managed.info.state.isTerminal {
            if let pty = managed.ptySession {
                ptysToTerminate.append(pty)
            }
            var updated = managed
            updated.info = managed.info.transitioning(to: .terminated)
            sessions[id] = updated
        }
        // Await all PTY terminations in parallel
        await withTaskGroup(of: Void.self) { group in
            for pty in ptysToTerminate {
                group.addTask { await pty.terminate() }
            }
        }
        // Cancel all detach timers
        for (_, timer) in detachTimers {
            timer.cancel()
        }
        detachTimers.removeAll()
    }

    // MARK: - Cleanup

    /// Removes sessions in terminal states (exited, failed, terminated, expired)
    /// that have been in that state for longer than the grace period.
    private func purgeTerminalSessions(gracePeriod: TimeInterval = 300) {
        let cutoff = Date().addingTimeInterval(-gracePeriod)
        let staleIds = sessions.filter { _, managed in
            managed.info.state.isTerminal && (managed.terminalSince ?? managed.info.createdAt) < cutoff
        }.map { $0.key }

        for id in staleIds {
            sessions.removeValue(forKey: id)
            detachTimers[id]?.cancel()
            detachTimers.removeValue(forKey: id)
        }

        if !staleIds.isEmpty {
            RelayLogger.log(category: "session", "Purged \(staleIds.count) terminal session(s)")
        }
    }

    // MARK: - Internal Handlers

    private func handlePTYExit(sessionId: UUID) {
        guard var managed = sessions[sessionId] else { return }
        let currentState = managed.info.state
        guard currentState.canTransition(to: .exited) else { return }

        managed.info = managed.info.transitioning(to: .exited)

        // Terminate PTY to close master FD and free the kernel PTY pair
        if let pty = managed.ptySession {
            Task {
                await pty.terminate()
            }
        }
        managed.ptySession = nil
        managed.terminalSince = Date()
        sessions[sessionId] = managed

        // Clean up timer
        detachTimers[sessionId]?.cancel()
        detachTimers.removeValue(forKey: sessionId)

        purgeTerminalSessions()
    }

    private func handleDetachTimeout(sessionId: UUID) {
        guard var managed = sessions[sessionId] else { return }
        let currentState = managed.info.state
        guard currentState.canTransition(to: .expired) else { return }

        managed.info = managed.info.transitioning(to: .expired)
        managed.terminalSince = Date()
        sessions[sessionId] = managed

        // Clean up timer entry
        detachTimers.removeValue(forKey: sessionId)

        // Terminate PTY
        if let pty = managed.ptySession {
            Task {
                await pty.terminate()
            }
        }
        managed.ptySession = nil
        sessions[sessionId] = managed

        purgeTerminalSessions()
    }
}
