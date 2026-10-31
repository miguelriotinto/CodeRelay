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
import relay.session.SessionHandshake
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
    /** The session-loss collector's clock (120 s repeat suppression). */
    nowMs: () -> Long = System::currentTimeMillis,
    /** The collector's 1 s debounce sleep. */
    lossSleepMs: suspend (Long) -> Unit = { delay(it) },
    /**
     * Cap on the session-loss hold around [start] and a foreground fan-out: one
     * dead server must not hold everyone's notice (spec §2, §6). Raced with
     * `withTimeoutOrNull` on [scope], so tests run it on virtual time.
     */
    private val fanOutBudgetMs: Long = 10_000,
) {
    // MARK: - Published state

    private val _sections = MutableStateFlow<List<ServerSection>>(emptyList())
    val sections: StateFlow<List<ServerSection>> = _sections.asStateFlow()

    internal val activeRefFlow = MutableStateFlow<SessionRef?>(null)
    val activeRef: StateFlow<SessionRef?> = activeRefFlow.asStateFlow()

    private val _aggregate = MutableStateFlow(HubAggregate())
    val aggregate: StateFlow<HubAggregate> = _aggregate.asStateFlow()

    internal val noticeFlow = MutableStateFlow<String?>(null)
    /**
     * User-facing notices the hub produces (deep-link enable, cap refusal,
     * sessions that ended while the user was away…).
     */
    val notice: StateFlow<String?> = noticeFlow.asStateFlow()
    fun setNotice(text: String?) { noticeFlow.value = text }

    private val _takenAlert = MutableStateFlow<SessionLossAlert?>(null)
    /**
     * The one aggregated "Session Moved" alert across every server (session
     * takeover spec §2, §5). Bound by the workspace root — never by a
     * per-server pane, which is re-keyed when focus moves.
     */
    val takenAlert: StateFlow<SessionLossAlert?> = _takenAlert.asStateFlow()
    /** The sessions [takenAlert] announces, so a batch that lands while it is unread joins it. */
    private var shownTaken: List<SessionLossItem> = emptyList()
    /** OK on the session-loss dialog: the only way it is cleared. */
    fun dismissTakenAlert() {
        _takenAlert.value = null
        shownTaken = emptyList()
    }

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
    private val _hasStarted = MutableStateFlow(false)
    /** True once the first [start] has loaded the bookmarks and built (or skipped) every slot. Until then an empty hub means "not loaded yet", not "no servers". */
    val hasStarted: StateFlow<Boolean> = _hasStarted.asStateFlow()
    /** The one selection waiting for its server to come live (always == activeRef while set). */
    internal var pendingRef: SessionRef? = null
    /** Bumped by every selection path; a path resuming after an `await` into a newer generation stops. */
    internal var selectionGeneration = 0L
    /** Selections between their first and last `await`; [reconcileSelection] stays out of the way. */
    internal var selectionsInFlight = 0
    /**
     * Deep links waiting on [startCompleted]. While one is, the restored F3
     * selection is not applied: the link is what the user asked for, and
     * applying both ran two switches concurrently on one coordinator.
     */
    internal var deepLinksWaiting = 0
    /** Bookmarks whose slot is being built (the token read suspends), so a reload cannot build a second one. */
    private val building = mutableSetOf<UUID>()
    /** The last push settings synced; slots built later get the same. */
    private var pushSettings: PushSettings? = null
    internal val lossCollector = SessionLossCollector(scope, nowMs, lossSleepMs).also { c ->
        c.onFlush = { taken, ended -> presentLosses(taken, ended) }
    }
    /**
     * Test hook: the most recent fan-out's hold. Callers never await it — the
     * notice must not delay the fan-out (spec anti-goal).
     */
    internal var lastLossHold: Job? = null

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
            val enabled = bookmarks.filter { it.enabled }
            val hold = openLossHold(enabled.size)
            coroutineScope {
                enabled.forEachIndexed { index, config ->
                    launch {
                        var handedOff = false
                        try {
                            sleepMs(staggerMs * index)
                            if (started) {
                                buildSlot(config, SessionHandshake.Reason.LAUNCH)
                                arriveAfterPass(hold, slots[config.id])
                                handedOff = true
                            }
                        } finally {
                            if (!handedOff) hold.arrive()
                        }
                    }
                }
            }
            publish()
        } finally {
            startCompleted.complete(Unit)
            _hasStarted.value = true
        }
    }

    fun stop() {
        // No notice may land behind a closed workspace; suppression memory stays.
        lossCollector.reset()
        val retiring = slots.values.toList()
        slots.clear()
        slotJobs.values.forEach { it.cancel() }
        slotJobs.clear()
        started = false
        pendingRef = null
        retiring.forEach { slot -> scope.launch { slot.tearDown() } }
        publish()
    }

    /** Like [stop], but awaits every slot's teardown — for a host whose own scope is about to end. */
    suspend fun shutdown() {
        val retiring = slots.values.toList()
        slots.clear()
        slotJobs.values.forEach { it.cancel() }
        slotJobs.clear()
        started = false
        pendingRef = null
        retiring.forEach { runCatching { it.tearDown() } }
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
        fresh.filter { it.enabled && !slots.containsKey(it.id) }.forEach { c ->
            scope.launch { buildSlot(c, SessionHandshake.Reason.ENABLE) }
        }
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
            scope.launch { buildSlot(updated, SessionHandshake.Reason.ENABLE) }
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
        scope.launch { buildSlot(config, SessionHandshake.Reason.ENABLE) }
    }

    // MARK: - Slots

    private fun isWanted(id: UUID) = started && bookmarks.firstOrNull { it.id == id }?.enabled == true

    /**
     * [reason] is LAUNCH from [start] (announces losses since the last run) and
     * ENABLE for every later build — enable, add/pair, edit — which resets the
     * baseline silently (spec §3b).
     */
    private suspend fun buildSlot(config: ConnectionConfig, reason: SessionHandshake.Reason) {
        // Re-read the flag: enable then disable can both run before this does,
        // and stop() may have closed the workspace.
        if (slots.containsKey(config.id) || config.id in building || !isWanted(config.id)) return
        building += config.id
        val token = try {
            tokens.loadToken(config.id)
        } catch (e: CancellationException) {
            building -= config.id
            throw e
        } catch (_: Throwable) {
            null // a locked keyring reads as "no token": authFailed, never a crash
        }
        building -= config.id
        if (!isWanted(config.id) || slots.containsKey(config.id)) return
        if (token.isNullOrEmpty()) {
            missingToken += config.id
            publish()
            return
        }
        missingToken -= config.id
        val slot = factory(config, token)
        slots[config.id] = slot
        slot.onSessionsLost = { report ->
            // A retired or rebuilt slot speaks for no server any more.
            if (slots[config.id] === slot) collectLosses(report, config.id)
        }
        slotJobs[config.id] = scope.launch { slot.changes.collect { slotDidChange(config.id) } }
        try {
            slot.start(reason)
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
        val targets = bookmarks.filter { it.enabled }.mapNotNull { slots[it.id] }
        val hold = openLossHold(targets.size)
        targets.forEachIndexed { index, slot ->
            scope.launch {
                var handedOff = false
                try {
                    sleepMs(staggerMs * index)
                    slot.handleForegroundTransition()
                    // The trigger returns at once when a handshake or recovery is
                    // already running (the launch case); the hold waits for that
                    // pass, whose list application is what reports (§6).
                    arriveAfterPass(hold, slot)
                    handedOff = true
                } finally {
                    if (!handedOff) hold.arrive()
                }
            }
        }
    }

    // MARK: - Session-loss notices (session takeover spec §2, §6)

    /**
     * Opens a collector hold for one fan-out of [count] slots. It closes when
     * every slot's trigger AND `awaitPassFinished` have returned, or after
     * [fanOutBudgetMs], whichever is first. The pass waits are side jobs: the
     * fan-out itself never waits on them. Reports arriving after the cap form
     * the next (debounced) batch.
     *
     * Holds nest in the collector, so a fan-out that starts while another is
     * held extends the batch to the later hold's end (up to 2 × the cap).
     */
    private fun openLossHold(count: Int): FanOutLatch {
        val latch = FanOutLatch(count)
        val epoch = lossCollector.beginHold()
        lastLossHold = scope.launch {
            withTimeoutOrNull(fanOutBudgetMs) { latch.await() }
            lossCollector.endHold(epoch)
        }
        return latch
    }

    /** Arrives once [slot]'s in-flight pass finishes, without making the caller wait. A null slot (not built) arrives at once. */
    private fun arriveAfterPass(latch: FanOutLatch, slot: S?) {
        if (slot == null) { latch.arrive(); return }
        scope.launch {
            try { slot.awaitPassFinished() } finally { latch.arrive() }
        }
    }

    private fun collectLosses(report: SessionLossReport, serverId: UUID) {
        val config = bookmarks.firstOrNull { it.id == serverId }
        val serverName = config?.let { it.displayName ?: it.name }.orEmpty()
        fun items(lost: List<LostSession>) = lost.map { SessionLossItem(serverId, serverName, it) }
        if (report.taken.isNotEmpty()) lossCollector.report(items(report.taken), SessionLossKind.TAKEN)
        if (report.ended.isNotEmpty()) lossCollector.report(items(report.ended), SessionLossKind.ENDED)
    }

    private fun presentLosses(taken: List<SessionLossItem>, ended: List<SessionLossItem>) {
        if (taken.isNotEmpty()) {
            // An unread dialog absorbs the new batch: replacing it would mean the
            // earlier sessions were never announced. Same id: it stays up.
            val pending = _takenAlert.value
            val merged = (if (pending == null) emptyList() else shownTaken).toMutableList()
            for (item in taken) {
                if (merged.none { it.serverId == item.serverId && it.session.id == item.session.id }) merged += item
            }
            val ordered = inSidebarOrder(merged)
            shownTaken = ordered
            _takenAlert.value = SessionLossAlert(
                SessionLossCopy.takenTitle(ordered.size), SessionLossCopy.takenBody(ordered),
                pending?.id ?: UUID.randomUUID())
        }
        if (ended.isNotEmpty()) noticeFlow.value = SessionLossCopy.endedBody(inSidebarOrder(ended))
    }

    /** Sorts by server in sidebar (bookmark) order, keeping each server's own order (stable sort). */
    private fun inSidebarOrder(items: List<SessionLossItem>): List<SessionLossItem> {
        val rank = HashMap<UUID, Int>()
        bookmarks.forEachIndexed { index, config -> rank.putIfAbsent(config.id, index) }
        return items.sortedBy { rank[it.serverId] ?: Int.MAX_VALUE }
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

/**
 * Counts a fan-out's slots down to zero; [await] returns once every slot has
 * arrived (at once when there were none). The hub races it against the cap, so
 * a slot that never arrives only leaves a cancelled waiter behind.
 */
internal class FanOutLatch(count: Int) {
    private var remaining = count
    private val done = CompletableDeferred<Unit>().also { if (count <= 0) it.complete(Unit) }

    fun arrive() {
        if (remaining <= 0) return
        remaining -= 1
        if (remaining == 0) done.complete(Unit)
    }

    suspend fun await() = done.await()
}
