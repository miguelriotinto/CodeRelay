package relay.session.hub

import kotlinx.coroutines.async
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import relay.protocol.SessionDeepLink
import relay.protocol.SessionRef
import java.util.UUID

// Selection (spec §7.5) and deep-link routing (spec §10). Port of
// `ServerHub+Selection.swift` and `ServerHub+DeepLink.swift`: the D9 invariant
// (one attachment across all servers) rests on this file.

/** Every selectable row in sidebar order (enabled sections, live or cached), for next/previous across sections. */
val ServerHub<*>.orderedRefs: List<SessionRef>
    get() = sections.value.filter { it.config.enabled }.flatMap { s -> s.sessions.map { SessionRef(s.id, it.id) } }

/**
 * Makes [ref] the one attached session. Same server → the coordinator's own
 * switch (which detaches its previous session itself). Different server → a
 * bounded detach on the previous server, THEN the attach. Offline or
 * still-building server → remember the choice and trigger its recovery. A row
 * whose server has no slot and is not getting one is refused before any state
 * moves.
 */
suspend fun <S : ServerSlot> ServerHub<S>.select(ref: SessionRef) {
    val section = sections.value.firstOrNull { it.id == ref.serverId } ?: return
    val slot = slots[ref.serverId]
    val building = slot == null && section.config.enabled && ref.serverId !in missingToken && started
    if (slot == null && !building) {
        noticeFlow.value = if (section.config.enabled) {
            "${section.title} has no token. Re-pair it in Servers."
        } else {
            "Enable ${section.title} in Servers to open its sessions."
        }
        return
    }
    if (activeRefFlow.value == ref && pendingRef == ref) return
    if (activeRefFlow.value == ref && pendingRef == null && slot?.activeSessionId?.value == ref.sessionId) return

    selectionGeneration += 1
    val generation = selectionGeneration
    selectionsInFlight += 1
    try {
        val previous = activeRefFlow.value
        activeRefFlow.value = ref
        pendingRef = null
        state.saveActiveRef(ref)
        publish()

        if (previous != null && previous.serverId != ref.serverId) {
            slots[previous.serverId]?.let { detachBounded(it) }
            if (generation != selectionGeneration) return
        }
        val to = slots[ref.serverId]
        if (to == null || sections.value.firstOrNull { it.id == ref.serverId }?.status?.isLive != true) {
            pendingRef = ref
            slot?.triggerUserRecovery()
            publish()
            return
        }
        to.switchToSession(ref.sessionId)
        if (generation != selectionGeneration) return
        mirror(to, ref.serverId)
        publish()
    } finally {
        selectionsInFlight -= 1
    }
}

/** A new session on [serverId]; detaches on any other server first (§7.5). */
suspend fun <S : ServerSlot> ServerHub<S>.createSession(serverId: UUID) {
    val to = slots[serverId]
    if (to == null || sections.value.firstOrNull { it.id == serverId }?.status?.isLive != true) {
        noticeFlow.value = "That server is not connected."
        return
    }
    selectionGeneration += 1
    val generation = selectionGeneration
    selectionsInFlight += 1
    try {
        pendingRef = null
        val previous = activeRefFlow.value
        if (previous != null && previous.serverId != serverId) {
            slots[previous.serverId]?.let { detachBounded(it) }
            if (generation != selectionGeneration) return
        }
        to.createNewSession()
        if (generation != selectionGeneration) return
        mirror(to, serverId)
        publish()
    } finally {
        selectionsInFlight -= 1
    }
}

suspend fun ServerHub<*>.selectNext() = step(1)
suspend fun ServerHub<*>.selectPrevious() = step(-1)

private suspend fun ServerHub<*>.step(delta: Int) {
    val refs = orderedRefs
    val current = activeRef.value ?: return
    val index = refs.indexOf(current)
    if (refs.size <= 1 || index < 0) return
    @Suppress("UNCHECKED_CAST")
    (this as ServerHub<ServerSlot>).select(refs[(index + delta + refs.size) % refs.size])
}

/**
 * Deletes a bookmark: detach if active, unregister push, tear down, forget its
 * token (§7.3, §11). The deletion lands BEFORE the bounded retire, and the
 * retire cannot be cancelled: a caller that goes away mid-way (leaving the
 * Servers screen) must not leak the socket or bring the bookmark back.
 */
suspend fun <S : ServerSlot> ServerHub<S>.removeServer(serverId: UUID) {
    val slot = detachFromHub(serverId)
    withContext(NonCancellable) {
        bookmarkStore.delete(serverId)
        runCatching { tokens.deleteToken(serverId) }
        bookmarks = bookmarkStore.loadAll()
        cachedSessions.remove(serverId)
        missingToken.remove(serverId)
        publish()
        slot?.let { retire(it, wasActive = it.activeSessionId.value != null, unregisterPush = true) }
    }
}

/** After an attach the coordinator's `activeSessionId` is the truth (it rolls back a failed resume). */
internal fun <S : ServerSlot> ServerHub<S>.mirror(slot: S, serverId: UUID) {
    val now = slot.activeSessionId.value?.let { SessionRef(serverId, it) }
    if (activeRefFlow.value != now) {
        activeRefFlow.value = now
        state.saveActiveRef(now)
    }
}

/**
 * Awaits [slot]'s detach for at most the hub's budget. The straggler keeps
 * running in the hub scope; the coordinator's own budget bounds it.
 */
