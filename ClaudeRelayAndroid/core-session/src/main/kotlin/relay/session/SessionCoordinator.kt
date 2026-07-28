package relay.session

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
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
import relay.protocol.PushPlatform
import relay.protocol.ServerMessage
import relay.protocol.SessionInfo
import relay.protocol.SessionNamingTheme
import relay.protocol.SessionState
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

    /** Sets (or, when [name] is null, removes) the display name for [id]. */
    fun setName(id: UUID, name: String?)
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
 *  - **CREATE**: RPC → optimistic pane insert → wire AFTER → active → touch →
 *    enforce → forced fetch (which replaces the pane with the server list).
 *  - **SWITCH**: wire BEFORE resume (so binary replay frames route to the right
 *    VM from the first frame) → RPC → active → touch → enforce → fetch.
 *  - **ATTACH**: RPC → optimistic pane insert → beginReplay → wire AFTER →
 *    active → touch → enforce → name → forced fetch, with **previous-session
 *    rollback** on failure.
 *  - **TERMINATE**: send terminate → clear active → evict → forgetSession →
 *    drop from pane → drop name/title → fetch.
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
    // M4: populated by the OSC-title → terminalTitles wiring in wireTerminalOutput
    // once TerminalSessionVm gains an `onTitleChanged` callback
    // (SharedSessionCoordinator.swift:642-644). Today only terminate clears it.
    val terminalTitles: StateFlow<Map<UUID, String>> = _terminalTitles.asStateFlow()

    /**
     * The filtered + sorted session list the tab bar and sidebar render.
     *
     * The SERVER is authoritative for ownership: [_sessions] is the token-scoped
     * `session_list` result — exactly the sessions this token owns — so the pane
     * renders it directly, dropping only terminal sessions. There is NO local
     * owned set: a session leaves the pane precisely when the server stops
     * listing it under this token (attached by another client, or terminated).
     * This removes the class of "empty pane on relaunch" bugs that a local,
     * device-scoped ownership cache kept reintroducing.
     *
     * Backed by a plain [MutableStateFlow] (not `combine(...).stateIn(...)`)
     * because an eager `stateIn` collector on [scope] never completes and
     * strands a coroutine under `runTest`. Sort: `createdAt` ASCENDING.
     */
    private val _activeSessions = MutableStateFlow<List<SessionInfo>>(emptyList())
    val activeSessions: StateFlow<List<SessionInfo>> = _activeSessions.asStateFlow()

    /** Re-derives [activeSessions] from the current raw server list. */
    private fun recomputeActiveSessions() {
        _activeSessions.value = computeActiveSessions(_sessions.value)
    }

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    /** True while a [fetchSessions] pass is in flight (Swift `isLoading`, :312-313). */
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

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
    val agentStates: StateFlow<Map<UUID, relay.protocol.AgentDetectedState>> get() = activityCoordinator.agentStates
    val sessionTitles: StateFlow<Map<UUID, String>> get() = activityCoordinator.sessionTitles
    val unseenSessions: StateFlow<Set<UUID>> get() = activityCoordinator.unseenSessions

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

    /**
     * Timestamp (from [nowMs]) of the last [fetchSessions] entry, the 0.5 s
     * debounce anchor (Swift `lastFetchTime`, :116, :308-310). Null means "never
     * fetched" (Swift `Date.distantPast`), so the first fetch always passes the
     * gate — avoids the `now - MIN_VALUE` overflow a sentinel Long would cause.
     */
    private var lastFetchMs: Long? = null
    /** Single-flight guard for [fetchSessions] — concurrent callers await the one
     *  in-flight fetch instead of issuing parallel `session_list` RPCs (whose
     *  type-matched replies could cross-deliver). */
    private var inFlightSessionsFetch: Job? = null

    /**
     * Timestamp (from [nowMs]) of the last evidence the transport is healthy — a
     * successful pong ([onHealthyPing]) or a fresh [connect]. The input-activity
     * liveness probe ([notifyUserActivity]) compares against this to decide
     * whether a keystroke is going out over a possibly-dead socket. Null means
     * "no health evidence yet".
     */
    private var lastHealthyAtMs: Long? = null

    /**
     * Timestamp (from [nowMs]) of the last [notifyUserActivity] probe, throttling
     * the probe so a burst of keystrokes fires at most one liveness check per
     * [ACTIVITY_PROBE_THROTTLE_MS] window.
     */
    private var lastActivityProbeMs: Long? = null

    init {
        authCoordinator = AuthCoordinator(
            authenticate = { sessionController.authenticate(token) },
            isAuthValid = { sessionController.isAuthValid },
            resetAuth = { sessionController.resetAuth() },
        )
        activityCoordinator = ActivityCoordinator(persistence = ownershipStore)

        // Hydrate the published mirrors from the persisted store. Ownership is
        // NOT persisted — the server's token-scoped list is authoritative and
        // arrives on the first fetch.
        _sessionNames.value = ownershipStore.names
        recomputeActiveSessions()

        // Recovery collaborators: real lambdas bound to the connection + controller.
        recoveryController = RecoveryController(
            scope = scope,
            // isAlive wraps a 5 s pong wait inside RelayConnection.isAlive().
            isAlive = { connection.isAlive() },
            needsRestore = { needsSessionRestore() },
            reconnect = { connection.forceReconnect() },
            // Reset auth only when it is actually stale for the current
            // connection, then go through the single-flight ensureAuthenticated
            // (iOS restoreSession does resetAuth() + ensureAuthenticated(),
            // RecoveryController.swift:239-241). The conditional matters on the
            // alive-restore path: the server handler is STILL authenticated
            // there, and a blind re-auth would draw its 400 "Already
            // authenticated" reject and fail the whole restore.
            reauth = {
                if (!sessionController.isAuthValid) sessionController.resetAuth()
                authCoordinator.ensureAuthenticated()
            },
            resumeActive = { resumeActiveForRecovery() },
            fetchSessions = { fetchSessions() },
            suppressSends = { on -> sendsSuppressed = on },
            isApplicationLevelError = { isApplicationLevelError(it) },
            onAppLevelRestoreFailure = { handleAppLevelRestoreFailure() },
            nowMs = nowMs,
        )

        // Server-message fan-in. RelayConnection routes pongs internally; every
        // other ServerMessage arrives here and is dispatched by type.
        subscriberId = connection.addServerMessageSubscriber { message ->
            scope.launch { handleServerMessage(message) }
        }

        // Transport health → recovery breaker, matching the Swift init wiring.
        // Both callbacks are invoked by RelayConnection on ITS confinement
        // dispatcher (the `relay-net` thread, see NetworkConfinement) — not the
        // coordinator's main dispatcher. The coordinator and RecoveryController
        // are main-confined, so hop onto [scope] before touching their state
        // (lastHealthyAtMs, the breaker, the dispatch lock).
        connection.onSendFailed = {
            scope.launch { recoveryController.scheduleAutoRecovery() }
        }
        connection.onHealthyPing = {
            scope.launch {
                lastHealthyAtMs = nowMs()
                recoveryController.resetAutoRecoveryBreaker()
            }
        }
    }

    /**
     * Coordinator-side handler for an app-level recovery (restore) failure. Swift
     * does this evict + clear inline inside `RecoveryController.restoreSession`
     * (RecoveryController.swift:263-266); the pure-JVM controller delegates the
     * coordinator mutation back via the `onAppLevelRestoreFailure` hook so the
     * controller stays Android-free. Runs before the controller sets
     * `sessionAttachFailed`.
     */
    private fun handleAppLevelRestoreFailure() {
        _activeSessionId.value?.let { activeId ->
            evictTerminal(activeId)
            _activeSessionId.value = null
        }
    }

    // MARK: - Connect

    /**
     * Connects, authenticates, and loads the initial session list (Swift's
     * connect path is split across the platform host + `fetchSessions`). Stores
     * config/token on the connection for later `forceReconnect`.
     */
    suspend fun connect() {
        connection.connect(config, token)
        lastHealthyAtMs = nowMs()
        authCoordinator.ensureAuthenticated()
        // force: authoritative launch fetch — never debounced behind a racing
        // recovery/foreground fetch, which left the pane empty on relaunch.
        fetchSessions(force = true)
    }

    /**
     * (Re)register this device's FCM push token with the server, or unregister
     * it, per [PushRegistrationController]. Pure at this layer — `:app` supplies
     * `deviceToken`/`permissionGranted`/`deviceId` (from FcmTokenBridge +
     * DeviceIdentifier) since those need Android `Context`. Best-effort: a failed
     * send is retried on the next trigger (connect / token refresh / settings
     * change). Mirrors the Swift `syncPushRegistration`.
     */
    suspend fun syncPushRegistration(
        deviceToken: String?,
        permissionGranted: Boolean,
        deviceId: String,
        pushEnabled: Boolean,
        notifyOnFinished: Boolean,
    ) {
        val action = PushRegistrationController.decide(
            permissionGranted = permissionGranted,
            deviceToken = deviceToken,
            connected = connection.isAlive(),
            pushEnabledSetting = pushEnabled,
            notifyOnFinished = notifyOnFinished,
        )
        try {
            when (action) {
                is PushRegistrationController.Action.Register -> {
                    val tok = deviceToken ?: return
                    connection.send(
                        ClientMessage.RegisterPushToken(
                            platform = PushPlatform.FCM,
                            token = tok,
                            deviceId = deviceId,
                            enabled = action.enabled,
                            notifyOnFinished = action.notifyOnFinished,
                        )
                    )
                }
                PushRegistrationController.Action.Unregister ->
                    connection.send(ClientMessage.UnregisterPushToken(deviceId))
                PushRegistrationController.Action.Noop -> Unit
            }
        } catch (_: Throwable) {
            // Best-effort; retried on the next sync trigger.
        }
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

    // MARK: - Pane mutation
    //
    // Ownership is not persisted; the pane IS the server's token-scoped list.
    // These helpers mutate `_sessions` optimistically so a just-created/attached
    // session shows instantly, or a removed one disappears instantly, before the
    // authoritative fetch lands.

    /** Optimistically add a session to the pane if absent. */
    private fun addSessionLocal(info: SessionInfo) {
        if (_sessions.value.none { it.id == info.id }) {
            _sessions.value = _sessions.value + info
            recomputeActiveSessions()
        }
    }

    /** Optimistically drop a session from the pane. */
    private fun removeSessionLocal(id: UUID) {
        if (_sessions.value.any { it.id == id }) {
            _sessions.value = _sessions.value.filterNot { it.id == id }
            recomputeActiveSessions()
        }
    }

    // MARK: - Session list

    /**
     * Refreshes the session list and prunes per-id name/agent/cache state for
     * sessions the server no longer lists (SharedSessionCoordinator.swift reconcile).
     *
     * The Android store has only per-id mutators (no bulk prune), so we reproduce
     * the Swift prune locally: for every locally-known id NOT in the server set,
     * drop its name and agent, evict its cached terminal, and forget its activity
     * state. A non-critical refresh — failures are swallowed. (Ownership itself is
     * not persisted; the pane IS the server list.)
     */
    suspend fun fetchSessions(force: Boolean = false) {
        // 0.5 s debounce keyed on the injected [nowMs] clock (Swift :308-310).
        // The first fetch (lastFetchMs == null, Swift `.distantPast`) always
        // passes; subsequent calls within 500 ms are dropped.
        //
        // [force] bypasses the debounce for post-mutation fetches (create /
        // attach / stolen-cleanup). The debounce only exists to avoid refresh
        // churn — it must NEVER suppress a fetch while the pane is EMPTY, or a
        // launch/foreground fetch that races another can leave the pane blank
        // until the user forces a refresh by attaching. So a fetch always
        // proceeds when `_sessions` is empty; nothing to protect from churn then.
        val last = lastFetchMs
        if (!force && _sessions.value.isNotEmpty() && last != null && nowMs() - last < FETCH_DEBOUNCE_MS) return

        // Single-flight: never issue two `session_list` in parallel — replies
        // are matched by response TYPE (no request ids) so overlapping calls
        // could cross-deliver. A NON-forced caller coalesces (await the in-flight
        // fetch and return). A FORCED caller (create/attach/switch/stolen) needs
        // a result reflecting ITS mutation, so it awaits any in-flight fetch to
        // clear, then runs its own fresh one.
        while (true) {
            val inFlight = inFlightSessionsFetch ?: break
            inFlight.join()
            if (!force) return
        }
        lastFetchMs = nowMs()
        _isLoading.value = true
        val job = scope.launch {
            try {
                doFetchSessions()
            } finally {
                _isLoading.value = false
                inFlightSessionsFetch = null
            }
        }
        inFlightSessionsFetch = job
        job.join()
    }

    private suspend fun doFetchSessions() {
        // The server is authoritative for ownership: `session_list` is
        // TOKEN-scoped — exactly the sessions this token owns. That IS the
        // "what sessions do I own?" answer; the pane renders it directly. A
        // failed RPC leaves `_sessions` untouched (early return), so a transient
        // failure never blanks the pane.
        val list = runCatching { authCoordinator.withAuth { sessionController.listSessions() } }
            .getOrElse { return }
        _sessions.value = list
        recomputeActiveSessions()

        val serverIds = list.map { it.id }.toSet()

        // Adopt any server-provided names.
        for (session in list) {
            session.name?.let { setNameLocal(session.id, it) }
        }

        // Re-apply each session's activity so the sidebar reflects server state.
        for (session in list) {
            activityCoordinator.applyActivity(
                session.id,
                session.activity ?: ActivityState.IDLE,
                session.agent,
                agentState = session.agentState,
                title = session.title,
                isActiveSession = _activeSessionId.value == session.id,
            )
        }

        // Prune stale local per-session state (names, agents, cached terminals)
        // to the server's authoritative list. Anything absent was attached
        // elsewhere, terminated, or lost on a server restart. This is bookkeeping
        // only — ownership is NOT persisted, so there is nothing to "unclaim".
        for (id in ownershipStore.names.keys.toList()) {
            if (id !in serverIds) setNameLocal(id, null)
        }
        for (id in ownershipStore.agents.keys.toList()) {
            if (id !in serverIds) activityCoordinator.forgetSession(id)
        }
        val prunedTerminals = terminalCache.pruneStale(serverIds)
        for (id in prunedTerminals) {
            if (id !in serverIds) activityCoordinator.forgetSession(id)
        }
    }

    // MARK: - Session-op tracking

    /**
     * Count of session ops (create / switch / attach) currently mid-flight.
     * Confined to the coordinator's serial dispatcher, so plain Int is safe.
     *
     * Ops make the attachment state transiently inconsistent BY DESIGN at their
     * suspension points: `withAuth { detach(); create/resume(...) }` leaves
     * `sessionController.sessionId` null (post-detach) or already-new while
     * `_activeSessionId` still holds the previous id until the op commits. A
     * recovery pass that evaluates [needsSessionRestore] in one of those gaps
     * would misread the op as a stale attachment and resume the OLD active id
     * concurrently with the op's own resume — two resumes racing on one
     * connection (the server holds ONE attached PTY per handler), ending in a
     * black terminal or output routed to the wrong VM. While an op is in
     * flight, [needsSessionRestore] therefore reports false: the op is already
     * establishing a fresh, valid attachment (or surfacing its own error), and
     * the next trigger re-evaluates against settled state.
     */
    private var sessionOpsInFlight = 0

    /** Best-known terminal geometry (cols to rows) from the latest resize; seeds
     *  the next `session_create`. Null until the first terminal lays out. */
    @Volatile
    private var lastKnownTerminalSize: Pair<UShort, UShort>? = null

    /** Called by the workspace layer whenever the terminal reports a new size. */
    fun recordTerminalSize(cols: Int, rows: Int) {
        if (cols <= 0 || rows <= 0) return
        lastKnownTerminalSize = cols.toUShort() to rows.toUShort()
    }

    // MARK: - Create (SharedSessionCoordinator.swift:388-421)

    suspend fun createNewSession() {
        if (recoveryController.isRecovering.value) return
        val previousId = _activeSessionId.value
        sessionOpsInFlight += 1
        try {
            val name = pickDefaultName()
            // withAuth: detach the previous session (best-effort), then create.
            val sessionId = authCoordinator.withAuth {
                if (previousId != null) runCatching { sessionController.detach() }
                val size = lastKnownTerminalSize
                sessionController.createSession(name, size?.first, size?.second)
            }

            previousId?.let {
                terminalCache.view(it)?.prepareForSwitch()
                terminalCache.evict(it)
            }

            // Optimistically show the new session; the forced fetch below
            // replaces `_sessions` with the authoritative token-scoped list.
            addSessionLocal(SessionInfo(sessionId, name, SessionState.ACTIVE_ATTACHED,
                sessionController.tokenId ?: "", 0.0, 0u, 0u, null, null, null, null, null))
            setNameLocal(sessionId, name)

            terminalCache.put(sessionId, newTerminalVm())
            wireTerminalOutput(sessionId)
            _activeSessionId.value = sessionId
            activityCoordinator.markSeen(sessionId)
            terminalCache.touch(sessionId)
            terminalCache.enforceLimit(_activeSessionId.value)

            // force: bypass the debounce so the just-created session lands in
            // `_sessions` immediately (it may be < 500 ms since connect()'s fetch).
            fetchSessions(force = true)
        } catch (e: Throwable) {
            presentError(e.message ?: "Failed to create session")
        } finally {
            sessionOpsInFlight -= 1
        }
    }

    // MARK: - Switch (SharedSessionCoordinator.swift:425-458)

    suspend fun switchToSession(id: UUID) {
        if (recoveryController.isRecovering.value) return
        // Re-selecting the ALREADY-active session is a repaint request, not a
        // switch: the user tapped the session they're already on because its
        // terminal looks blank/stale (e.g. after returning from the background).
        // Route it through the foreground-restore path (resume + re-feed the live
        // emulator) instead of the old early-return no-op that left them stuck.
        // Do NOT run the full SWITCH sequence here — that would detach() then
        // resume() the same session, needlessly orphaning it mid-op.
        if (id == _activeSessionId.value) {
            restoreActiveOnForeground()
            return
        }
        val previousId = _activeSessionId.value
        sessionOpsInFlight += 1
        try {
            if (previousId != null && previousId != id) {
                terminalCache.view(previousId)?.prepareForSwitch()
            }

            // Prepare the incoming VM and wire output BEFORE resumeSession so
            // binary replay frames route to the correct VM from the first frame
            // (SharedSessionCoordinator.swift:433-434).
            val incoming = terminalCache.view(id)
            if (incoming == null) {
                terminalCache.put(id, newTerminalVm())
            } else {
                incoming.prepareForReplay()
            }
            terminalCache.view(id)?.beginReplay()
            wireTerminalOutput(id) // BEFORE resume (route replay frames correctly).

            authCoordinator.withAuth {
                if (previousId != null) runCatching { sessionController.detach() }
                sessionController.resumeSession(id, skipReplay = false)
            }

            _activeSessionId.value = id
            activityCoordinator.markSeen(id)
            terminalCache.touch(id)
            terminalCache.enforceLimit(_activeSessionId.value)

            fetchSessions()
        } catch (e: Throwable) {
            presentError(e.message ?: "Failed to switch session")
        } finally {
            sessionOpsInFlight -= 1
        }
    }

    // MARK: - Attach (SharedSessionCoordinator.swift:462-561)

    /** Lists sessions running on the server (across all tokens) that aren't
     *  already in this token's pane, so they can be attached from another
     *  device. Filtered against the token-scoped `_sessions` (what the pane
     *  shows now) so we never offer a session we already own. */
    suspend fun fetchAttachableSessions(): List<SessionInfo> =
        runCatching {
            val shownIds = _sessions.value.map { it.id }.toSet()
            authCoordinator.withAuth { sessionController.listAllSessions() }
                .filter { !it.state.isTerminal && it.id !in shownIds }
        }.getOrElse { e ->
            // Surface the failure instead of silently returning an empty list —
            // otherwise a transient RPC error reads to the user as the misleading
            // "No Sessions Available" even when sessions exist on the server.
            presentError(e.message ?: "Couldn't load sessions from the server. Try again.")
            emptyList()
        }

    suspend fun attachRemoteSession(id: UUID, serverName: String? = null) {
        if (recoveryController.isRecovering.value) return
        val previousId = _activeSessionId.value
        sessionOpsInFlight += 1
        try {
            authCoordinator.withAuth {
                if (previousId != null) runCatching { sessionController.detach() }
                sessionController.attachSession(id)
            }

            if (previousId != null && previousId != id) {
                terminalCache.view(previousId)?.prepareForSwitch()
                terminalCache.evict(previousId)
            }

            // Optimistically show the just-attached session; the forced fetch
            // below reconciles against the authoritative token-scoped list
            // (attach reassigned its token to us, so it's now listed).
            addSessionLocal(SessionInfo(id, serverName, SessionState.ACTIVE_ATTACHED,
                sessionController.tokenId ?: "", 0.0, 0u, 0u, null, null, null, null, null))
            val vm = newTerminalVm()
            vm.beginReplay()
            terminalCache.put(id, vm)
            wireTerminalOutput(id)
            _activeSessionId.value = id
            activityCoordinator.markSeen(id)
            terminalCache.touch(id)
            terminalCache.enforceLimit(_activeSessionId.value)

            if (serverName != null) {
                setNameLocal(id, serverName)
            } else if (_sessionNames.value[id] == null) {
                val name = pickDefaultName()
                setNameLocal(id, name)
                runCatching { sessionController.renameSession(id, name) }
            }

            // force: bypass the debounce so the authoritative server list (now
            // including the just-attached session under our token) lands promptly.
            fetchSessions(force = true)
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
        } finally {
            sessionOpsInFlight -= 1
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
            activityCoordinator.forgetSession(id)
            // Drop from the pane immediately; the fetch below reconciles against
            // the server list (which no longer includes the terminated session).
            removeSessionLocal(id)
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
                onSessionActivity(message.sessionId, message.activity, message.agent, message.agentState, message.title)
            is ServerMessage.SessionStolen -> onSessionStolen(message.sessionId)
            is ServerMessage.SessionRenamed -> onSessionRenamed(message.sessionId, message.name)
            is ServerMessage.ReplayComplete -> onReplayComplete(message.sessionId)
            is ServerMessage.SessionStateMsg -> onSessionState(message.sessionId, message.state)
            else -> Unit // pongs/acks/list-results handled elsewhere.
        }
    }

    private fun onSessionActivity(sessionId: UUID, activity: ActivityState, agent: String?, agentState: relay.protocol.AgentDetectedState?, title: String?) {
        activityCoordinator.applyActivity(
            sessionId,
            activity,
            agent,
            agentState = agentState,
            title = title,
            isActiveSession = _activeSessionId.value == sessionId,
        ) { id, isActive ->
            terminalCache.view(id)?.isAgentActive = isActive
        }
    }

    private fun onSessionStolen(sessionId: UUID) {
        // The server sends `session_stolen` to this (previous-owner) token when
        // ANOTHER client attaches a session we currently hold. Act only if it's
        // still in our pane / active, so a duplicate or late push doesn't
        // re-raise the alert for an already-handled session.
        if (_sessions.value.none { it.id == sessionId } && _activeSessionId.value != sessionId) return
        cleanUpStolenSession(sessionId)
    }

    /**
     * Handles a session attached by another client: removes it from the pane and
     * (optionally) raises the "attached by another client" popup. The pane is the
     * server's token-scoped list, so we drop it from `_sessions` directly (there
     * is no owned set to unclaim).
     *
     * @param alert raise the popup. True for the live `session_stolen` push.
     * @param refetch re-run `fetchSessions` afterward. False when called from
     *   inside a fetch pass to avoid re-entrancy.
     */
    fun cleanUpStolenSession(sessionId: UUID, alert: Boolean = true, refetch: Boolean = true) {
        // Remove from the UI FIRST (clear active, drop from the pane, evict the
        // terminal), THEN raise the popup — so when the user taps OK the UI is
        // already clean. Matches Swift `cleanUpStolenSession` ordering.
        if (_activeSessionId.value == sessionId) _activeSessionId.value = null
        removeSessionLocal(sessionId)
        evictTerminal(sessionId)
        if (alert) {
            activityCoordinator.sessionStolen(sessionId) { name(it) }
        } else {
            activityCoordinator.forgetSession(sessionId)
        }
        // force: bypass the debounce so a list response snapshotted before the
        // server's token reassignment can't slip in and re-add the stolen row.
        if (refetch) scope.launch { fetchSessions(force = true) }
    }

    private fun onSessionRenamed(sessionId: UUID, name: String) {
        setNameLocal(sessionId, name)
    }

    private fun onReplayComplete(sessionId: UUID) {
        // Key strictly on the message's sessionId, not the active session
        // (SharedSessionCoordinator.swift:211-214). A late replay_complete during
        // a fast switch must end replay on the VM it names, not on whichever VM
        // happens to be active by the time it arrives.
        terminalCache.view(sessionId)?.endReplay()
    }

    private fun onSessionState(sessionId: UUID, state: String) {
        // The server pushes coarse state transitions; refresh the list so the
        // sidebar reflects them.
        scope.launch { fetchSessions() }
    }

    // MARK: - Terminal output wiring

    /**
     * Creates a [TerminalSessionVm] on the coordinator's [scope], so its
     * input-prompt silence debounce launches on the same dispatcher the
     * coordinator runs on — the Android analogue of Swift's shared `@MainActor`
     * isolation between the coordinator and its view models.
     */
    private fun newTerminalVm() = TerminalSessionVm(scope = scope)

    /**
     * Routes the connection's binary terminal output to the VM for [sessionId].
     * The connection has a single `onTerminalOutput` slot, so wiring a new
     * session replaces the previous routing — exactly the Swift single-slot model
     * (SharedSessionCoordinator.swift:635-645).
     */
    fun wireTerminalOutput(sessionId: UUID) {
        // Prime `isAgentActive` from the current agent map so the silence
        // detector picks the 2 s (agent) threshold immediately on wire, before
        // the next `sessionActivity` event (SharedSessionCoordinator.swift:636-638).
        terminalCache.view(sessionId)?.isAgentActive =
            activityCoordinator.isRunningAgent(sessionId)
        connection.onTerminalOutput = { data ->
            terminalCache.view(sessionId)?.receiveOutput(data)
        }
        // M4: Swift also wires `onTitleChanged → terminalTitles` (:642-644);
        // TerminalSessionVm has no `onTitleChanged` yet, so that stays deferred
        // to when the Termux bridge lands the title callback.
    }

    /**
     * The recovery `resumeActive` collaborator. Mirrors Swift `restoreSession`'s
     * resume block exactly (RecoveryController.swift:243-248):
     *   resetForReplay() → resumeSession → wireTerminalOutput (wire AFTER resume).
     *
     * This deliberately does NOT use the SWITCH semantics (prepareForReplay +
     * beginReplay + wire-BEFORE). Recovery resumes the SAME already-active
     * session whose output handler is still wired, so `resetForReplay()` blanks
     * the live terminal with RIS (ESC c) via the current handler, the resume
     * replays scrollback, and we re-affirm the wire after resume. We do not enter
     * buffering mode (`beginReplay`) here because Swift does not — the scrollback
     * arrives on the live handler and renders directly, matching the source of
     * truth. No-op when there is no active session.
     */
    private suspend fun resumeActiveForRecovery() {
        val activeId = _activeSessionId.value ?: return
        terminalCache.view(activeId)?.resetForReplay()
        sessionController.resumeSession(activeId, skipReplay = false)
        wireTerminalOutput(activeId)
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

    /**
     * Force-repaint the active session's terminal when the app returns to the
     * foreground. This is the fix for the "reopen lands on a blank/dead terminal"
     * bug: after a plain background→foreground the WebSocket can stall WITHOUT the
     * connection being replaced, so `needsSessionRestore()` is false (sessionId and
     * attachedGeneration both still match) and `isAlive()` may briefly report true
     * on the half-dead socket. `handleForegroundTransition()` then short-circuits
     * to a bare `fetchSessions()` and the cached emulator is never re-fed — the
     * user sees the green dot and ticking uptime over an empty grid, and tapping
     * the session does nothing.
     *
     * Unlike that heuristic path, this ALWAYS repaints when a session is active:
     *  - **Dead socket** (`!isAlive()`): defer to full recovery (reconnect →
     *    reauth → resume) via [RecoveryController.triggerUserRecovery]; a bare
     *    resume on a dead socket can't work, and recovery owns the breaker/backoff.
     *  - **Live socket**: resume the active session directly on the live transport.
     *    The server's resume handler is idempotent and ALWAYS replays scrollback +
     *    re-wires PTY output (`repaintAfter: true`, SessionRequestHandlers.swift:140),
     *    so this re-feeds the live emulator and the terminal repaints in place. The
     *    resume goes through `withAuth` so a silently-expired auth re-authenticates
     *    once. No-op while a session op is mid-flight or recovery is already running
     *    (those are already establishing a fresh attachment).
     *
     * Called from the UI on `ON_RESUME` (alongside, not replacing,
     * [handleForegroundTransition], which still covers the network-restored and
     * dead-socket cases). Also the target of a re-tap on the active session in the
     * sidebar (see [switchToSession]).
     */
    fun restoreActiveOnForeground() {
        if (recoveryController.isRecovering.value) return
        if (sessionOpsInFlight > 0) return
        val activeId = _activeSessionId.value
        if (activeId == null) {
            // No active session to repaint, but the transport may still have died
            // in the background — let the recovery path reconnect + refresh the
            // sidebar (it short-circuits to a fetch if the socket is fine). This
            // keeps restoreActiveOnForeground the single ON_RESUME entry point.
            recoveryController.triggerUserRecovery()
            return
        }
        scope.launch {
            // A dead transport can't be repainted by a bare resume — hand off to
            // the full recovery state machine (reconnect → reauth → resume).
            if (!connection.isAlive()) {
                recoveryController.triggerUserRecovery()
                return@launch
            }
            // Live socket: resume in place so the server replays scrollback into
            // the live emulator. Guard the whole op with sessionOpsInFlight so a
            // concurrent recovery trigger reads a consistent attachment state (the
            // same protection the create/switch/attach ops use).
            sessionOpsInFlight += 1
            try {
                authCoordinator.withAuth {
                    sessionController.resumeSession(activeId, skipReplay = false)
                }
                // Re-wire AFTER the resume (recovery semantics), so the replayed
                // scrollback routes to the active VM's live output handler.
                wireTerminalOutput(activeId)
            } catch (e: Throwable) {
                // A live-socket resume that still fails is most likely a transient
                // attachment race; fall back to the full recovery path rather than
                // surfacing an error over a working connection.
                if (e !is kotlinx.coroutines.CancellationException) {
                    recoveryController.triggerUserRecovery()
                }
            } finally {
                sessionOpsInFlight -= 1
            }
        }
    }

    /** Explicit user-initiated recovery (QR rescan, manual retry). */
    fun triggerUserRecovery() {
        recoveryController.triggerUserRecovery()
    }

    /**
     * Whether the active session's server-side attachment is stale on the
     * CURRENT connection. The server holds the attached PTY per connection
     * handler, so a socket replacement (or a recovery pass whose reconnect
     * succeeded but whose resume failed) leaves the session orphaned: the
     * transport is healthy and pongs normally, but the server SILENTLY drops
     * typed bytes (`handleBinaryFrame`'s `guard isAuthenticated, let pty =
     * attachedPTY else { return }`). This is the recovery controller's
     * `needsRestore` collaborator — it converts "alive" short-circuits into
     * restore passes when the attachment is stale (the sleep/wake bug).
     *
     * False when no session is active (nothing to restore — includes the
     * post-app-level-failure state, where the failed restore already cleared
     * the active id, and the post-steal state, where `onSessionStolen` did).
     *
     * Also false while a session op (create / switch / attach) is mid-flight:
     * ops put the controller and `_activeSessionId` in transiently mismatched
     * states at their suspension points, and the op is already establishing a
     * fresh attachment — see [sessionOpsInFlight] for the race this prevents.
     */
    internal fun needsSessionRestore(): Boolean {
        if (sessionOpsInFlight > 0) return false
        val activeId = _activeSessionId.value ?: return false
        return sessionController.sessionId != activeId || !sessionController.isAttachmentValid
    }

    /**
     * Signals that the user just sent input (a keystroke / utterance). Because
     * OkHttp's `WebSocket.send()` returns `true` as soon as bytes are *enqueued*
     * — not delivered — a keystroke over a half-open socket vanishes silently and
     * never trips [CoordinatorConnection.onSendFailed]. Without this hook the only
     * thing that notices a dead socket is the 10 s keepalive's three-failure death
     * detector, leaving a 30–45 s window where typing does nothing and the user
     * must reconnect by hand (the reported bug).
     *
     * This collapses that window: when input is sent and the transport has not
     * proven healthy within [ACTIVITY_HEALTH_STALE_MS], it drives a user-initiated
     * recovery. Routing through [RecoveryController.triggerUserRecovery] (not the
     * auto path) is deliberate — active typing is an unambiguous "I want this
     * connection" signal, so it also clears the auto-recovery circuit breaker,
     * self-healing the case where repeated outages had suspended auto-recovery.
     * `triggerUserRecovery` then short-circuits via its own `isAlive` probe if the
     * socket turns out to be fine, so a healthy connection pays only a single ~5 s
     * probe, never a reconnect.
     *
     * Throttled to one probe per [ACTIVITY_PROBE_THROTTLE_MS] so a burst of
     * keystrokes fires at most one liveness check. A no-op while recovery is
     * already in flight (the dispatch lock in the controller also guards this).
     */
    fun notifyUserActivity() {
        val now = nowMs()
        val lastProbe = lastActivityProbeMs
        if (lastProbe != null && now - lastProbe < ACTIVITY_PROBE_THROTTLE_MS) return

        // A healthy transport only excuses the probe when the session attachment
        // is also current. After a failed restore the socket pongs forever while
        // the server drops this very keystroke (no attached PTY) — typing is the
        // strongest "I need this session NOW" signal, so route it into recovery,
        // whose alive-restore path resumes without a reconnect.
        val healthyAt = lastHealthyAtMs
        if (healthyAt != null && now - healthyAt < ACTIVITY_HEALTH_STALE_MS && !needsSessionRestore()) return

        lastActivityProbeMs = now
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

    companion object {
        /** fetchSessions debounce window, ms (Swift `0.5` s, :309). */
        private const val FETCH_DEBOUNCE_MS = 500L

        /**
         * How stale the last health evidence must be before a keystroke triggers
         * a liveness probe. Set just above the 10 s keepalive interval so steady
         * typing on a healthy connection (which sees a pong every 10 s) never
         * probes, but a socket that has gone quiet does.
         */
        private const val ACTIVITY_HEALTH_STALE_MS = 12_000L

        /** Minimum spacing between input-activity liveness probes. */
        private const val ACTIVITY_PROBE_THROTTLE_MS = 5_000L

        /**
         * Pure derivation of the pane list from the server's token-scoped
         * session list. The server is authoritative for ownership, so this only
         * drops terminal sessions and sorts by [SessionInfo.createdAt] ascending.
         * No local owned-set filter (mirrors Swift `activeSessions`).
         */
        fun computeActiveSessions(all: List<SessionInfo>): List<SessionInfo> =
            all.filter { !it.state.isTerminal }
                .sortedBy { it.createdAt }
    }
}
