package relay.session

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import relay.net.RelayConnection
import relay.net.SessionController
import relay.net.SessionException
import relay.protocol.ActivityState
import relay.protocol.ConnectionConfig
import relay.protocol.ClientMessage
import relay.protocol.ServerMessage
import relay.protocol.SessionInfo
import relay.protocol.SessionNamingTheme
import relay.storage.SessionNaming
import relay.terminal.TerminalSessionVm
import java.util.UUID

/**
 * The coordinator-facing surface of the WebSocket connection. [RelayConnection]
 * satisfies it via [RelayConnectionGateway]; the coordinator's unit tests
 * substitute a recording fake so the op orderings can be asserted without a real
 * socket. Covers exactly the connection members the coordinator touches —
 * lifecycle, terminal-output routing, health callbacks, the server-message
 * fan-in, and the terminate control send.
 */
interface CoordinatorConnection {
    var onTerminalOutput: ((ByteArray) -> Unit)?
    var onSendFailed: (() -> Unit)?
    var onHealthyPing: (() -> Unit)?

    suspend fun connect(config: ConnectionConfig, token: String)
    suspend fun forceReconnect()
    suspend fun disconnect()
    suspend fun isAlive(): Boolean
    suspend fun send(message: ClientMessage)

    fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID
    fun removeSubscriber(id: UUID)
}

/** Adapts a concrete [RelayConnection] to [CoordinatorConnection]. */
class RelayConnectionGateway(private val connection: RelayConnection) : CoordinatorConnection {
    override var onTerminalOutput: ((ByteArray) -> Unit)?
        get() = connection.onTerminalOutput
        set(value) { connection.onTerminalOutput = value }
    override var onSendFailed: (() -> Unit)?
        get() = connection.onSendFailed
        set(value) { connection.onSendFailed = value }
    override var onHealthyPing: (() -> Unit)?
        get() = connection.onHealthyPing
        set(value) { connection.onHealthyPing = value }

    override suspend fun connect(config: ConnectionConfig, token: String) = connection.connect(config, token)
    override suspend fun forceReconnect() = connection.forceReconnect()
    override suspend fun disconnect() = connection.disconnect()
    override suspend fun isAlive(): Boolean = connection.isAlive()
    override suspend fun send(message: ClientMessage) = connection.send(message)
    override fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID =
        connection.addServerMessageSubscriber(handler)
    override fun removeSubscriber(id: UUID) = connection.removeSubscriber(id)
}

/**
 * Persistence surface the coordinator needs from the ownership store. The
 * concrete [relay.storage.SessionOwnershipStore] (an Android type that needs a
 * `Context`) satisfies this shape directly; the `:app` layer adapts it when
 * constructing the coordinator. Keeping it an interface lets the coordinator's
 * unit tests substitute an in-memory fake without `Context` — the same
 * injected-seam pattern [AgentPersistence] already uses.
 *
 * Extends [AgentPersistence] so a single adapter satisfies both the
 * coordinator's needs and the [ActivityCoordinator]'s.
 */
interface OwnershipStore : AgentPersistence {
    /** Snapshot of UUID → display name. */
    val names: Map<UUID, String>

    /** Snapshot of owned session ids (device-scoped). */
    val owned: Set<UUID>

    /** Sets (or, when [name] is null, removes) the display name for [id]. */
    fun setName(id: UUID, name: String?)

    /** Marks [id] as owned by this device. */
    fun claim(id: UUID)

    // `unclaim(id)` is inherited from [AgentPersistence] (returns Unit). The
    // concrete store's `Boolean` return is discarded by the adapter.
}

