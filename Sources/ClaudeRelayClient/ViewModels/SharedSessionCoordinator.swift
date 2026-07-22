import Foundation
import Combine
import os.log
import ClaudeRelayKit

private let recoveryLog = Logger(subsystem: "com.claude.relay.client", category: "Recovery")

@MainActor
open class SharedSessionCoordinator: ObservableObject, SessionCoordinating {

    // MARK: - Published State

    @Published public var sessions: [SessionInfo] = []
    @Published public var activeSessionId: UUID?
    @Published public var sessionNames: [UUID: String] = [:]
    @Published public var terminalTitles: [UUID: String] = [:]
    @Published public var isLoading = false

    /// Live agent / awaiting-input / stolen-session state. Extracted into its
    /// own object so the server-event fan-in (activity, stolen, rename) is
    /// self-contained and independently testable. Views that need to bind
    /// against the stolen-session alert reach through
    /// `coordinator.activityCoordinator.showSessionStolen`; reads of
    /// `agentSessions` / `sessionsAwaitingInput` are available via the
    /// read-only forwarders below.
    public let activityCoordinator: ActivityCoordinator

    /// Read-through to `activityCoordinator.agentSessions`. Provided so the
    /// `SessionCoordinating` protocol, sidebar views, and existing tests
    /// keep the same `coordinator.agentSessions` access pattern.
    public var agentSessions: [UUID: String] {
        get { activityCoordinator.agentSessions }
        set { activityCoordinator.agentSessions = newValue }
    }

    /// Read-through to `activityCoordinator.sessionsAwaitingInput`.
    public var sessionsAwaitingInput: Set<UUID> {
        get { activityCoordinator.sessionsAwaitingInput }
        set { activityCoordinator.sessionsAwaitingInput = newValue }
    }

    /// Read-through to the stolen-session UI flags. Setters are provided so
    /// `WorkspaceView`'s `.alert(..., isPresented: $coordinator...)` can
    /// reset the flag on dismiss if it chooses to bind through the parent.
    /// (New views should prefer `$coordinator.activityCoordinator...`.)
    public var stolenSessionName: String? {
        get { activityCoordinator.stolenSessionName }
        set { activityCoordinator.stolenSessionName = newValue }
    }
    public var stolenSessionShortId: String? {
        get { activityCoordinator.stolenSessionShortId }
        set { activityCoordinator.stolenSessionShortId = newValue }
    }
    public var showSessionStolen: Bool {
        get { activityCoordinator.showSessionStolen }
        set { activityCoordinator.showSessionStolen = newValue }
    }
    public enum RecoveryPhase {
        case reconnecting, authenticating, resuming

        public var label: String {
            switch self {
            case .reconnecting:   return "Reconnecting to server…"
            case .authenticating:  return "Authenticating…"
            case .resuming:       return "Restoring session…"
            }
        }
    }

    @Published public var isRecovering = false
    @Published public var recoveryPhase: RecoveryPhase = .reconnecting
    @Published public internal(set) var recoveryFailed = false
    @Published public var errorMessage: String?
    @Published public var showError = false
    /// True when recovery could not restore the connection itself (reconnect attempts
    /// all failed). Distinct from `sessionAttachFailed`, which covers the case where
    /// the connection is fine but the session is gone or unusable on the server.
    @Published public var connectionTimedOut = false
    /// True when an attach/resume failed for application-level reasons (session gone, ownership,
    /// server-side error) rather than because the underlying connection is dead. The UI should
    /// surface this as a recoverable error instead of dismissing the workspace.
    @Published public var sessionAttachFailed = false
    @Published public var sessionAttachError: String?

    /// Subscription that republishes `activityCoordinator.objectWillChange`
    /// onto this parent so SwiftUI views observing the parent `@ObservedObject`
    /// re-render when agent / awaiting-input / stolen state changes.
    private var activityObjectWillChangeSubscription: AnyCancellable?

