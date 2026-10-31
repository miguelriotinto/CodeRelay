package relay.session.hub

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * Aggregates every server's session-loss reports into one batch (spec §2).
 * Port of Swift `SessionLossCollector`; keep the two in step.
 *
 * - Dedupes by `(serverId, session.id)` within a batch, across both kinds
 *   (the first report wins).
 * - Drops an item announced in the last [SUPPRESSION_WINDOW_MS] (120 s), so a
 *   late queued `session_stolen` after a wake diff — or the reverse — stays silent.
 * - Outside a hold, flushes [DEBOUNCE_MS] (1 s) after the LAST report, so two
 *   steals in quick succession produce one alert.
 * - [beginHold]/[endHold] nest; while any hold is open nothing flushes, and the
 *   outermost [endHold] flushes whatever was collected.
 *
 * Not thread-safe: confined to [scope]'s single dispatcher, like the hub.
 */
class SessionLossCollector(
    private val scope: CoroutineScope,
    private val nowMs: () -> Long,
    private val sleepMs: suspend (Long) -> Unit,
) {
    private data class Key(val serverId: UUID, val sessionId: UUID)

    /** Delivered once per batch; at least one of the two lists is non-empty. */
    var onFlush: ((taken: List<SessionLossItem>, ended: List<SessionLossItem>) -> Unit)? = null

    private val taken = mutableListOf<SessionLossItem>()
    private val ended = mutableListOf<SessionLossItem>()
    private val pendingKeys = mutableSetOf<Key>()
    private val announced = mutableMapOf<Key, Long>()
    private var holdDepth = 0
    /** Bumped by [reset]; a hold opened before a reset cannot end one after it. */
    private var epoch = 0L
    /**
     * Bumped by every report and hold change; a debounce that wakes to a
     * different value was superseded and does nothing. The injected sleep need
     * not honour cancellation, so this — not `Job.cancel` — is the guard.
     */
    private var debounceGeneration = 0L

    val isHolding: Boolean get() = holdDepth > 0

    fun report(items: List<SessionLossItem>, kind: SessionLossKind) {
        val at = nowMs()
        announced.entries.removeAll { at - it.value >= SUPPRESSION_WINDOW_MS }
        var added = false
        for (item in items) {
            val key = Key(item.serverId, item.session.id)
            if (key in pendingKeys || key in announced) continue
            pendingKeys += key
            when (kind) {
                SessionLossKind.TAKEN -> taken += item
                SessionLossKind.ENDED -> ended += item
            }
            added = true
        }
        if (!added || holdDepth > 0) return
        scheduleDebouncedFlush()
    }

    /** Returns the epoch to hand back to [endHold]. */
    fun beginHold(): Long {
        holdDepth += 1
        debounceGeneration += 1
        return epoch
    }

    /** A hold from before the last [reset] (its [holdEpoch] differs) is a no-op. */
    fun endHold(holdEpoch: Long? = null) {
        if (holdEpoch != null && holdEpoch != epoch) return
        if (holdDepth == 0) return
        holdDepth -= 1
        if (holdDepth == 0) flush()
    }

    /**
     * Drops everything pending, supersedes a pending debounce and closes every
     * hold (hub `stop()`). The announced memory stays, so suppression holds
     * across a workspace re-open.
     */
    fun reset() {
        taken.clear(); ended.clear(); pendingKeys.clear()
        holdDepth = 0
        debounceGeneration += 1
        epoch += 1
    }

    private fun scheduleDebouncedFlush() {
        debounceGeneration += 1
        val generation = debounceGeneration
        scope.launch {
            sleepMs(DEBOUNCE_MS)
            if (debounceGeneration != generation || holdDepth > 0) return@launch
            flush()
        }
    }

    private fun flush() {
        if (taken.isEmpty() && ended.isEmpty()) return
        val at = nowMs()
        for (key in pendingKeys) announced[key] = at
        val batch = taken.toList() to ended.toList()
        taken.clear(); ended.clear(); pendingKeys.clear()
        onFlush?.invoke(batch.first, batch.second)
    }

    companion object {
        const val DEBOUNCE_MS = 1_000L
        const val SUPPRESSION_WINDOW_MS = 120_000L
    }
}

/**
 * The one aggregated "Session Moved" alert the workspace root presents. [id]
 * keeps two alerts with the same copy distinct (Swift `Identifiable`).
 */
data class SessionLossAlert(val title: String, val message: String, val id: UUID = UUID.randomUUID())
