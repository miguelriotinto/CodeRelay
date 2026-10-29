package relay.session.hub

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import relay.protocol.ConnectionConfig
import relay.protocol.SessionInfo
import relay.protocol.SessionRef
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

/**
 * One workspace across several relays (multi-server spec §7).
 *
 * Owns one slot per ENABLED bookmark, merges their state into [sections], and
 * holds the single global active session ([activeRef]). It never talks to the
 * network, runs recovery, or holds terminal views — those stay in the
 * coordinators, unchanged. Not thread-safe: confined to [scope]'s single
 * dispatcher like the coordinators it owns.
 *
 * Port of `Sources/CodeRelayClient/Hub/ServerHub.swift` including both review
 * fix passes; keep the two in step. Selection and deep links live in
 * `ServerHubSelection.kt`.
 */
class ServerHub<S : ServerSlot>(
    internal val scope: CoroutineScope,
    internal val bookmarkStore: BookmarkStore,
    internal val tokens: TokenSource,
    internal val state: HubStateStore,
    private val factory: (ConnectionConfig, String) -> S,
    /** Runs once at the top of the first [start] (the one-time [HubMigration]). */
    private val migration: (suspend () -> Unit)? = null,
    private val maxEnabled: Int = MAX_ENABLED,
    private val staggerMs: Long = 150,
    /** Bound on the previous server's detach before a cross-server attach (spec §7.5). */
    internal val detachBudgetMs: Long = 3_000,
    private val sleepMs: suspend (Long) -> Unit = { delay(it) },
) {
    // MARK: - Published state

    private val _sections = MutableStateFlow<List<ServerSection>>(emptyList())
    val sections: StateFlow<List<ServerSection>> = _sections.asStateFlow()

    internal val activeRefFlow = MutableStateFlow<SessionRef?>(null)
    val activeRef: StateFlow<SessionRef?> = activeRefFlow.asStateFlow()

    private val _aggregate = MutableStateFlow(HubAggregate())
    val aggregate: StateFlow<HubAggregate> = _aggregate.asStateFlow()

    internal val noticeFlow = MutableStateFlow<String?>(null)
    /** User-facing notices the hub produces (deep-link enable, cap refusal…). */
    val notice: StateFlow<String?> = noticeFlow.asStateFlow()
    fun setNotice(text: String?) { noticeFlow.value = text }

    private val _isShowingServerList = MutableStateFlow(false)
    /** UI-only: the server management screen is being shown. */
    val isShowingServerList: StateFlow<Boolean> = _isShowingServerList.asStateFlow()
    fun setShowingServerList(show: Boolean) { _isShowingServerList.value = show }

    private val _activeSlot = MutableStateFlow<S?>(null)
    /** The slot that owns [activeRef], if it is built. */
    val activeSlot: StateFlow<S?> = _activeSlot.asStateFlow()

    private val _focusServerId = MutableStateFlow<UUID?>(null)
    private val _focusSlot = MutableStateFlow<S?>(null)
    /**
     * The slot the single-server surfaces (QR scan, Attach, the Reconnecting
     * sheet, error alerts) follow: the active one, else the only enabled one,
     * else the first live one. A one-server user keeps every pre-hub surface (G8).
     */
    val focusSlot: StateFlow<S?> = _focusSlot.asStateFlow()
    val focusServerId: StateFlow<UUID?> = _focusServerId.asStateFlow()

    // MARK: - State

    internal var bookmarks: List<ConnectionConfig> = emptyList()
    internal val slots = mutableMapOf<UUID, S>()
    private val slotJobs = mutableMapOf<UUID, Job>()
    internal val cachedSessions = mutableMapOf<UUID, List<SessionInfo>>()
    internal val missingToken = mutableSetOf<UUID>()
    private var collapsedServers: Set<UUID> = state.loadCollapsedServers()
    internal var started = false
    /** Completed when the first [start] returns; deep links wait on it. */
    internal val startCompleted = CompletableDeferred<Unit>()
    /** The one selection waiting for its server to come live (always == activeRef while set). */
    internal var pendingRef: SessionRef? = null
    /** Bumped by every selection path; a path resuming after an `await` into a newer generation stops. */
    internal var selectionGeneration = 0L
    /** Selections between their first and last `await`; [reconcileSelection] stays out of the way. */
    internal var selectionsInFlight = 0
    /** The last push settings synced; slots built later get the same. */
    private var pushSettings: PushSettings? = null

    val enabledCount: Int get() = bookmarks.count { it.enabled }

    fun slot(serverId: UUID): S? = slots[serverId]

    // MARK: - Lifecycle (spec §7.3)

    /**
     * Builds a slot per enabled bookmark — concurrently, each after its own
     * stagger, so one unreachable relay's handshake never delays the next (D10)
     * — then publishes. Returns once every build finished or was skipped;
     * [stop] makes the remaining builds no-ops.
     */
    suspend fun start() {
        if (started) return
        started = true
        try {
            migration?.invoke()
            bookmarks = bookmarkStore.loadAll()
            // F3 across servers (§9): restore the last active ref as a pending
            // selection, applied once that server's live list proves it exists.
            val saved = state.loadActiveRef()
            if (saved != null && bookmarks.any { it.id == saved.serverId && it.enabled }) {
                activeRefFlow.value = saved
                pendingRef = saved
            } else {
                state.saveActiveRef(null)
            }
            publish()
            coroutineScope {
                bookmarks.filter { it.enabled }.forEachIndexed { index, config ->
                    launch {
                        sleepMs(staggerMs * index)
                        if (started) buildSlot(config)
                    }
                }
            }
            publish()
        } finally {
            startCompleted.complete(Unit)
        }
    }

    fun stop() {
        val retiring = slots.values.toList()
        slots.clear()
        slotJobs.values.forEach { it.cancel() }
        slotJobs.clear()
        started = false
        pendingRef = null
        retiring.forEach { slot -> scope.launch { slot.tearDown() } }
        publish()
    }

    /**
     * Re-reads the bookmark store (after add / edit / delete / pair) and
     * reconciles slots: new enabled bookmarks get one, removed or disabled ones
     * are retired, edited ones (host/port/TLS) are rebuilt. Add and pair save
     * bookmarks enabled, so the cap (D12) is enforced here.
     */
    suspend fun reloadBookmarks() {
        var fresh = bookmarkStore.loadAll()
        var enabledNow = fresh.count { it.enabled }
        if (enabledNow > maxEnabled) {
            fresh = fresh.reversed().map { c ->
                if (c.enabled && !slots.containsKey(c.id) && enabledNow > maxEnabled) {
                    enabledNow -= 1
                    noticeFlow.value = "Up to $maxEnabled servers can be enabled at once. ${c.name} was added disabled."
                    c.copy(enabled = false)
                } else {
                    c
                }
            }.reversed()
            bookmarkStore.saveAll(fresh)
        }
        val freshById = fresh.associateBy { it.id }
        for (id in slots.keys.toList()) {
            val now = freshById[id]
            if (now == null || !now.enabled) { tearDownSlot(id); continue }
            val old = bookmarks.firstOrNull { it.id == id }
            if (old != null && (old.host != now.host || old.port != now.port || old.useTLS != now.useTLS)) tearDownSlot(id)
        }
        bookmarks = fresh
        publish()
        fresh.filter { it.enabled && !slots.containsKey(it.id) }.forEach { c -> scope.launch { buildSlot(c) } }
    }

    /** Flips a bookmark's `enabled` flag and persists it. False when the cap refuses (D12); see [notice]. */
    suspend fun setEnabled(serverId: UUID, enabled: Boolean): Boolean {
        val config = bookmarks.firstOrNull { it.id == serverId } ?: return false
        if (enabled && !config.enabled && enabledCount >= maxEnabled) {
            noticeFlow.value = "Up to $maxEnabled servers can be enabled at once. Disable one first."
            return false
        }
        val updated = config.copy(enabled = enabled)
        bookmarkStore.add(updated)
        bookmarks = bookmarkStore.loadAll()
        if (enabled) {
            scope.launch { buildSlot(updated) }
        } else {
            // Spec §10: unregister push on that relay first; the cached list is kept.
            tearDownSlot(serverId, unregisterPush = true)
        }
        publish()
        return true
    }

    /** Replaces the bookmark's slot after an edit that may have changed its token (the hub cannot see the keyring). */
    fun rebuildSlot(serverId: UUID) {
        tearDownSlot(serverId)
        val config = bookmarks.firstOrNull { it.id == serverId && it.enabled }
        if (config == null) { publish(); return }
        scope.launch { buildSlot(config) }
    }

    // MARK: - Slots

    private fun isWanted(id: UUID) = started && bookmarks.firstOrNull { it.id == id }?.enabled == true

    private suspend fun buildSlot(config: ConnectionConfig) {
        // Re-read the flag: enable then disable can both run before this does,
        // and stop() may have closed the workspace.
        if (slots.containsKey(config.id) || !isWanted(config.id)) return
        val token = runCatching { tokens.loadToken(config.id) }.getOrNull()
        if (token.isNullOrEmpty()) {
            missingToken += config.id
            publish()
            return
        }
        missingToken -= config.id
        val slot = factory(config, token)
        slots[config.id] = slot
        slotJobs[config.id] = scope.launch { slot.changes.collect { slotDidChange(config.id) } }
        try {
            slot.start()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            // A rejected token or an unreachable relay: the coordinator's own
            // flags (isAuthRejected, connected) describe it in the section.
        }
        // The world may have moved while the handshake ran.
        if (!isWanted(config.id) || slots[config.id] !== slot) {
            if (slots[config.id] === slot) {
                slots.remove(config.id)
                slotJobs.remove(config.id)?.cancel()
            }
            slot.tearDown()
            return
        }
        pushSettings?.let { slot.syncPush(it) }
        slotDidChange(config.id)
    }

    /** Forgets the slot and clears a selection that pointed at it; the caller retires it. */
    internal fun detachFromHub(id: UUID): S? {
        val slot = slots.remove(id) ?: return null
        slotJobs.remove(id)?.cancel()
        if (activeRefFlow.value?.serverId == id || pendingRef?.serverId == id) {
            activeRefFlow.value = null
            pendingRef = null
            state.saveActiveRef(null)
        }
        return slot
    }

    /** Detaches and/or unregisters push within the budget, then tears the slot down. */
    internal suspend fun retire(slot: S, wasActive: Boolean, unregisterPush: Boolean) {
        val work = scope.async {
            if (wasActive) slot.detachForHub(detachBudgetMs)
            // Without synced settings there is no device id to unregister with.
            if (unregisterPush) pushSettings?.let { slot.syncPush(it.copy(pushEnabled = false)) }
        }
        withTimeoutOrNull(detachBudgetMs) { work.await() }
        slot.tearDown()
    }

    private fun tearDownSlot(id: UUID, unregisterPush: Boolean = false) {
        val slot = detachFromHub(id) ?: return
        val wasActive = slot.activeSessionId.value != null
        scope.launch { retire(slot, wasActive, unregisterPush) }
    }

    internal suspend fun slotDidChange(id: UUID) {
        val slot = slots[id] ?: return
        // Learn the relay's identity once and persist it on the bookmark (§5.2).
        val identity = slot.serverIdentity.value
        val config = bookmarks.firstOrNull { it.id == id }
        if (identity != null && config != null) {
            val name = identity.name.ifEmpty { null }
            if (config.instanceId != identity.id || config.displayName != name) {
                bookmarkStore.add(config.copy(instanceId = identity.id, displayName = name))
                bookmarks = bookmarkStore.loadAll()
            }
        }
        reconcileSelection(slot, id)
        publish()
        applyPendingSelection(id)
    }

    /**
     * The coordinator owns the attachment; the hub mirrors it. Detach, terminate,
     * a stolen session, a failed resume, the Attach sheet and the QR scanner all
     * move `activeSessionId` without going through the hub.
     */
    private fun reconcileSelection(slot: S, id: UUID) {
        if (selectionsInFlight > 0 || pendingRef != null) return
        val attached = slot.activeSessionId.value
        val active = activeRefFlow.value
        if (active != null && active.serverId == id) {
            if (attached == active.sessionId) return
            activeRefFlow.value = attached?.let { SessionRef(id, it) }
            state.saveActiveRef(activeRefFlow.value)
        } else if (active == null && attached != null) {
            activeRefFlow.value = SessionRef(id, attached)
            state.saveActiveRef(activeRefFlow.value)
        }
    }

    // MARK: - Publishing (spec §7.2, §7.6)

    internal fun publish() {
        var live = 0
        var awaiting = 0
        val built = bookmarks.map { config ->
            val slot = slots[config.id]
            var status = ServerSectionStatus.derive(
                enabled = config.enabled,
                connected = slot?.connected?.value ?: false,
                isRecovering = slot?.isRecovering?.value ?: false,
                isPerformingHandshake = slot?.isPerformingHandshake?.value ?: false,
                authRejected = slot?.isAuthRejected?.value ?: false,
            )
            if (config.enabled && config.id in missingToken) status = ServerSectionStatus.AuthFailed(NO_TOKEN)
            val liveList = slot?.sessions?.value.orEmpty()
            if (status.isLive) cachedSessions[config.id] = liveList
            val shown = if (status.isLive) liveList else cachedSessions[config.id].orEmpty()
            val waiting = if (status.isLive) slot?.sessionsAwaitingInput?.value?.size ?: 0 else 0
            if (status.isLive) { live += 1; awaiting += waiting }
            ServerSection(
                config = config, status = status, sessions = shown, isCached = !status.isLive,
                rollups = slot?.rollups(shown).orEmpty(), awaitingInput = waiting,
                isCollapsed = config.id in collapsedServers,
            )
        }
        val counts = built.mapNotNull { it.config.instanceId }.groupingBy { it }.eachCount()
        val sections = built.map { s ->
            val iid = s.config.instanceId ?: return@map s
            s.copy(isDuplicateInstance = (counts[iid] ?: 0) > 1)
        }
        if (_sections.value != sections) _sections.value = sections
        val agg = HubAggregate(live, bookmarks.size, enabledCount, awaiting)
        if (_aggregate.value != agg) _aggregate.value = agg
        _activeSlot.value = activeRefFlow.value?.let { slots[it.serverId] }
        val enabled = bookmarks.filter { it.enabled }
        val focusId = activeRefFlow.value?.serverId?.takeIf { slots.containsKey(it) }
            ?: enabled.singleOrNull()?.id?.takeIf { slots.containsKey(it) }
            ?: sections.firstOrNull { it.status.isLive && slots.containsKey(it.id) }?.id
        _focusServerId.value = focusId
        _focusSlot.value = focusId?.let { slots[it] }
    }

    // MARK: - Fan-out (spec §7.3, D10)

    /**
     * Foreground / network restored: every enabled slot gets the event, each
     * after its own stagger so N servers do not reconnect in lockstep. Offline
     * ones are included — this is how they come back.
     */
    fun handleForegroundTransition() {
        bookmarks.filter { it.enabled }.mapNotNull { slots[it.id] }.forEachIndexed { index, slot ->
            scope.launch {
                sleepMs(staggerMs * index)
                slot.handleForegroundTransition()
            }
        }
    }

    /** One server (the section's Retry) or every server. */
    fun triggerUserRecovery(serverId: UUID? = null) {
        if (serverId != null) slots[serverId]?.triggerUserRecovery() else slots.values.forEach { it.triggerUserRecovery() }
    }

    /** Push registration is per relay: each slot decides and sends for its own socket (spec §10). */
    suspend fun syncPushRegistration(settings: PushSettings) {
        pushSettings = settings
        slots.values.toList().forEach { it.syncPush(settings) }
    }

    // MARK: - Collapse (per device)

    fun setCollapsed(serverId: UUID, collapsed: Boolean) {
        collapsedServers = if (collapsed) collapsedServers + serverId else collapsedServers - serverId
        state.saveCollapsedServers(collapsedServers)
        publish()
    }

    companion object {
        const val MAX_ENABLED = 8
        internal const val NO_TOKEN = "No token stored for this server"
    }
}