    /// Must be `@Published`: `activeSessions` (the sidebar + tab-bar data
    /// source) filters `sessions` by this set, so a change here has to trigger
    /// a SwiftUI re-render. When it wasn't published, unclaiming a stolen
    /// session mutated only this set — no `objectWillChange` fired — so the
    /// lost session lingered in the sidebar/tab bar until the next
    /// `fetchSessions` happened to reassign `sessions`.
    @Published public private(set) var ownedSessionIds: Set<UUID> = []

    public var activeSessions: [SessionInfo] {
        sessions
            .filter { !$0.state.isTerminal && ownedSessionIds.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Dependencies

    public let connection: RelayConnection
    public let token: String
    /// Owns the auth surface (single-flight authTask, SessionController
    /// instance, withAuth retry helper). See `AuthCoordinator`.
    public let authCoordinator: AuthCoordinator
    public var sessionController: SessionController? {
        get { authCoordinator.sessionController }
        set { authCoordinator.sessionController = newValue }
    }
    public var terminalViewModels: [UUID: TerminalViewModel] = [:]
    /// Best-known terminal geometry from the most recent resize on any session.
    /// Seeds `session_create` so the PTY forks at the right width. `nil` until
    /// the first terminal has been laid out.
    public private(set) var lastKnownTerminalSize: (cols: UInt16, rows: UInt16)?
    public var recoveryTask: Task<Void, Never>?
    public var isTornDown = false
    /// UserDefaults persistence for sessionNames / ownedSessionIds /
    /// agentSessions. Diff-checks before writing; coordinator keeps the
    /// @Published mirrors for SwiftUI binding.
    private let ownershipStore: SessionOwnershipStore
    private var lastFetchTime: Date = .distantPast
    private var networkMonitor: NetworkMonitor?
    private var networkObserver: NSObjectProtocol?
    /// LRU-bounded cache of native terminal views (NSView on macOS, UIView on
    /// iOS). Kept alive across session switches so SwiftTerm's internal
    /// scrollback persists across tab-like navigation. The coordinator owns
    /// this cache; platform hosts look up or install entries via
    /// `registerLiveTerminal(for:view:)` / `cachedTerminalView(for:)`.
    ///
    /// Limit: 8 — beyond this, the least-recently-used entry is evicted, and
    /// that session's next resume replays from the server's ring buffer.
    public let terminalCache = TerminalCache(limit: 8)

    // MARK: - Recovery Control
    //
    // The recovery state machine (breaker, generations, cooldown, backoff
    // loop, restoreSession) lives on `recoveryController`. This coordinator
    // owns the `@Published` recovery UI flags and the `recoveryTask` slot so
    // SwiftUI bindings still live next to the properties they depend on.

    /// Owns the auto-recovery circuit breaker, generation tokens, and the
    /// reconnect + restore flow. Installed in `init` once the coordinator's
    /// required fields are populated.
    private(set) var recoveryController: RecoveryController!

    // MARK: - Subclass Hooks

    open class var keyPrefix: String { "com.clauderelay" }

    open func sessionNamingTheme() -> SessionNamingTheme { .gameOfThrones }

    open func didAuthenticate() {}

    public func startNetworkRecovery() {
        guard networkMonitor == nil else { return }
        let monitor = NetworkMonitor()
        networkMonitor = monitor
        networkObserver = NotificationCenter.default.addObserver(
            forName: NetworkMonitor.connectivityRestored,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerUserRecovery()
            }
        }
    }

    private func stopNetworkRecovery() {
        if let obs = networkObserver {
            NotificationCenter.default.removeObserver(obs)
            networkObserver = nil
        }
        networkMonitor = nil
    }

    // MARK: - Init

    public init(connection: RelayConnection, token: String) {
        self.connection = connection
        self.token = token
        self.authCoordinator = AuthCoordinator(connection: connection, token: token)
        let store = SessionOwnershipStore(
            keyPrefix: Self.keyPrefix,
            deviceId: DeviceIdentifier().currentID
        )
        self.ownershipStore = store
        sessionNames = store.loadNames()
        ownedSessionIds = store.loadOwned()
        self.activityCoordinator = ActivityCoordinator(
            ownershipStore: store,
            initialAgents: store.loadAgents()
        )

        // Forward the auth coordinator's hook to the subclass `didAuthenticate`
        // override so the Mac app's `isAuthenticated` @Published flag still
        // flips.
        authCoordinator.onAuthenticated = { [weak self] in
            self?.didAuthenticate()
        }

        // Install the recovery controller now that all required fields are
        // populated. `self` is fully initialized from Swift's perspective;
        // the controller's `unowned` ref is safe for the lifetime of the
        // coordinator (the controller is stored here).
        self.recoveryController = RecoveryController(coordinator: self, connection: connection)

        // Views observe this parent via @ObservedObject / @StateObject. The
        // activity cluster is a nested ObservableObject, so re-emit its
        // will-change to keep parent observers in sync without forcing every
        // view to also observe the child.
        self.activityObjectWillChangeSubscription = activityCoordinator.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        connection.onReplayComplete = { [weak self] sessionId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.terminalViewModels[sessionId]?.endReplay()
            }
        }
        connection.onSessionActivity = { [weak self] sessionId, activity, agent, agentState, title, workingDir in
            Task { @MainActor [weak self] in
                self?.handleActivityUpdate(sessionId: sessionId, activity: activity, agent: agent,
                                           agentState: agentState, title: title, workingDir: workingDir)
            }
        }
        connection.onSessionStolen = { [weak self] sessionId in
            Task { @MainActor [weak self] in
                self?.handleSessionStolen(sessionId: sessionId)
            }
        }
        connection.onSessionRenamed = { [weak self] sessionId, name in
            Task { @MainActor [weak self] in
                self?.handleSessionRenamed(sessionId: sessionId, name: name)
            }
        }
        connection.onSendFailed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.recoveryController.scheduleAutoRecovery()
            }
        }
        // Reset the auto-recovery circuit breaker on any healthy keepalive
        // ping so a transient outage followed by real recovery doesn't leave
        // the breaker armed against the next unrelated failure.
        connection.onHealthyPing = { [weak self] in
            Task { @MainActor [weak self] in
                self?.recoveryController.resetAutoRecoveryBreaker()
            }
        }
    }

    /// Explicit user-initiated recovery: foreground, network restored, QR
    /// rescan, etc. Delegates to `RecoveryController`.
    public func triggerUserRecovery() {
        recoveryController.triggerUserRecovery()
    }

    // MARK: - Names

    public func name(for id: UUID) -> String {
        sessionNames[id] ?? id.uuidString.prefix(8).description
    }

    public func setName(_ name: String, for id: UUID) {
        sessionNames[id] = name
        ownershipStore.saveNames(sessionNames)
        Task {
            try? await sessionController?.renameSession(id: id, name: name)
        }
    }

    public func pickDefaultName() -> String {
        SessionNaming.pickDefaultName(
            usedNames: Set(sessionNames.values),
            theme: sessionNamingTheme(),
            fallbackIndex: sessionNames.count + 1
        )
    }

    // MARK: - Persistence
    //
    // Delegated to `SessionOwnershipStore`. The @Published dictionaries
    // stay on the coordinator for SwiftUI binding; the store handles the
    // UserDefaults encoding and diff-checked writes (C-21).

    // MARK: - Ownership

    public func claimSession(_ id: UUID) {
        guard !ownedSessionIds.contains(id) else { return }
        ownedSessionIds.insert(id)
        ownershipStore.saveOwned(ownedSessionIds)
    }

    public func unclaimSession(_ id: UUID) {
        ownedSessionIds.remove(id)
        ownershipStore.saveOwned(ownedSessionIds)
    }

    // MARK: - Auth (forwarders into AuthCoordinator)

    public func ensureAuthenticated() async throws -> SessionController {
        try await authCoordinator.ensureAuthenticated()
    }

    /// Runs a closure that requires an authenticated controller. If the server
    /// replies "Not authenticated" (stale auth), resets auth and retries once.
    public func withAuth<T>(_ body: (SessionController) async throws -> T) async throws -> T {
        try await authCoordinator.withAuth(body)
    }

    // MARK: - Session List

    public func fetchSessions() async {
        let now = Date()
        guard now.timeIntervalSince(lastFetchTime) >= 0.5 else { return }
        lastFetchTime = now

        isLoading = true
        defer { isLoading = false }

        do {
            sessions = try await withAuth { try await $0.listSessions() }

            for session in sessions {
                if let serverName = session.name {
                    sessionNames[session.id] = serverName
                }
            }
            // Diff-checked inside the store — no UserDefaults write when the
            // names dictionary is unchanged since the last save (C-21).
            ownershipStore.saveNames(sessionNames)

            for session in sessions {
                let activity = session.activity ?? .idle
                handleActivityUpdate(sessionId: session.id, activity: activity, agent: session.agent,
                                     agentState: session.agentState, title: session.title)
            }

            let serverIds = Set(sessions.map { $0.id })

            // Snapshot BEFORE the prune below: any owned session missing from
            // this token's list was lost (moved to another device or
            // terminated). We capture it now because `pruneToServerSessions`
            // unclaims these, which would otherwise defeat the ownership guard
            // in `cleanUpStolenSession`. Classified into moved-vs-terminated
            // after the prune (see below).
            let lostOwned = ownedSessionIds.subtracting(serverIds)

            // Prune names/owned/agents in one pass through the store. Each
            // `save*` inside `pruneToServerSessions` no-ops when nothing was
            // stale, so this does not churn UserDefaults (C-21).
            //
            // `agentSessions` is a computed forwarder onto `activityCoordinator`
            // and can't be passed as `inout` directly — round-trip via a
            // local so the prune + save path stays intact.
            var agentsScratch = activityCoordinator.agentSessions
            let pruned = ownershipStore.pruneToServerSessions(
                serverIds: serverIds,
                names: &sessionNames,
                owned: &ownedSessionIds,
                agents: &agentsScratch
            )
            activityCoordinator.agentSessions = agentsScratch
            activityCoordinator.applyPrunedAgents(pruned.removedAgents)
            // Evict cached terminal views for sessions that no longer exist
            // on the server (exited, terminated elsewhere, server restarted).
            terminalCache.pruneStale(knownSessionIds: serverIds)
            // Keep terminalViewModels in sync with the cache's evictions above.
            let cachedNow = terminalCache.cachedIds
            let staleVMs = Set(terminalViewModels.keys).subtracting(serverIds).subtracting(cachedNow)
            for id in staleVMs { terminalViewModels.removeValue(forKey: id) }

            // Reconcile EVERY lost owned session (not just the active one):
            // belt-and-suspenders for a missed real-time `session_stolen` push
            // — e.g. the theft happened while this device was disconnected, so
            // it's only discovered now on reconnect. Distinguish "moved to
            // another device" (still alive on the server under a different
            // token → alert the user) from "terminated" (gone everywhere →
            // clean up silently) via the token-agnostic all-sessions list. If
            // that RPC fails we can't classify, so stay silent to avoid a false
            // "moved" alert for a session that was actually terminated.
            if !lostOwned.isEmpty {
                let aliveElsewhere: Set<UUID>
                if let all = try? await withAuth({ try await $0.listAllSessions() }) {
                    aliveElsewhere = Set(all.filter { !$0.state.isTerminal }.map { $0.id })
                } else {
                    aliveElsewhere = []
                }
                for id in lostOwned {
                    // Re-claim first so `cleanUpStolenSession`'s ownership guard
                    // passes even though the prune above already unclaimed it.
                    // `refetch: false` — we're already inside `fetchSessions`.
                    claimSession(id)
                    cleanUpStolenSession(id, alert: aliveElsewhere.contains(id), refetch: false)
                }
            }
        } catch {
            // Non-critical refresh.
        }
    }

    // MARK: - Access

    public func viewModel(for sessionId: UUID) -> TerminalViewModel? {
        terminalViewModels[sessionId]
    }

    public func createdAt(for sessionId: UUID) -> Date? {
        sessions.first { $0.id == sessionId }?.createdAt
    }

    public func activeAgent(for sessionId: UUID) -> String? {
        activityCoordinator.activeAgent(for: sessionId)
    }

    public func isRunningAgent(sessionId: UUID) -> Bool {
        activityCoordinator.isRunningAgent(sessionId: sessionId)
    }

    /// Derive the `ActivityState` for a session. Convenience helper used by
    /// sidebar views on both platforms — keeps the agent/awaiting-input
    /// resolution in one place.
    public func activityState(for sessionId: UUID) -> ActivityState {
        activityCoordinator.activityState(for: sessionId)
    }

    /// Fine-grained agent state for a session (Phase 2), or nil.
    public func agentState(for sessionId: UUID) -> AgentDetectedState? {
        activityCoordinator.agentState(for: sessionId)
    }

    /// Window title for a session, or nil.
    public func title(for sessionId: UUID) -> String? {
        activityCoordinator.title(for: sessionId)
    }

    /// Whether a session has an unacknowledged blocked/done state.
    public func isUnseen(_ sessionId: UUID) -> Bool {
        activityCoordinator.unseenSessions.contains(sessionId)
    }

    // MARK: - Create

    public func createNewSession() async {
        guard !isRecovering else { return }
        let previousId = activeSessionId
        do {
            let (name, sessionId) = try await withAuth { controller in
                if previousId != nil {
                    try? await controller.detach()
                }
                let name = self.pickDefaultName()
                let size = self.lastKnownTerminalSize
                let sessionId = try await controller.createSession(
                    name: name, cols: size?.cols, rows: size?.rows
                )
                return (name, sessionId)
            }

            if let currentId = previousId {
                terminalViewModels[currentId]?.prepareForSwitch()
                terminalViewModels[currentId] = nil
            }

            claimSession(sessionId)
            sessionNames[sessionId] = name
            ownershipStore.saveNames(sessionNames)

            let vm = TerminalViewModel(sessionId: sessionId, connection: connection)
            terminalViewModels[sessionId] = vm
            wireTerminalOutput(to: sessionId)
            activeSessionId = sessionId
            activityCoordinator.markSeen(sessionId)
            terminalCache.touch(sessionId)
            terminalCache.enforceLimit(activeSessionId: activeSessionId)

            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Switch

    public func switchToSession(id: UUID) async {
        guard !isRecovering, id != activeSessionId else { return }
        let previousId = activeSessionId
        do {
            if let currentId = previousId, currentId != id {
                terminalViewModels[currentId]?.prepareForSwitch()
            }

            // Prepare the incoming VM and wire output BEFORE resumeSession so
            // binary replay frames are routed to the correct VM from the start.
            if terminalViewModels[id] == nil {
                terminalViewModels[id] = TerminalViewModel(sessionId: id, connection: connection)
            } else {
                terminalViewModels[id]?.prepareForReplay()
            }
            terminalViewModels[id]?.beginReplay()
            wireTerminalOutput(to: id)

            try await withAuth { controller in
                if previousId != nil {
                    try? await controller.detach()
                }
                try await controller.resumeSession(id: id, skipReplay: false)
            }

            activeSessionId = id
            activityCoordinator.markSeen(id)
            terminalCache.touch(id)
            terminalCache.enforceLimit(activeSessionId: activeSessionId)

            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Attach

    /// Lists sessions running on the server that this device isn't already
    /// showing, so they can be attached from another device. Filter by the
    /// TOKEN-SCOPED `sessions` (what the sidebar shows now), NOT `ownedSessionIds`:
    /// the owned set is sticky — a session this device once attached but that has
    /// since moved to another device lingers in `ownedSessionIds`, so filtering
    /// by it hid every such session (neither in the sidebar nor offered for
    /// attach: invisible AND unattachable). That was the bug.
    public func fetchAttachableSessions() async -> [SessionInfo] {
        do {
            let all = try await withAuth { try await $0.listAllSessions() }
            let shownIds = Set(sessions.map { $0.id })
            return all.filter { session in
                !session.state.isTerminal && !shownIds.contains(session.id)
            }
        } catch {
            return []
        }
    }

    public func attachRemoteSession(id: UUID, serverName: String? = nil) async {
        guard !isRecovering else { return }
        let previousId = activeSessionId
        do {
            let controller = try await withAuth { controller in
                if previousId != nil {
                    try? await controller.detach()
                }
                try await controller.attachSession(id: id)
                return controller
            }

            if let currentId = previousId, currentId != id {
                terminalViewModels[currentId]?.prepareForSwitch()
                terminalViewModels[currentId] = nil
            }

            claimSession(id)
            let vm = TerminalViewModel(sessionId: id, connection: connection)
            vm.beginReplay()
            terminalViewModels[id] = vm
            wireTerminalOutput(to: id)
            activeSessionId = id
            activityCoordinator.markSeen(id)
            terminalCache.touch(id)
            terminalCache.enforceLimit(activeSessionId: activeSessionId)

            if let serverName {
                sessionNames[id] = serverName
                ownershipStore.saveNames(sessionNames)
            } else if sessionNames[id] == nil {
                let name = pickDefaultName()
                sessionNames[id] = name
                ownershipStore.saveNames(sessionNames)
                try? await controller.renameSession(id: id, name: name)
            }

            await fetchSessions()
        } catch {
            recoveryLog.error("attachRemoteSession failed for \(id): \(error.localizedDescription, privacy: .public)")
            if let previousId {
                try? await sessionController?.resumeSession(id: previousId)
                wireTerminalOutput(to: previousId)
            }
            if Self.isApplicationLevelError(error) {
                if case SessionController.SessionError.authenticationFailed = error {
                    recoveryController?.markAuthRejected()
                }
                sessionAttachError = friendlyAttachErrorMessage(error)
                sessionAttachFailed = true
            } else {
                presentError(error.localizedDescription)
            }
        }
    }

    static func isApplicationLevelError(_ error: Error) -> Bool {
        if let sessionErr = error as? SessionController.SessionError {
            switch sessionErr {
            case .unexpectedResponse, .authenticationFailed, .versionIncompatible:
                return true
            case .timeout:
                return false
            }
        }
        if let connErr = error as? RelayConnection.ConnectionError {
            switch connErr {
            case .invalidMessage:
                return true
            case .notConnected, .encodingFailed:
                return false
            }
        }
        return false
    }

    func friendlyAttachErrorMessage(_ error: Error) -> String {
        if let sessionErr = error as? SessionController.SessionError,
           case .authenticationFailed = sessionErr {
            return "Access token rejected. This server's token is no longer "
                + "valid — edit the server to re-pair it."
        }
        if let sessionErr = error as? SessionController.SessionError,
           case .unexpectedResponse(let detail) = sessionErr {
            if detail.localizedCaseInsensitiveContains("not found") {
                return "This session no longer exists on the server."
            }
            if detail.localizedCaseInsensitiveContains("invalid") || detail.localizedCaseInsensitiveContains("terminal") {
                return "This session has ended and cannot be reattached."
            }
            if detail.localizedCaseInsensitiveContains("no session attached") ||
               detail.localizedCaseInsensitiveContains("not authenticated") {
                return "The session couldn't be restored. Please try reconnecting."
            }
            return detail
        }
        return error.localizedDescription
    }

    // MARK: - Terminate

    open func terminateSession(id: UUID) async {
        guard !isRecovering else { return }
        do {
            try await connection.send(.sessionTerminate(sessionId: id))
            if activeSessionId == id {
                activeSessionId = nil
            }
            evictTerminal(for: id)
            activityCoordinator.forgetSession(id)
            unclaimSession(id)
            sessionNames.removeValue(forKey: id)
            terminalTitles.removeValue(forKey: id)
            ownershipStore.saveNames(sessionNames)
            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Activity / Steal / Rename Handlers
    //
    // Fan-in from the server. Mutation of activity/stolen state lives on
    // `ActivityCoordinator`; the parent only owns the pieces outside that
    // cluster (active-session slot, terminal cache, session names).

    private func handleActivityUpdate(
        sessionId: UUID, activity: ActivityState, agent: String? = nil,
        agentState: AgentDetectedState? = nil, title: String? = nil, workingDir: String? = nil
    ) {
        // Live cwd updates (e.g. after `cd`) arrive on the activity channel;
        // patch the cached SessionInfo so the grouped sidebar regroups without
        // waiting for a full session-list refetch.
        if let workingDir, let idx = sessions.firstIndex(where: { $0.id == sessionId }),
           sessions[idx].workingDir != workingDir {
            sessions[idx] = sessions[idx].enriched(
                activity: sessions[idx].activity, agent: sessions[idx].agent,
                agentState: sessions[idx].agentState, title: sessions[idx].title,
                workingDir: workingDir)
        }
        activityCoordinator.handleActivityUpdate(
            sessionId: sessionId,
            activity: activity,
            agent: agent,
            agentState: agentState,
            title: title,
            isActiveSession: sessionId == activeSessionId,
            onAgentActiveChange: { [weak self] id, isActive in
                self?.terminalViewModels[id]?.isAgentActive = isActive
            }
        )
    }

    private func handleSessionStolen(sessionId: UUID) {
        // Only act on sessions this device still thinks it owns — otherwise a
        // duplicate/late steal push (or the reconciliation backstop that also
        // calls this) would re-raise the alert for an already-handled session.
        guard ownedSessionIds.contains(sessionId) || activeSessionId == sessionId else { return }
        cleanUpStolenSession(sessionId)
    }

    /// Removes a session that was lost to another device and (optionally)
    /// surfaces the "Session Moved" alert. Ordering matches the product spec:
    /// the session vanishes from the sidebar + tab bar FIRST (clear
    /// `activeSessionId`, unclaim → drops out of `activeSessions`, evict the
    /// terminal), THEN the alert is raised — so when the user taps OK the UI is
    /// already clean. Fires for ANY lost session, not just the active one.
    ///
    /// - Parameters:
    ///   - alert: raise the "moved to another device" popup. True for the live
    ///     `session_stolen` push (the server only sends it for a genuine
    ///     cross-device attach). The reconnect reconciliation passes `false`
    ///     for sessions that are gone everywhere (terminated) and `true` only
    ///     for those still alive under another token (actually moved).
    ///   - refetch: re-run `fetchSessions` afterward. False when called from
    ///     inside `fetchSessions` to avoid re-entrancy.
    func cleanUpStolenSession(_ sessionId: UUID, alert: Bool = true, refetch: Bool = true) {
        let stolenName = name(for: sessionId)

        // 1) Remove from the UI first.
        if activeSessionId == sessionId {
            activeSessionId = nil
        }
        terminalViewModels[sessionId]?.isSendingSuppressed = true
        activityCoordinator.forgetSession(sessionId)
        unclaimSession(sessionId)          // @Published → sidebar/tab re-render
        evictTerminal(for: sessionId)

        // 2) Then raise the alert (OK-only). ActivityCoordinator owns the flag.
        if alert {
            activityCoordinator.presentStolenAlert(sessionId: sessionId, name: stolenName)
        }

        if refetch { Task { await fetchSessions() } }
    }

    private func handleSessionRenamed(sessionId: UUID, name: String) {
        sessionNames[sessionId] = name
        ownershipStore.saveNames(sessionNames)
    }

    // MARK: - Wire Output (subclasses may override to add platform callbacks)

    open func wireTerminalOutput(to sessionId: UUID) {
        if agentSessions[sessionId] != nil {
            terminalViewModels[sessionId]?.isAgentActive = true
        }
        connection.onTerminalOutput = { [weak self] data in
            self?.terminalViewModels[sessionId]?.receiveOutput(data)
        }
        terminalViewModels[sessionId]?.onTitleChanged = { [weak self] title in
            self?.terminalTitles[sessionId] = title
        }
        terminalViewModels[sessionId]?.onResize = { [weak self] cols, rows in
            self?.lastKnownTerminalSize = (cols, rows)
        }
    }

    // MARK: - Terminal View Cache (thin forwarders over TerminalCache)

    /// Called by the platform host when it creates (or retrieves) a native
    /// terminal view for a session, so the cache can reuse it on switch.
    public func registerLiveTerminal(for sessionId: UUID, view: AnyObject) {
        terminalCache.register(view: view, for: sessionId, activeSessionId: activeSessionId)
    }

    /// Lookup the cached native view for a session, if any.
    public func cachedTerminalView(for sessionId: UUID) -> AnyObject? {
        terminalCache.view(for: sessionId)
    }

    /// Drop all cached state tied to a single session. Used when a session is
    /// terminated, stolen, or the workspace is torn down.
    public func evictTerminal(for sessionId: UUID) {
        terminalCache.evict(sessionId)
        terminalViewModels.removeValue(forKey: sessionId)
    }

    public func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }

    func suppressAllViewModelSends(_ suppress: Bool) {
        for (_, vm) in terminalViewModels {
            vm.isSendingSuppressed = suppress
        }
    }

    // MARK: - Recovery

    public func handleForegroundTransition() async {
        await recoveryController.handleForegroundTransition(userInitiated: true)
    }

    /// - Parameter userInitiated: true when triggered by an explicit
    ///   user-intent signal (scenePhase active, network restored, manual
    ///   retry). Delegates to `RecoveryController`.
    public func handleForegroundTransition(userInitiated: Bool) async {
        await recoveryController.handleForegroundTransition(userInitiated: userInitiated)
    }

    /// Delegates to `RecoveryController`. Exposed publicly because the Mac
    /// app's recovery sheet calls this path.
    public func restoreSession(generation: UInt64, userInitiated: Bool) async {
        await recoveryController.restoreSession(generation: generation, userInitiated: userInitiated)
    }

    /// Cancels any in-flight recovery and clears recovery UI state.
    public func cancelRecovery() {
        recoveryController.cancel()
    }

    // MARK: - Cleanup

    open func tearDown() {
        isTornDown = true
        recoveryController.invalidate()
        stopNetworkRecovery()
        recoveryTask?.cancel()
        recoveryTask = nil
        authCoordinator.invalidate()
        if activeSessionId != nil {
            Task {
                do {
                    try await sessionController?.detach()
                } catch {
                    recoveryLog.debug("Detach during teardown: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        terminalCache.removeAll()
        connection.disconnect()
    }

    // MARK: - Test Hooks

    /// Expose the auto-recovery breaker state so unit tests can verify that
    /// a healthy ping clears it. Forwards to `RecoveryController`.
    public var _testOnly_autoRecoverySuspended: Bool {
        recoveryController._testOnly_autoRecoverySuspended
    }
    public var _testOnly_consecutiveAutoRecoveryFailures: Int {
        recoveryController._testOnly_consecutiveAutoRecoveryFailures
    }

    /// Force the breaker into the suspended state for tests that exercise
    /// the onHealthyPing → reset path without having to trip three
    /// auto-recovery failures first.
    public func _testOnly_setAutoRecoverySuspended(_ suspended: Bool, failures: Int) {
        recoveryController._testOnly_setAutoRecoverySuspended(suspended, failures: failures)
    }
}