internal suspend fun <S : ServerSlot> ServerHub<S>.detachBounded(slot: S) {
    val work = scope.async { slot.detachForHub(detachBudgetMs) }
    withTimeoutOrNull(detachBudgetMs) { work.await() }
}

/**
 * Called from `slotDidChange` after `publish()`: apply or drop the pending
 * selection once its server is live. Only ever the CURRENT selection — an
 * abandoned choice was replaced by the next [select].
 */
internal fun <S : ServerSlot> ServerHub<S>.applyPendingSelection(serverId: UUID) {
    val wanted = pendingRef ?: return
    if (wanted.serverId != serverId || activeRefFlow.value != wanted) return
    // A link queued behind start() decides what opens; the restore must not
    // switch concurrently with it on the same coordinator.
    if (deepLinksWaiting > 0) { pendingRef = null; return }
    val slot = slots[serverId] ?: return
    if (sections.value.firstOrNull { it.id == serverId }?.status?.isLive != true) return
    pendingRef = null
    if (slot.sessions.value.none { it.id == wanted.sessionId }) {
        activeRefFlow.value = null
        state.saveActiveRef(null)
        noticeFlow.value = "That session has ended"
        publish()
        return
    }
    selectionGeneration += 1
    val generation = selectionGeneration
    selectionsInFlight += 1
    scope.launch {
        try {
            slot.switchToSession(wanted.sessionId)
            if (generation != selectionGeneration) return@launch
            mirror(slot, serverId)
            publish()
        } finally {
            selectionsInFlight -= 1
        }
    }
}

/**
 * Attaches [sessionId] — a session another device owns — on [serverId]: the
 * Attach sheet, the QR scanner and the one-server deep-link fallback. Detaches
 * any other server first, like every selection path (D9: one attachment).
 */
suspend fun <S : ServerSlot> ServerHub<S>.attachRemote(serverId: UUID, sessionId: UUID, serverName: String?) {
    val slot = slots[serverId] ?: run { noticeFlow.value = "That server is not connected."; return }
    selectionGeneration += 1
    val generation = selectionGeneration
    selectionsInFlight += 1
    try {
        pendingRef = null
        val previous = activeRefFlow.value
        if (previous != null && previous.serverId != serverId) {
            slots[previous.serverId]?.let { detachBounded(it) }
            if (generation != selectionGeneration) return
        }
        slot.attachRemoteSession(sessionId, serverName)
        if (generation != selectionGeneration) return
        mirror(slot, serverId)
        publish()
    } finally {
        selectionsInFlight -= 1
    }
}

/** Where a deep link went (spec §10). */
sealed interface DeepLinkOutcome {
    data class Selected(val ref: SessionRef) : DeepLinkOutcome
    data class EnabledAndSelected(val ref: SessionRef) : DeepLinkOutcome
    data class AttachingRemote(val serverId: UUID) : DeepLinkOutcome
    data class NotFound(val serverName: String?) : DeepLinkOutcome
}

/**
 * Routing precedence: instance id → unique session across live sections →
 * single enabled server's cross-device attach → not found. A link that
 * arrives before the first [ServerHub.start] finished (a cold launch from a
 * push tap) waits for it; afterwards it routes at once, even with no slot built.
 */
suspend fun <S : ServerSlot> ServerHub<S>.handleDeepLink(link: SessionDeepLink): DeepLinkOutcome {
    deepLinksWaiting += 1
    try {
        startCompleted.await()
    } finally {
        deepLinksWaiting -= 1
    }
    // 1. The relay named itself. An enabled bookmark wins over a disabled twin
    //    of the same relay (§12) — never a second socket to one relay.
    val iid = link.serverInstanceId
    val named = iid?.let { id ->
        bookmarks.firstOrNull { it.instanceId == id && it.enabled } ?: bookmarks.firstOrNull { it.instanceId == id }
    }
    if (named != null) {
        val ref = SessionRef(named.id, link.sessionId)
        if (!named.enabled) {
            val title = named.displayName ?: named.name
            if (!setEnabled(named.id, true)) return DeepLinkOutcome.NotFound(title)
            noticeFlow.value = "Enabled $title to open this session"
            selectionGeneration += 1
            selectionsInFlight += 1
            try {
                // D9 even here: the current server is detached before the new
                // one's pending selection can attach.
                val previous = activeRefFlow.value
                if (previous != null && previous.serverId != named.id) slots[previous.serverId]?.let { detachBounded(it) }
                activeRefFlow.value = ref
                pendingRef = ref
                state.saveActiveRef(ref)
                publish()
            } finally {
                selectionsInFlight -= 1
            }
            return DeepLinkOutcome.EnabledAndSelected(ref)
        }
        select(ref)
        return DeepLinkOutcome.Selected(ref)
    }
    // 2. Exactly one live section lists the session.
    val hits = sections.value.filter { s -> s.status.isLive && s.sessions.any { it.id == link.sessionId } }
    if (hits.size == 1) {
        val ref = SessionRef(hits[0].id, link.sessionId)
        select(ref)
        return DeepLinkOutcome.Selected(ref)
    }
    // 3. One enabled server: the pre-hub cross-device attach.
    val enabled = bookmarks.filter { it.enabled }
    val only = enabled.singleOrNull()
    val onlySlot = only?.let { slots[it.id] }
    if (only != null && onlySlot != null) {
        attachRemote(only.id, link.sessionId, null)
        return DeepLinkOutcome.AttachingRemote(only.id)
    }
    // 4. Nothing to route to.
    noticeFlow.value = "Session not found on any enabled server"
    return DeepLinkOutcome.NotFound(null)
}
