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

    /// Test-only view of the detach-expiry timer table. A timer registered for a
    /// session that is not `.activeDetached` is a bug — it is armed to expire a
    /// session that must not expire — so tests assert on the key set directly.
    /// `internal`, so it is reachable from `@testable import` only.
    var detachTimerSessionIds: Set<UUID> { Set(detachTimers.keys) }
    public typealias ActivityObserver =
        @Sendable (UUID, ActivityState, String?, AgentDetectedState?, String?, String?) -> Void
    private var activityObservers = ObserverRegistry<ActivityObserver>()
    public typealias StealObserver = @Sendable (UUID) -> Void
    private var stealObservers = ObserverRegistry<StealObserver>()
    public typealias RenameObserver = @Sendable (UUID, String) -> Void
    private var renameObservers = ObserverRegistry<RenameObserver>()
    /// Token-agnostic activity observer, carrying the owning token id + the
    /// event's activity/agent state + revision. Used by the push dispatcher,
    /// which must see transitions across ALL tokens (not scoped to one).
    public typealias GlobalActivityObserver =
        @Sendable (_ sessionId: UUID, _ tokenId: String, _ activity: ActivityState,
                   _ agentState: AgentDetectedState?, _ revision: UInt64) -> Void
    private var globalActivityObservers: [UUID: GlobalActivityObserver] = [:]

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
        // Capture the admin port so the default PTY factory can pass it into
        // each session's environment (F6 hook endpoint). Keeps the PTYFactory
        // typealias unchanged so test mocks aren't affected.
        let adminPort = Int(config.adminPort)
        self.ptyFactory = ptyFactory ?? { id, cols, rows, scrollback in
            try PTYSession(sessionId: id, cols: cols, rows: rows,
                           scrollbackSize: scrollback, adminPort: adminPort)
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

        // Attaching a detached session cancels its expiry, exactly as
        // `resumeSession` does. Without this, a cross-device attach left the
        // detach timer live: it would later fire against an attached session and
        // decline to expire it.
        detachTimers[id]?.cancel()
        detachTimers[id] = nil

        // Attached: fast poll for responsive agent entry/exit. Derived from the
        // committed state above rather than written directly — see
        // `syncPollCadence`.
        await syncPollCadence(id: id)

        return (newInfo, pty)
    }

    /// Detach a session (client disconnected, session stays alive).
    ///
    /// `async` so the poll-cadence change is awaited rather than dispatched in
    /// an unstructured `Task`: for the sequential detach→resume a tab switch
    /// performs, dispatching let this method's slow cadence overtake resume's
    /// fast one and strand an attached session polling every 5 s. Every caller
    /// already awaited this actor method.
    ///
    /// The cadence sync is deliberately the **last** statement, so the state
    /// transition and the detach-expiry timer install above it share one
    /// suspension-free region. `SessionManager` is a reentrant actor: any
    /// `await` here lets `resumeSession` run to completion in between, and if
    /// the timer were installed after that suspension it would be registered for
    /// a session that is once again `.activeAttached` — an expiry timer for a
    /// session that must not expire. (`handleDetachTimeout` does drop its
    /// `detachTimers` entry unconditionally and declines to expire an attached
    /// session, so this no longer leaks the slot; it is still wrong to arm.)
    public func detachSession(id: UUID) async throws {
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

        // Detached: slow the poll — we still need activity for background iOS
        // tabs, but 1 s resolution is only needed for the user's foreground
        // session. Last, and only after the state above is committed, so a
        // reentrant resume cannot observe a torn transition.
        await syncPollCadence(id: id)
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

        // Resume lands in .activeAttached, so restore the fast poll exactly as
        // attachSession does. Without this a session that was ever detached
        // keeps polling at detachedPollCadence — and since same-device tab
        // switches detach-then-resume, that was the common path, not the rare
        // one. Routed through `syncPollCadence` so a detach suspended in the PTY
        // write cannot land its slow cadence after this attached transition.
        await syncPollCadence(id: id)

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
                     managed.latestAgentState, managed.latestTitle, managed.latestWorkingDir)
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
                     managed.latestAgentState, managed.latestTitle, managed.latestWorkingDir)
        }
    }

    /// Apply an authoritative agent state reported by a local lifecycle hook
    /// (F6). Forwarded to the session's PTY monitor, which publishes the change
    /// through the normal activity-observer chain. Returns false when the
    /// session is unknown or terminal, so the admin handler can 404.
    ///
    /// `await`s the PTY hop (rather than spawning a detached Task) so state is
    /// applied before the admin handler returns 200. This preserves ordering:
    /// Claude Code fires lifecycle hooks sequentially (each curl blocks on the
    /// 200), so a rapid working→idle burst applies in send order. A detached
    /// Task would let the two hops reach the PTY actor out of order — the
    /// last-EXECUTED state would win and pin for the full TTL, inverting the
    /// finish edge and mis-firing the F1 push. `applyHookState` never re-enters
    /// SessionManager, so awaiting is deadlock-free.
    @discardableResult
    public func reportHookState(sessionId: UUID, state: AgentDetectedState) async -> Bool {
        guard let managed = sessions[sessionId], !managed.info.state.isTerminal,
              let pty = managed.ptySession else { return false }
        await pty.applyHookState(state)
        return true
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
            callback(sessionId, activity, agent, agentState, title, managed.latestWorkingDir)
        }
        // Token-agnostic fan-out (push dispatcher). Carries the accepted
        // revision so the dispatcher preserves ordering.
        for callback in globalActivityObservers.values {
            callback(sessionId, tokenId, activity, agentState, managed.activityRevision)
        }
    }

    // MARK: - Global Activity Observers

    @discardableResult
    public func addGlobalActivityObserver(_ callback: @escaping GlobalActivityObserver) -> UUID {
        let id = UUID()
        globalActivityObservers[id] = callback
        return id
    }

    public func removeGlobalActivityObserver(id: UUID) {
        globalActivityObservers.removeValue(forKey: id)
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

    /// Evict terminal-state sessions past the grace period. Called periodically
    /// from main.swift.
    ///
    /// The event-driven `purgeTerminalSessions()` calls on the lifecycle paths
    /// are not sufficient on their own: all three fire only when a session is
    /// created, terminated, or exits, so once churn stops the last batch of
    /// terminal sessions is retained indefinitely — each still holding a
    /// `scrollbackSize` `RingBuffer` that `RingBuffer.init` allocates and
    /// zero-fills in full (2 MB per session at the default config), regardless
    /// of how little output the session actually produced. Bounded by
    /// `maxSessionsPerToken`, but that bound is ~100 MB of resident memory held
    /// by an otherwise idle server.
    public func purgeTerminalSessionsNow(gracePeriod: TimeInterval = 300) {
        purgeTerminalSessions(gracePeriod: gracePeriod)
    }

    /// Exposed only for tests. Do not call from production code.
    public var _testOnly_observerCount: Int {
        activityObservers.count + stealObservers.count + renameObservers.count
    }

    /// Exposed only for tests. Do not call from production code.
    public var _testOnly_sessionCount: Int {
        sessions.count
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

    // MARK: - Poll cadence

    /// Sessions with a `syncPollCadence` loop currently running.
    private var cadenceSyncInFlight: Set<UUID> = []

    /// Pushes the foreground-poll cadence implied by the session's **committed
    /// state** to its PTY: 1 s attached, 5 s detached.
    ///
    /// Why this is not simply `await pty.setPollCadence(x)` at each call site.
    /// `setPollCadence` is a cross-actor call, so it suspends, and
    /// `SessionManager` is reentrant — a lifecycle transition can run to
    /// completion while another is parked in that call. Each caller captures the
    /// cadence it wants *before* suspending, so whichever write reaches the PTY
    /// last wins even if its value was derived from state that has since
    /// changed. Ordering the statements cannot fix that: the race is between the
    /// two writes, not the two methods. A tab switch (detach→resume) hitting it
    /// left an *attached* session polling every 5 s — the bug this whole change
    /// set out to fix, reintroduced one level down.
    ///
    /// The fix is that the value is **re-read from committed state after every
    /// suspension** instead of captured once by the caller. Whoever writes last
    /// therefore writes the cadence the last committed transition implies, so the
    /// PTY converges on the right value regardless of arrival order. (That is the
    /// load-bearing part: replacing this re-read with a captured constant
    /// reproduces the original bug — measured, see `SessionPollCadenceTests`.)
    ///
    /// Writes are additionally single-flight per session, which serialises them
    /// and gives one owner responsibility for reaching agreement. It is *not*
    /// what fixes the race — delete the guard and the tests still pass, because
    /// each caller loops on its own. What it does buy is a simple ownership
    /// story: `lastWritten` is this task's own write, and with one writer per
    /// session it is also the PTY's current value, so comparing against it is a
    /// sound exit test rather than an assumption about who else may have written.
    ///
    /// A caller that finds a loop already in flight writes nothing and returns.
    /// That is only safe because it has *already committed its state* before
    /// calling, and the owner re-reads state after every write — so the owner
    /// picks up the skipped caller's transition on its next pass. The loop
    /// therefore exits on **state agreement**, never on a pass count: an earlier
    /// version capped it at 8 passes, which reintroduced the bug at the boundary.
    /// A transition committing during the eighth write returned early on the
    /// guard, then the owner finished its stale write and exhausted the loop
    /// without re-reading, and nothing was left to repair it. Guarded by
    /// `testSyncLoopTakesAsManyPassesAsThereAreTransitions`, which drives more
    /// passes than that cap allowed — the gated reentrancy test drives only two,
    /// so it cannot tell `while true` from any cap >= 2.
    ///
    /// Termination does not need the cap: a further pass only happens when
    /// another task committed a *different* state while this one was suspended,
    /// so the loop stops one pass after lifecycle transitions quiesce. It is not
    /// that transitions are inherently finite — two connections could in
    /// principle alternate detach/resume indefinitely and keep the owner
    /// looping — but that costs nothing worth capping: each pass suspends on the
    /// PTY actor rather than spinning on CPU, overtaking callers return on the
    /// guard instead of accumulating, and the work per pass is exactly the write
    /// the flapping asked for. The terminal paths cannot sustain it either:
    /// `handleDetachTimeout` and `handlePTYExit` are one-way and nil out
    /// `ptySession`, so the owner exits on its next `guard let pty`.
    private func syncPollCadence(id: UUID) async {
        guard !cadenceSyncInFlight.contains(id) else { return }
        cadenceSyncInFlight.insert(id)
        defer { cadenceSyncInFlight.remove(id) }

        var lastWritten: TimeInterval?
        while true {
            guard let managed = sessions[id], let pty = managed.ptySession else { return }
            let desired = managed.info.state == .activeAttached
                ? PTYSession.attachedPollCadence
                : PTYSession.detachedPollCadence
            // Exit only when the PTY already holds what committed state implies.
            if desired == lastWritten { return }
            await pty.setPollCadence(desired)
            lastWritten = desired
        }
    }

    private func handleDetachTimeout(sessionId: UUID) {
        // Drop the entry first, unconditionally: this timer has fired, so it is
        // spent whether or not the session is still expirable. Both guards below
        // used to return with the entry still populated, so a timer that fired
        // against an already-attached session leaked its slot forever. Safe to
        // remove before the guards because a fired timer is never reusable, and
        // any later detach installs a fresh one.
        detachTimers.removeValue(forKey: sessionId)

        guard var managed = sessions[sessionId] else { return }
        let currentState = managed.info.state
        guard currentState.canTransition(to: .expired) else { return }

        managed.info = managed.info.transitioning(to: .expired)
        managed.terminalSince = Date()
        sessions[sessionId] = managed

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
