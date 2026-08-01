import Foundation
import Combine
import os.log
import ClaudeRelayKit

private let recoveryLog = Logger(subsystem: "com.claude.relay.client", category: "Recovery")

@MainActor
open class SharedSessionCoordinator: ObservableObject, SessionCoordinating {

    // MARK: - Published State

    @Published public var sessions: [SessionInfo] = []
    @Published public var activeSessionId: UUID? {
        didSet {
            // F3: persist the focused tab per-device so relaunch restores it.
            // Restore goes through switchToSession (which sets this to the
            // persisted value), so the resulting save is a diff-checked no-op —
            // no suppression flag needed.
            guard activeSessionId != oldValue else { return }
            ownershipStore.saveActiveSession(activeSessionId)
        }
    }
    /// F3: the active session is restored from persistence exactly once, on the
    /// first successful session fetch — not on every reconnect (which would
    /// fight the user's live selection).
    private var didRestoreActiveSession = false
    /// F3: holds the restore-through-switchToSession task so it isn't run
    /// synchronously inside `fetchSessions` (switchToSession calls fetchSessions
    /// at its end; the throttle guard makes the nested call a no-op, but
    /// deferring keeps the two flows cleanly separated).
    private var restoreActiveTask: Task<Void, Never>?
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
    /// True while the connect → authenticate → list-owned-sessions handshake is
    /// running. Owned by `SessionHandshake`; read by `RecoveryController`, which
    /// refuses to reconnect while it is set (recovery replacing the socket
    /// mid-handshake is what left the pane empty on relaunch). Views may bind to
    /// it to show a "loading sessions" affordance.
    @Published public internal(set) var isPerformingHandshake = false
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