/**
 * The session-layer orchestrator, ported from
 * Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift.
 *
 * Owns the [RelayConnection] + [SessionController], the three facet coordinators
 * ([AuthCoordinator], [ActivityCoordinator], [RecoveryController]), the
 * [TerminalCache], and the ownership store. Exposes session/recovery/activity
 * state as [StateFlow]s the Compose layer collects.
 *
 * Like the Swift `@MainActor` original this type is **not** thread-safe — every
 * entry point and every callback must be confined to a single (main) dispatcher.
 * The `:app` layer wires [scope] with `Dispatchers.Main.immediate` and injects
 * `android.os.SystemClock.elapsedRealtime()` for [nowMs]; the unit tests inject a
 * `TestScope` and a fake clock.
 *
 * ## The four session ops are DISTINCT sequences
 * They were split deliberately (each fixed a real race) and must not be
 * collapsed into one shared flow. The load-bearing ordering differences:
 *  - **CREATE** (SharedSessionCoordinator.swift:388-421): RPC → claim → wire
 *    AFTER → active → touch → enforce → fetch.
 *  - **SWITCH** (:425-458): wire BEFORE resume (so binary replay frames route to
 *    the right VM from the first frame) → RPC → active → touch → enforce → fetch.
 *    **No claim** — switching is between sessions this device already owns.
 *  - **ATTACH** (:473-522): RPC → claim → beginReplay → wire AFTER → active →
 *    touch → enforce → name → fetch, with **previous-session rollback** on
 *    failure (:510-514).
 *  - **TERMINATE** (:565-578): send terminate → clear active → evict →
 *    forgetSession → unclaim (forget BEFORE unclaim) → drop name/title → fetch.
 *
 * Every session-op RPC is wrapped in [AuthCoordinator.withAuth] and guarded by
 * `!recoveryController.isRecovering.value` — ops are no-ops while recovering.
 */
