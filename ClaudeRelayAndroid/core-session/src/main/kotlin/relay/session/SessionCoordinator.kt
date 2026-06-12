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
    // M4: populated by the OSC-title → terminalTitles wiring in wireTerminalOutput
    // once TerminalSessionVm gains an `onTitleChanged` callback
    // (SharedSessionCoordinator.swift:642-644). Today only terminate clears it.
    val terminalTitles: StateFlow<Map<UUID, String>> = _terminalTitles.asStateFlow()

    private val _ownedSessionIds = MutableStateFlow<Set<UUID>>(emptySet())
    val ownedSessionIds: StateFlow<Set<UUID>> = _ownedSessionIds.asStateFlow()

    /**
     * The filtered + sorted session list the tab bar and sidebar render — NOT the
     * raw [sessions]. Recomputed from the raw list + owned-id set via the pure
     * [computeActiveSessions] whenever either changes (see [recomputeActiveSessions],
     * called from the same mutation points that update [_sessions] / [_ownedSessionIds]).
     *
     * Backed by a plain [MutableStateFlow] rather than `combine(...).stateIn(...)`
     * on purpose: every other flow here is a `MutableStateFlow`, and an eager
     * `stateIn` collector launched on [scope] never completes, which strands a
     * coroutine under `runTest` in the coordinator's unit tests. The push model
     * keeps the same single-(main)-dispatcher confinement the rest of the type uses.
     *
     * Source of truth: SharedSessionCoordinator.swift:92-96
     * ```
     * public var activeSessions: [SessionInfo] {
     *     sessions
     *         .filter { !$0.state.isTerminal && ownedSessionIds.contains($0.id) }
     *         .sorted { $0.createdAt < $1.createdAt }
     * }
     * ```
     * Filter: keep non-terminal sessions this device owns. Sort: `createdAt`
     * ASCENDING (Swift `$0.createdAt < $1.createdAt`).
     */
    private val _activeSessions = MutableStateFlow<List<SessionInfo>>(emptyList())
    val activeSessions: StateFlow<List<SessionInfo>> = _activeSessions.asStateFlow()

    /** Re-derives [activeSessions] from the current raw list + owned set. */
    private fun recomputeActiveSessions() {
        _activeSessions.value = computeActiveSessions(_sessions.value, _ownedSessionIds.value)
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

        // Hydrate the published mirrors from the persisted store.
        _sessionNames.value = ownershipStore.names
        _ownedSessionIds.value = ownershipStore.owned
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
        recomputeActiveSessions()
    }

    private fun unclaimSession(id: UUID) {
        ownershipStore.unclaim(id)
        _ownedSessionIds.value = ownershipStore.owned
        recomputeActiveSessions()
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
    suspend fun fetchSessions(force: Boolean = false) {
        // 0.5 s debounce keyed on the injected [nowMs] clock (Swift :308-310).
        // The first fetch (lastFetchMs == null, Swift `.distantPast`) always
        // passes; subsequent calls within 500 ms are dropped.
        //
        // [force] bypasses the debounce for post-mutation fetches (create / attach):
        // those MUST refresh `_sessions` so the just-claimed id appears in the pane.
        // Without it, a create/attach that lands < 500 ms after connect()'s initial
        // fetch is debounced away, leaving the session `owned` but absent from
        // `_sessions` → `computeActiveSessions` filters it out → it's invisible until
        // some later fetch (the "sometimes not visible after attach" symptom).
        val last = lastFetchMs
        if (!force && last != null && nowMs() - last < FETCH_DEBOUNCE_MS) return
        lastFetchMs = nowMs()

        _isLoading.value = true
        try {
            doFetchSessions()
        } finally {
            _isLoading.value = false
        }
    }

    private suspend fun doFetchSessions() {
        // The pane list is TOKEN-scoped (sessions created/attached under THIS
        // connection's token) — `session_list`.
        val list = runCatching { authCoordinator.withAuth { sessionController.listSessions() } }
            .getOrElse { return }
        _sessions.value = list
        recomputeActiveSessions()

        // The PRUNE existence set is TOKEN-AGNOSTIC — `session_list_all` lists every
        // session the server still holds, across all tokens. We prune local
        // ownership/names/agents against THIS, not the token-scoped `list`, because
        // ownership is device-scoped: a session this device created/attached under a
        // DIFFERENT token (e.g. another device attached it, or a prior launch used a
        // different token) is absent from `list` but still very much alive. Pruning
        // against the token-scoped list would permanently unclaim it → the session
        // vanishes from the pane with no recovery (the reported bug). The server
        // REMOVES terminated/cleaned-up sessions from its store (SessionManager
        // `sessions.removeValue`), so a truly-dead session is absent from
        // `session_list_all` too and is still pruned correctly. The dedicated
        // `session_stolen` push handles the "another device took it" case.
        //
        // If the all-sessions RPC fails, fall back to the token-scoped ids — but
        // since that risks the over-prune above, treat a failure as "prune nothing"
        // (null) rather than "prune everything not on this token".
        val existsIds: Set<UUID>? = runCatching {
            authCoordinator.withAuth { sessionController.listAllSessions() }.map { it.id }.toSet()
        }.getOrNull()

        // Adopt any server-provided names.
        for (session in list) {
            session.name?.let { setNameLocal(session.id, it) }
        }

        // Re-apply each session's activity so the sidebar reflects server state.
        for (session in list) {
            activityCoordinator.applyActivity(session.id, session.activity ?: ActivityState.IDLE, session.agent)
        }

        // Only prune when we have an authoritative all-sessions set; a failed
        // all-sessions fetch must NOT trigger unclaims (see above).
        if (existsIds != null) {
            // Prune names for sessions gone from the server entirely.
            for (id in ownershipStore.names.keys.toList()) {
                if (id !in existsIds) setNameLocal(id, null)
            }
            // Prune owned ids only when truly gone from the server (any token).
            for (id in ownershipStore.owned.toList()) {
                if (id !in existsIds) unclaimSession(id)
            }
            // Prune agents gone from the server, forgetting their activity state too.
            for (id in ownershipStore.agents.keys.toList()) {
                if (id !in existsIds) activityCoordinator.forgetSession(id)
            }
            // Evict cached terminals for sessions that no longer exist on the server.
            val prunedTerminals = terminalCache.pruneStale(existsIds)
            // Forget activity for any pruned terminal whose id wasn't already handled
            // above (e.g. a cached terminal with no agent entry).
            for (id in prunedTerminals) {
                if (id !in existsIds) activityCoordinator.forgetSession(id)
            }
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
                sessionController.createSession(name)
            }

            previousId?.let {
                terminalCache.view(it)?.prepareForSwitch()
                terminalCache.evict(it)
            }

            // claim → name BEFORE wiring; wire AFTER the RPC (create/attach wire after).
            claimSession(sessionId)
            setNameLocal(sessionId, name)

            terminalCache.put(sessionId, newTerminalVm())
            wireTerminalOutput(sessionId)
            _activeSessionId.value = sessionId
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
        if (recoveryController.isRecovering.value || id == _activeSessionId.value) return
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
        } finally {
            sessionOpsInFlight -= 1
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

            // claim → beginReplay → wire AFTER the RPC (attach wires after).
            claimSession(id)
            val vm = newTerminalVm()
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

            // force: bypass the debounce so the just-attached session lands in
            // `_sessions` immediately (attach claims it but does not add it to
            // `_sessions` directly; a debounced fetch would leave it invisible).
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
        // Flip the matching VM's `isAgentActive` on agent entry/exit so the
        // input-prompt silence detector switches between the 1 s and 2 s
        // thresholds (SharedSessionCoordinator.swift:595-597).
        activityCoordinator.applyActivity(sessionId, activity, agent) { id, isActive ->
            terminalCache.view(id)?.isAgentActive = isActive
        }
    }

    private fun onSessionStolen(sessionId: UUID) {
        val wasActive = _activeSessionId.value == sessionId

        // Only raise the "Session Moved" alert when the user's focused terminal
        // is displaced; sidebar-only sessions disappear silently on the next list
        // refresh (SharedSessionCoordinator.swift:601-625).
        if (wasActive) {
            // sessionStolen() raises the alert AND relinquishes ownership
            // (unclaims internally) — do NOT double-unclaim here.
            activityCoordinator.sessionStolen(sessionId) { name(it) }
            _activeSessionId.value = null
        } else {
            // Silent path: forget activity state WITHOUT raising the alert.
            // forgetSession() does NOT unclaim (only sessionStolen() does), so
            // unclaim explicitly to match Swift, which unclaims in both branches
            // (SharedSessionCoordinator.swift:615, :622).
            activityCoordinator.forgetSession(sessionId)
            unclaimSession(sessionId)
        }

        // Refresh the owned-id mirror (covers the active branch's internal
        // unclaim), then evict + fetch in BOTH branches
        // (SharedSessionCoordinator.swift:622-625).
        _ownedSessionIds.value = ownershipStore.owned
        recomputeActiveSessions()
        evictTerminal(sessionId)
        scope.launch { fetchSessions() }
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
         * Pure derivation of the active-session list, factored out so it is
         * unit-testable without Android or coroutines. Mirrors the Swift
         * `activeSessions` computed property exactly
         * (SharedSessionCoordinator.swift:92-96):
         *  - filter: keep sessions that are NOT terminal AND that [owned] contains.
         *  - sort: by [SessionInfo.createdAt] ASCENDING (Swift `$0.createdAt < $1.createdAt`).
         */
        fun computeActiveSessions(all: List<SessionInfo>, owned: Set<UUID>): List<SessionInfo> =
            all.filter { !it.state.isTerminal && it.id in owned }
                .sortedBy { it.createdAt }
    }
}