    /// The sidebar + tab-bar data source. The SERVER is authoritative for
    /// ownership: `sessions` is the token-scoped `listSessions()` result — i.e.
    /// exactly the sessions this token owns — so the pane renders it directly,
    /// filtered only to drop terminal sessions. There is NO client-persisted
    /// owned set: a session leaves the pane precisely when the server stops
    /// listing it under this token (it was attached by another client, or
    /// terminated). This removes the whole class of "empty pane on relaunch"
    /// bugs that a local, device-scoped ownership cache kept reintroducing.
    public var activeSessions: [SessionInfo] {
        sessions
            .filter { !$0.state.isTerminal }
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
    /// UserDefaults persistence for the device-independent auxiliary maps
    /// (sessionNames / agentSessions) and F3 layout state. Ownership is NOT
    /// persisted — the server's token-scoped list is authoritative. Diff-checks
    /// before writing; the coordinator keeps @Published mirrors for SwiftUI.
    private let ownershipStore: SessionOwnershipStore
    private var lastFetchTime: Date = .distantPast
    /// Single-flight guard for `fetchSessions` — concurrent callers await the
    /// one in-flight fetch instead of issuing parallel `listSessions` RPCs
    /// (whose type-matched replies could cross-deliver).
    private var isFetchingSessions = false
    private var inFlightSessionsFetch: Task<Void, Never>?
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

    /// Owns the connect → authenticate → list-owned-sessions sequence that
    /// populates the pane. Single-flight and retrying; see `SessionHandshake`.
    private(set) var handshake: SessionHandshake!

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
        self.handshake = SessionHandshake(coordinator: self, connection: connection)

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
        connection.onClipboardUpdate = { sessionId, text in
            // F11: mirror an OSC 52 terminal clipboard write to the device
            // clipboard. Only for the session the user is looking at, so a
            // background session's copy can't silently hijack the pasteboard.
            Task { @MainActor [weak self] in
                guard self?.activeSessionId == sessionId else { return }
                DeviceClipboard.setString(text)
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

    /// **The** way the session pane is populated: open the socket →
    /// authenticate → ask the server which sessions this client owns → render
    /// them. Single-flight, retrying, and never silently swallowed. Call it
    /// unconditionally on every entry into the workspace — cold launch,
    /// foreground, wake, network restore.
    ///
    /// - Parameter reason: `.launch` stays silent about sessions another client
    ///   took while this app was closed; `.wake` announces them (the live
    ///   `session_stolen` push was missed while the socket was down).
    /// - Returns: true once the pane reflects the server's list. Owning zero
    ///   sessions is a success, not a failure.
    @discardableResult
    public func performHandshake(reason: SessionHandshake.Reason) async -> Bool {
        await handshake.perform(reason: reason)
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

    // MARK: - Sidebar layout (F3)

    /// Load the persisted collapsed workspace-group ids (per-device). Sidebar
    /// views seed their `SidebarCollapseModel` from this at appear time so the
    /// collapse layout survives relaunch.
    public func loadCollapsedGroups() -> Set<String> {
        ownershipStore.loadCollapsedGroups()
    }

    /// Persist the collapsed workspace-group ids after a toggle (per-device,
    /// diff-checked).
    public func saveCollapsedGroups(_ groups: Set<String>) {
        ownershipStore.saveCollapsedGroups(groups)
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

    /// Reconciles this device's push registration with the OS token, the
    /// notification permission, and the app's push settings, then sends the
    /// appropriate wire message. Idempotent — safe to call on auth, on a
    /// settings change, or when the OS vends a token. No-ops when disconnected.
    public func syncPushRegistration(pushEnabled: Bool, notifyOnFinished: Bool) async {
        let bridge = PushTokenBridge.shared
        let action = PushRegistrationController.decide(
            permissionGranted: bridge.permissionGranted ?? false,
            deviceToken: bridge.deviceToken,
            connected: connection.state == .connected,
            pushEnabledSetting: pushEnabled,
            notifyOnFinished: notifyOnFinished)

        let deviceId = DeviceIdentifier().currentID
        do {
            switch action {
            case .register(let enabled, let notify):
                guard let token = bridge.deviceToken else { return }
                try await connection.send(.registerPushToken(
                    platform: .apns, token: token, deviceId: deviceId,
                    enabled: enabled, notifyOnFinished: notify,
                    topic: Bundle.main.bundleIdentifier))
            case .unregister:
                try await connection.send(.unregisterPushToken(deviceId: deviceId))
            case .noop:
                break
            }
        } catch {
            // Registration is best-effort; a failed send is retried on the next
            // sync trigger (reconnect / settings change / token arrival).
        }
    }

    public func fetchSessions(force: Bool = false) async {
        // 0.5 s debounce. `force` bypasses it for post-mutation fetches
        // (create / attach / switch / stolen-cleanup). The debounce only exists
        // to avoid refresh churn — it must NEVER suppress a fetch while the pane
        // is EMPTY, or a launch/foreground fetch that races another (e.g. a
        // recovery pass that swapped the socket mid-flight) can leave the pane
        // permanently blank until the user forces a refresh by attaching. So a
        // fetch always proceeds when `sessions` is empty; there is nothing to
        // protect from churn in that state.
        let now = Date()
        if !force && !sessions.isEmpty {
            guard now.timeIntervalSince(lastFetchTime) >= 0.5 else { return }
        }

        // Single-flight: never issue two `listSessions` in parallel — their
        // replies are matched by response TYPE (no request ids), so overlapping
        // calls could cross-deliver. Launch fires several fetches
        // near-simultaneously (WorkspaceView `.task`, scenePhase→foreground,
        // recovery), so this is a real window.
        //
        // A NON-forced caller coalesces: it just awaits the in-flight fetch and
        // returns (any fetch satisfies "refresh the list"). A FORCED caller
        // (create / attach / switch / stolen-cleanup) needs a result that
        // reflects ITS mutation, so it must NOT adopt an in-flight fetch that
        // may have started before the mutation — it awaits the in-flight one to
        // clear, then runs its own fresh fetch.
        while isFetchingSessions {
            await inFlightSessionsFetch?.value
            if !force { return }
        }
        isFetchingSessions = true
        lastFetchTime = now
        isLoading = true

        let task = Task { [weak self] in
            defer {
                self?.isLoading = false
                self?.isFetchingSessions = false
                self?.inFlightSessionsFetch = nil
            }
            do {
                // The server is authoritative for ownership: `listSessions()` is
                // TOKEN-scoped — exactly the sessions this token owns. That IS the
                // "what sessions do I own?" answer; the client renders it
                // directly. A throwing RPC leaves `sessions` untouched (the catch
                // below), so a transient failure never blanks the pane.
                guard let self else { return }
                let tokenScoped = try await self.withAuth { try await $0.listSessions() }
                self.reconcile(tokenScoped: tokenScoped)
            } catch {
                // A refresh, not the authoritative population of the pane —
                // that is `performHandshake`, which retries and surfaces
                // failures. Log so this is never invisible again: silently
                // dropping the error here is what made the empty-pane bug
                // undiagnosable for five rounds of fixes.
                recoveryLog.error("fetchSessions failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        inFlightSessionsFetch = task
        await task.value
    }

    /// Reconcile local state against the server's authoritative, token-scoped
    /// session list. Pure with respect to the network — the list is passed in —
    /// so it can be unit tested directly.
    ///
    /// - `tokenScoped`: `listSessions()` — exactly the sessions this token owns.
    ///   This IS the source of truth for the pane. There is no local ownership
    ///   set: `activeSessions` renders `sessions` (minus terminal), so assigning
    ///   `sessions = tokenScoped` is what makes a session appear or disappear.
    ///
    /// Cleanup for sessions that dropped out of the token-scoped list (attached
    /// by another client, or terminated) is driven live by the `session_stolen`
    /// push while the client is connected (see `handleSessionStolen`). On a cold
    /// relaunch we simply don't list them — no reconciliation, no persisted set,
    /// so there is nothing that can drift from the server and blank the pane.
    func reconcile(tokenScoped: [SessionInfo]) {
        sessions = tokenScoped

        for session in sessions {
            if let serverName = session.name {
                sessionNames[session.id] = serverName
            }
        }
        // Diff-checked inside the store — no UserDefaults write when the names
        // dictionary is unchanged since the last save (C-21).
        ownershipStore.saveNames(sessionNames)

        for session in sessions {
            let activity = session.activity ?? .idle
            handleActivityUpdate(sessionId: session.id, activity: activity, agent: session.agent,
                                 agentState: session.agentState, title: session.title)
        }

        let serverIds = Set(sessions.map { $0.id })

        // Prune stale local per-session state to the server's authoritative list
        // (anything absent was attached elsewhere, terminated, or lost on a
        // server restart). This is bookkeeping only — ownership is NOT persisted.
        //
        // Compute the stale activity ids BEFORE pruning the agents map, then
        // `forgetSession` each — that clears agentSessions, sessionsAwaitingInput,
        // agentStates, titles, and unseen together. (Pruning first would empty
        // the map and make the subtraction below a no-op.)
        let staleActivity = Set(activityCoordinator.agentSessions.keys).subtracting(serverIds)
        for id in staleActivity { activityCoordinator.forgetSession(id) }
        // Prune persisted names to the server list (diff-checked). `agents` is
        // already reconciled above via forgetSession, so pass the live snapshot.
        var agentsScratch = activityCoordinator.agentSessions
        ownershipStore.pruneToServerSessions(serverIds: serverIds, names: &sessionNames, agents: &agentsScratch)
        activityCoordinator.agentSessions = agentsScratch
        // Evict cached terminal views / VMs for sessions no longer listed.
        terminalCache.pruneStale(knownSessionIds: serverIds)
        let cachedNow = terminalCache.cachedIds
        let staleVMs = Set(terminalViewModels.keys).subtracting(serverIds).subtracting(cachedNow)
        for id in staleVMs { terminalViewModels.removeValue(forKey: id) }

        // F3: restore the focused tab once, on the first fetch — only when it's
        // a NON-TERMINAL session this token still owns (restore goes through
        // switchToSession → resumeSession, which would error on a terminal id).
        // Restore through switchToSession — NOT a bare activeSessionId
        // assignment — so the terminal is actually wired: it creates the
        // TerminalViewModel, wires output, and resumeSession()s (triggering
        // scrollback replay). `restoreActiveTask` runs it after this fetch
        // returns so switchToSession's own trailing fetchSessions() doesn't
        // recurse.
        if !didRestoreActiveSession {
            didRestoreActiveSession = true
            let restorableIds = Set(sessions.filter { !$0.state.isTerminal }.map { $0.id })
            if activeSessionId == nil,
               let restored = ownershipStore.loadActiveSession(),
               restorableIds.contains(restored) {
                restoreActiveTask = Task { [weak self] in
                    await self?.switchToSession(id: restored)
                }
            }
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

            // Optimistically show the new session immediately; the forced
            // fetchSessions() below replaces `sessions` with the authoritative
            // token-scoped list (which will include it).
            if !sessions.contains(where: { $0.id == sessionId }) {
                sessions.append(SessionInfo(id: sessionId, name: name, state: .activeAttached,
                                            tokenId: sessionController?.tokenId ?? "",
                                            createdAt: Date(), cols: 0, rows: 0))
            }
            sessionNames[sessionId] = name
            ownershipStore.saveNames(sessionNames)

            let vm = TerminalViewModel(sessionId: sessionId, connection: connection)
            terminalViewModels[sessionId] = vm
            wireTerminalOutput(to: sessionId)
            activeSessionId = sessionId
            activityCoordinator.markSeen(sessionId)
            terminalCache.touch(sessionId)
            terminalCache.enforceLimit(activeSessionId: activeSessionId)

            // force: bypass the 0.5 s debounce — the just-created session MUST
            // land in `sessions` now so it appears in the pane (it may land
            // < 0.5 s after connect()'s initial fetch).
            await fetchSessions(force: true)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Switch

    /// Switches the visible session.
    ///
    /// **The selection is published BEFORE the RPCs, not after.** Both the
    /// sidebar's `List(selection:)` binding and the terminal container's
    /// `updateNSView` key off `activeSessionId`, so assigning it last made the
    /// whole UI wait on the wire: `resumeSession` sits in `SessionController`'s
    /// *serialized* RPC chain (replies carry no request ids, so at most one may be
    /// outstanding), each hop has a 10 s timeout, and a timeout POISONS the socket
    /// — every later RPC then throws `connectionDesynchronized` until a reconnect.
    /// One slow hop therefore cascaded into handshake retries plus recovery
    /// backoff while the pane stayed frozen on the old session, which is how a tab
    /// switch took minutes. Publishing first decouples perceived responsiveness
    /// from wire latency; the guard on `id != activeSessionId` then also stops an
    /// impatient re-click from queueing a second resume onto a stalled chain.
    public func switchToSession(id: UUID) async {
        guard !isRecovering, id != activeSessionId else { return }
        let previousId = activeSessionId

        // A live native terminal for the target means its SwiftTerm scrollback is
        // still on screen, so the server's ring-buffer replay would re-stream
        // `scrollbackSize` bytes the client already has (in 64 KB frames, parsed
        // on the main actor) — the reason `skipReplay` exists. When we skip it we
        // must also NOT reset the cached view's buffering state: `prepareForReplay`
        // clears `terminalSized`, which makes `terminalReady()` emit RIS and blank
        // the very glyphs we are reusing. The server still resize-wiggles
        // (`repaintAfter`) after a skipped replay, so a full-screen app redraws
        // itself if the grid changed while we were away.
        let hasLiveTerminal = terminalCache.view(for: id) != nil

        do {
            if let currentId = previousId, currentId != id {
                terminalViewModels[currentId]?.prepareForSwitch()
            }

            // Prepare the incoming VM and wire output BEFORE resumeSession so
            // binary replay frames are routed to the correct VM from the start.
            if terminalViewModels[id] == nil {
                terminalViewModels[id] = TerminalViewModel(sessionId: id, connection: connection)
            } else if !hasLiveTerminal {
                terminalViewModels[id]?.prepareForReplay()
            }
            if !hasLiveTerminal {
                terminalViewModels[id]?.beginReplay()
            }
            wireTerminalOutput(to: id)

            // Optimistic: publish the selection now so the sidebar highlight and
            // the terminal swap immediately. Everything below is bookkeeping the
            // views don't block on. Reverted in the catch if the resume fails.
            activeSessionId = id
            activityCoordinator.markSeen(id)
            terminalCache.touch(id)
            terminalCache.enforceLimit(activeSessionId: activeSessionId)

            try await withAuth { controller in
                if previousId != nil {
                    try? await controller.detach()
                }
                try await controller.resumeSession(id: id, skipReplay: hasLiveTerminal)
            }

            // force: bypass the debounce so the switched-to session refreshes
            // immediately (see createNewSession).
            await fetchSessions(force: true)
        } catch {
            // The optimistic publish has to be undone, or the pane sits on a
            // session that isn't attached: the server auto-detaches the previous
            // one before it can fail this resume, so after a failure NEITHER is
            // attached. Restore the previous selection and re-resume it (mirroring
            // `attachRemoteSession`'s rollback); with no previous session — the F3
            // restore path — clear the selection rather than show a blank terminal.
            if activeSessionId == id {
                activeSessionId = previousId
                if let previousId {
                    try? await sessionController?.resumeSession(id: previousId)
                    wireTerminalOutput(to: previousId)
                }
            }
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Attach

    /// Lists sessions running on the server (across all tokens) that aren't
    /// already in this token's pane, so they can be attached from another
    /// device. Filtered against the token-scoped `sessions` (what the pane shows
    /// now) so we never offer a session we already own.
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

            // Optimistically show the just-attached session; the forced
            // fetchSessions() below reconciles against the authoritative
            // token-scoped list (which now includes it — attach reassigned its
            // token to us).
            if !sessions.contains(where: { $0.id == id }) {
                sessions.append(SessionInfo(id: id, name: serverName, state: .activeAttached,
                                            tokenId: sessionController?.tokenId ?? "",
                                            createdAt: Date(), cols: 0, rows: 0))
            }
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

            // force: bypass the debounce — the just-attached session MUST land
            // in `sessions` now so it appears in the pane (see createNewSession).
            await fetchSessions(force: true)
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
            // Both are transport conditions, not the server rejecting the
            // request: `connectionDesynchronized` means an earlier RPC timed out
            // and the socket must be replaced before another can run.
            case .timeout, .connectionDesynchronized:
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
            // Drop from the pane immediately; the fetch below reconciles against
            // the server's list (which no longer includes the terminated session).
            sessions.removeAll { $0.id == id }
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
        // The server sends `session_stolen` to this (previous-owner) token when
        // ANOTHER client attaches a session we currently hold. Only act if it's
        // still in our pane / active, so a duplicate or late push doesn't
        // re-raise the alert for an already-handled session.
        guard sessions.contains(where: { $0.id == sessionId }) || activeSessionId == sessionId else { return }
        cleanUpStolenSession(sessionId)
    }

    /// Handles a session that was attached by another client: removes it from
    /// the pane and raises the "attached by another client" popup. Ordering
    /// matches the product spec — the session vanishes from the sidebar + tab
    /// bar FIRST (clear `activeSessionId`, drop from `sessions`, evict the
    /// terminal), THEN the alert is raised — so when the user taps OK the UI is
    /// already clean.
    ///
    /// - Parameters:
    ///   - alert: raise the popup. True for the live `session_stolen` push.
    ///   - refetch: re-run `fetchSessions` afterward. False when called from
    ///     inside a fetch pass to avoid re-entrancy.
    func cleanUpStolenSession(_ sessionId: UUID, alert: Bool = true, refetch: Bool = true) {
        let stolenName = name(for: sessionId)

        // 1) Remove from the UI first. The pane is driven by `sessions`, so drop
        //    it there directly (there is no owned set to unclaim anymore).
        if activeSessionId == sessionId {
            activeSessionId = nil
        }
        terminalViewModels[sessionId]?.isSendingSuppressed = true
        activityCoordinator.forgetSession(sessionId)
        sessions.removeAll { $0.id == sessionId }   // @Published → sidebar/tab re-render
        evictTerminal(for: sessionId)

        // 2) Then raise the alert (OK-only). ActivityCoordinator owns the flag.
        if alert {
            activityCoordinator.presentStolenAlert(sessionId: sessionId, name: stolenName)
        }

        // force: bypass the debounce so a list response snapshotted before the
        // server's token reassignment can't slip in and re-add the stolen row.
        if refetch { Task { await fetchSessions(force: true) } }
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
        handshake.invalidate()
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