class SessionCoordinator(
    private val scope: CoroutineScope,
    val connection: CoordinatorConnection,
    val sessionController: SessionController,
    val token: String,
    private val ownershipStore: OwnershipStore,
    private val config: ConnectionConfig,
    private val theme: SessionNamingTheme = SessionNamingTheme.DEFAULT,
    /**
     * Clock for the recovery cooldown/debounce. Defaults to wall-clock here so
     * the module stays pure-JVM; `:app` MUST inject
     * `android.os.SystemClock.elapsedRealtime()` (monotonic). Tests inject a fake.
     */
    private val nowMs: () -> Long = { System.currentTimeMillis() },
) {
    constructor(
        scope: CoroutineScope,
        connection: RelayConnection,
        token: String,
        ownershipStore: OwnershipStore,
        config: ConnectionConfig,
        theme: SessionNamingTheme = SessionNamingTheme.DEFAULT,
        nowMs: () -> Long = { System.currentTimeMillis() },
    ) : this(
        scope = scope,
        connection = RelayConnectionGateway(connection),
        sessionController = SessionController(connection),
        token = token,
        ownershipStore = ownershipStore,
        config = config,
        theme = theme,
        nowMs = nowMs,
    )

    // MARK: - Dependencies

    /** Auth surface: single-flight authenticate + withAuth retry-once. */
    val authCoordinator: AuthCoordinator

    /** Live agent / awaiting-input / stolen state. */
    val activityCoordinator: ActivityCoordinator

    /** Recovery state machine (breaker, backoff, restore). */
    val recoveryController: RecoveryController

    /**
     * LRU-8 cache of per-session terminal buffering view-models. Kept alive
     * across switches so scrollback survives tab-like navigation (Swift limit 8).
     */
    val terminalCache = TerminalCache<TerminalSessionVm>(limit = 8)

    // MARK: - Published state

    private val _sessions = MutableStateFlow<List<SessionInfo>>(emptyList())
    val sessions: StateFlow<List<SessionInfo>> = _sessions.asStateFlow()

    private val _activeSessionId = MutableStateFlow<UUID?>(null)
    val activeSessionId: StateFlow<UUID?> = _activeSessionId.asStateFlow()

    private val _sessionNames = MutableStateFlow<Map<UUID, String>>(emptyMap())
    /** Mirror of the ownership store's names, for the sidebar. */
    val sessionNames: StateFlow<Map<UUID, String>> = _sessionNames.asStateFlow()

    private val _terminalTitles = MutableStateFlow<Map<UUID, String>>(emptyMap())
    val terminalTitles: StateFlow<Map<UUID, String>> = _terminalTitles.asStateFlow()

    private val _ownedSessionIds = MutableStateFlow<Set<UUID>>(emptySet())
    val ownedSessionIds: StateFlow<Set<UUID>> = _ownedSessionIds.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    // MARK: - Recovery state (delegated to RecoveryController)

    val isRecovering: StateFlow<Boolean> get() = recoveryController.isRecovering
    val recoveryPhase: StateFlow<RecoveryPhase> get() = recoveryController.phase
    val connectionTimedOut: StateFlow<Boolean> get() = recoveryController.connectionTimedOut
    val sessionAttachFailed: StateFlow<Boolean> get() = recoveryController.sessionAttachFailed
    val autoRecoverySuspended: StateFlow<Boolean> get() = recoveryController.autoRecoverySuspended

    // MARK: - Activity state (delegated to ActivityCoordinator)

    val agentSessions: StateFlow<Map<UUID, String>> get() = activityCoordinator.agentSessions
    val sessionsAwaitingInput: StateFlow<Set<UUID>> get() = activityCoordinator.sessionsAwaitingInput
    val sessionsStolen: StateFlow<Set<UUID>> get() = activityCoordinator.sessionsStolen
    val stolenAlert: StateFlow<ActivityCoordinator.StolenAlert?> get() = activityCoordinator.stolenAlert

    // MARK: - Send-suppression

    /**
     * Toggled by recovery (Swift `suppressAllViewModelSends`). The active
     * terminal VM checks this before sending input (wired in M4). Exposed so the
     * workspace layer can gate input while a recovery pass is in flight.
     */
    @Volatile
    var sendsSuppressed: Boolean = false
        private set

    /** Subscription id for the server-message fan-in, removed on [tearDown]. */
    private var subscriberId: UUID? = null

    init {
        authCoordinator = AuthCoordinator(
            authenticate = { sessionController.authenticate(token) },
            isAuthValid = { sessionController.isAuthValid },
            resetAuth = { sessionController.resetAuth() },
        )
        activityCoordinator = ActivityCoordinator(persistence = ownershipStore)

        // Hydrate the published mirrors from the persisted store.
        _sessionNames.value = ownershipStore.names
        _ownedSessionIds.value = ownershipStore.owned

        // Recovery collaborators: real lambdas bound to the connection + controller.
        recoveryController = RecoveryController(
            scope = scope,
            // isAlive wraps a 5 s pong wait inside RelayConnection.isAlive().
            isAlive = { connection.isAlive() },
            reconnect = { connection.forceReconnect() },
            reauth = { sessionController.authenticate(token) },
            resumeActive = { resumeActiveForRecovery() },
            fetchSessions = { fetchSessions() },
            suppressSends = { on -> sendsSuppressed = on },
            isApplicationLevelError = { isApplicationLevelError(it) },
            nowMs = nowMs,
        )

        // Server-message fan-in. RelayConnection routes pongs internally; every
        // other ServerMessage arrives here and is dispatched by type.
        subscriberId = connection.addServerMessageSubscriber { message ->
            scope.launch { handleServerMessage(message) }
        }

        // Transport health → recovery breaker, matching the Swift init wiring.
        connection.onSendFailed = { recoveryController.scheduleAutoRecovery() }
        connection.onHealthyPing = { recoveryController.resetAutoRecoveryBreaker() }
    }

    // MARK: - Connect

    /**
     * Connects, authenticates, and loads the initial session list (Swift's
     * connect path is split across the platform host + `fetchSessions`). Stores
     * config/token on the connection for later `forceReconnect`.
     */
    suspend fun connect() {
        connection.connect(config, token)
        authCoordinator.ensureAuthenticated()
        fetchSessions()
    }

    // MARK: - Names

    fun name(id: UUID): String = _sessionNames.value[id] ?: id.toString().take(8)

    private fun pickDefaultName(): String =
        SessionNaming.pickDefaultName(
            usedNames = _sessionNames.value.values.toSet(),
            theme = theme,
            fallbackIndex = _sessionNames.value.size + 1,
        )

    private fun setNameLocal(id: UUID, name: String?) {
        ownershipStore.setName(id, name)
        _sessionNames.value = ownershipStore.names
    }

    /**
     * User/explicit rename. Updates the local mirror and broadcasts to the
     * server (fire-and-forget; the server echoes `session_renamed` to all
     * connections). Mirrors Swift `setName(_:for:)`.
     */
    suspend fun renameSession(id: UUID, name: String) {
        setNameLocal(id, name)
        runCatching { sessionController.renameSession(id, name) }
    }

    // MARK: - Ownership

    private fun claimSession(id: UUID) {
        ownershipStore.claim(id)
        _ownedSessionIds.value = ownershipStore.owned
    }

    private fun unclaimSession(id: UUID) {
        ownershipStore.unclaim(id)
        _ownedSessionIds.value = ownershipStore.owned
    }

    // MARK: - Session list

    /**
     * Refreshes the session list and prunes per-id ownership/agent/cache state
     * for sessions the server no longer knows about (SharedSessionCoordinator.swift:307-359).
     *
     * The Android ownership store has only per-id mutators (no bulk prune), so we
     * reproduce the Swift prune locally: for every locally-known id NOT in the
     * server set, drop its name, claim, and agent, evict its cached terminal, and
     * forget its activity state. A non-critical refresh — failures are swallowed.
     */
    suspend fun fetchSessions() {
        val list = runCatching { authCoordinator.withAuth { sessionController.listSessions() } }
            .getOrElse { return }
        _sessions.value = list

        // Adopt any server-provided names.
        for (session in list) {
            session.name?.let { setNameLocal(session.id, it) }
        }

        // Re-apply each session's activity so the sidebar reflects server state.
        for (session in list) {
            activityCoordinator.applyActivity(session.id, session.activity ?: ActivityState.IDLE, session.agent)
        }

        val serverIds = list.map { it.id }.toSet()

        // Prune names not on the server.
        for (id in ownershipStore.names.keys.toList()) {
            if (id !in serverIds) setNameLocal(id, null)
        }
        // Prune owned ids not on the server.
        for (id in ownershipStore.owned.toList()) {
            if (id !in serverIds) unclaimSession(id)
        }
        // Prune agents not on the server, forgetting their activity state too.
        for (id in ownershipStore.agents.keys.toList()) {
            if (id !in serverIds) activityCoordinator.forgetSession(id)
        }
        // Evict cached terminals for sessions that no longer exist on the server.
        val prunedTerminals = terminalCache.pruneStale(serverIds)
        // Forget activity for any pruned terminal whose id wasn't already handled
        // above (e.g. a cached terminal with no agent entry).
        for (id in prunedTerminals) {
            if (id !in serverIds) activityCoordinator.forgetSession(id)
        }
    }

    // MARK: - Create (SharedSessionCoordinator.swift:388-421)

    suspend fun createNewSession() {
        if (recoveryController.isRecovering.value) return
        val previousId = _activeSessionId.value
        try {
            val name = pickDefaultName()
            // withAuth: detach the previous session (best-effort), then create.
            val sessionId = authCoordinator.withAuth {
                if (previousId != null) runCatching { sessionController.detach() }
                sessionController.createSession(name)
            }

            previousId?.let {
                terminalCache.view(it)?.prepareForSwitch()
                terminalCache.evict(it)
            }

            // claim → name BEFORE wiring; wire AFTER the RPC (create/attach wire after).
            claimSession(sessionId)
            setNameLocal(sessionId, name)

            terminalCache.put(sessionId, TerminalSessionVm())
            wireTerminalOutput(sessionId)
            _activeSessionId.value = sessionId
            terminalCache.touch(sessionId)
            terminalCache.enforceLimit(_activeSessionId.value)

            fetchSessions()
        } catch (e: Throwable) {
            presentError(e.message ?: "Failed to create session")
        }
    }

    // MARK: - Switch (SharedSessionCoordinator.swift:425-458)

    suspend fun switchToSession(id: UUID) {
        if (recoveryController.isRecovering.value || id == _activeSessionId.value) return
        val previousId = _activeSessionId.value
        try {
            if (previousId != null && previousId != id) {
                terminalCache.view(previousId)?.prepareForSwitch()
            }

            // Prepare the incoming VM and wire output BEFORE resumeSession so
            // binary replay frames route to the correct VM from the first frame
            // (SharedSessionCoordinator.swift:433-434).
            val incoming = terminalCache.view(id)
            if (incoming == null) {
                terminalCache.put(id, TerminalSessionVm())
            } else {
                incoming.prepareForReplay()
            }
            terminalCache.view(id)?.beginReplay()
            wireTerminalOutput(id) // BEFORE resume. NO claim — switching owned sessions.

            authCoordinator.withAuth {
                if (previousId != null) runCatching { sessionController.detach() }
                sessionController.resumeSession(id, skipReplay = false)
            }

            _activeSessionId.value = id
            terminalCache.touch(id)
            terminalCache.enforceLimit(_activeSessionId.value)

            fetchSessions()
        } catch (e: Throwable) {
            presentError(e.message ?: "Failed to switch session")
        }
    }

    // MARK: - Attach (SharedSessionCoordinator.swift:462-561)

    /** Lists cross-device sessions this device does not already own. */
    suspend fun fetchAttachableSessions(): List<SessionInfo> =
        runCatching {
            authCoordinator.withAuth { sessionController.listAllSessions() }
                .filter { !it.state.isTerminal && it.id !in ownershipStore.owned }
        }.getOrDefault(emptyList())

    suspend fun attachRemoteSession(id: UUID, serverName: String? = null) {
        if (recoveryController.isRecovering.value) return
        val previousId = _activeSessionId.value
        try {
            authCoordinator.withAuth {
                if (previousId != null) runCatching { sessionController.detach() }
                sessionController.attachSession(id)
            }

            if (previousId != null && previousId != id) {
                terminalCache.view(previousId)?.prepareForSwitch()
                terminalCache.evict(previousId)
            }

            // claim → beginReplay → wire AFTER the RPC (attach wires after).
            claimSession(id)
            val vm = TerminalSessionVm()
            vm.beginReplay()
            terminalCache.put(id, vm)
            wireTerminalOutput(id)
            _activeSessionId.value = id
            terminalCache.touch(id)
            terminalCache.enforceLimit(_activeSessionId.value)

            if (serverName != null) {
                setNameLocal(id, serverName)
            } else if (_sessionNames.value[id] == null) {
                val name = pickDefaultName()
                setNameLocal(id, name)
                runCatching { sessionController.renameSession(id, name) }
            }

            fetchSessions()
        } catch (e: Throwable) {
            // Rollback to the previous session (SharedSessionCoordinator.swift:510-514).
            if (previousId != null) {
                runCatching { sessionController.resumeSession(previousId) }
                wireTerminalOutput(previousId)
            }
            if (isApplicationLevelError(e)) {
                // App-level failure: the connection is fine, the session is gone.
                // Surfaced as a recoverable attach error rather than dismissing.
                presentError(friendlyAttachErrorMessage(e))
            } else {
                presentError(e.message ?: "Failed to attach session")
            }
        }
    }

    // MARK: - Terminate (SharedSessionCoordinator.swift:565-578)

    suspend fun terminateSession(id: UUID) {
        if (recoveryController.isRecovering.value) return
        try {
            connection.send(ClientMessage.SessionTerminate(id))
            if (_activeSessionId.value == id) {
                _activeSessionId.value = null
            }
            evictTerminal(id)
            // forget BEFORE unclaim (the Swift ordering at :573-574).
            activityCoordinator.forgetSession(id)
            unclaimSession(id)
            setNameLocal(id, null)
            _terminalTitles.value = _terminalTitles.value - id
            fetchSessions()
        } catch (e: Throwable) {
            presentError(e.message ?: "Failed to terminate session")
        }
    }

    // MARK: - Server-message fan-in

    private fun handleServerMessage(message: ServerMessage) {
        when (message) {
            is ServerMessage.SessionActivity ->
                onSessionActivity(message.sessionId, message.activity, message.agent)
            is ServerMessage.SessionStolen -> onSessionStolen(message.sessionId)
            is ServerMessage.SessionRenamed -> onSessionRenamed(message.sessionId, message.name)
            is ServerMessage.ReplayComplete -> onReplayComplete(message.sessionId)
            is ServerMessage.SessionStateMsg -> onSessionState(message.sessionId, message.state)
            else -> Unit // pongs/acks/list-results handled elsewhere.
        }
    }

    private fun onSessionActivity(sessionId: UUID, activity: ActivityState, agent: String?) {
        activityCoordinator.applyActivity(sessionId, activity, agent)
    }

    private fun onSessionStolen(sessionId: UUID) {
        val wasActive = _activeSessionId.value == sessionId
        // ActivityCoordinator.sessionStolen already relinquishes ownership
        // (unclaim) — do NOT double-unclaim here (M2-C note).
        activityCoordinator.sessionStolen(sessionId) { name(it) }
        if (wasActive) {
            _activeSessionId.value = null
        }
        _ownedSessionIds.value = ownershipStore.owned
        evictTerminal(sessionId)
        scope.launch { fetchSessions() }
    }

    private fun onSessionRenamed(sessionId: UUID, name: String) {
        setNameLocal(sessionId, name)
    }

    private fun onReplayComplete(sessionId: UUID) {
        // The replay_complete signal targets whichever VM is the active terminal.
        terminalCache.view(_activeSessionId.value ?: sessionId)?.endReplay()
    }

    private fun onSessionState(sessionId: UUID, state: String) {
        // The server pushes coarse state transitions; refresh the list so the
        // sidebar reflects them.
        scope.launch { fetchSessions() }
    }

    // MARK: - Terminal output wiring

    /**
     * Routes the connection's binary terminal output to the VM for [sessionId].
     * The connection has a single `onTerminalOutput` slot, so wiring a new
     * session replaces the previous routing — exactly the Swift single-slot model
     * (SharedSessionCoordinator.swift:635-645).
     */
    fun wireTerminalOutput(sessionId: UUID) {
        connection.onTerminalOutput = { data ->
            terminalCache.view(sessionId)?.receiveOutput(data)
        }
    }

    /**
     * The recovery `resumeActive` collaborator. Reproduces Swift restoreSession's
     * pre-resume work: reset the active VM for replay, re-wire output, then resume
     * the active session (no-op when there is no active session).
     */
    private suspend fun resumeActiveForRecovery() {
        val activeId = _activeSessionId.value ?: return
        terminalCache.view(activeId)?.let { vm ->
            vm.prepareForReplay()
            vm.beginReplay()
        }
        wireTerminalOutput(activeId)
        sessionController.resumeSession(activeId, skipReplay = false)
    }

    // MARK: - Terminal cache forwarders

    private fun evictTerminal(sessionId: UUID) {
        terminalCache.view(sessionId)?.prepareForSwitch()
        terminalCache.evict(sessionId)
    }

    // MARK: - Recovery

    /**
     * Foreground / network-restored / rescan signal. When the connection is
     * already alive this short-circuits to a list refresh without flashing
     * recovery UI; otherwise it drives the recovery pass. Mirrors Swift
     * `handleForegroundTransition`.
     */
    fun handleForegroundTransition() {
        recoveryController.triggerUserRecovery()
    }

    /** Explicit user-initiated recovery (QR rescan, manual retry). */
    fun triggerUserRecovery() {
        recoveryController.triggerUserRecovery()
    }

    /**
     * Cancels any in-flight recovery and the in-flight auth single-flight
     * (Swift RecoveryController.swift:289 calls
     * `coordinator.authCoordinator.cancelInFlight()`).
     */
    fun cancelRecovery() {
        recoveryController.cancel()
        authCoordinator.cancelInFlight()
    }

    /**
     * Clears the terminal recovery flags (connectionTimedOut / sessionAttachFailed).
     * The UI calls this when the user dismisses the recovery error or a fresh
     * foreground transition begins. Mirrors the Swift reset on WorkspaceView.
     */
    fun clearRecoveryFlags() {
        recoveryController.clearTerminalFlags()
    }

    // MARK: - Error classification (SharedSessionCoordinator.swift:525-561)

    /**
     * Classifies a restore/attach error: app-level (session gone, ownership,
     * server-side error) vs transport-level (connection dead). App-level errors
     * are recoverable without dismissing the workspace.
     */
    internal fun isApplicationLevelError(error: Throwable): Boolean {
        if (error is SessionException) {
            // "not authenticated" maps to a transient/transport-adjacent state in
            // Swift's .timeout branch — treat the rest of the unexpected-response
            // family as app-level. A timeout message is transport-level.
            if (error.message?.contains("timed out", ignoreCase = true) == true) return false
            return true
        }
        return false
    }

    private fun friendlyAttachErrorMessage(error: Throwable): String {
        val detail = error.message ?: return "Failed to attach session"
        return when {
            detail.contains("not found", ignoreCase = true) ->
                "This session no longer exists on the server."
            detail.contains("invalid", ignoreCase = true) ||
                detail.contains("terminal", ignoreCase = true) ->
                "This session has ended and cannot be reattached."
            detail.contains("no session attached", ignoreCase = true) ||
                detail.contains("not authenticated", ignoreCase = true) ->
                "The session couldn't be restored. Please try reconnecting."
            else -> detail
        }
    }

    // MARK: - Errors

    private fun presentError(message: String) {
        _errorMessage.value = message
    }

    fun clearError() {
        _errorMessage.value = null
    }

    // MARK: - Teardown

    /**
     * Releases all resources: cancels recovery, removes the server-message
     * subscriber, clears the terminal cache, and disconnects the transport.
     */
    suspend fun tearDown() {
        recoveryController.cancel()
        authCoordinator.cancelInFlight()
        subscriberId?.let { connection.removeSubscriber(it) }
        subscriberId = null
        connection.onTerminalOutput = null
        connection.onSendFailed = null
        connection.onHealthyPing = null
        terminalCache.removeAll()
        connection.disconnect()
    }
}
