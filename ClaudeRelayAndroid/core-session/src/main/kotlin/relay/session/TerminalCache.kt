package relay.session

import java.util.UUID

/**
 * LRU-bounded cache for native terminal views, ported from
 * Sources/ClaudeRelayClient/ViewModels/TerminalCache.swift.
 *
 * The coordinator owns one [TerminalCache] and forwards calls into it. Keeping
 * the cache in its own type means the "never evict the active session"
 * invariant is enforced in one place and tested against one API, not smeared
 * across the session coordinator.
 *
 * Generic over the view type [T] so this module stays free of any Android view
 * dependency; the workspace layer instantiates it with its concrete terminal
 * view type.
 *
 * Not thread-safe by design — the Swift original is `@MainActor`-isolated, so
 * callers must confine access to a single dispatcher (the main/UI thread).
 *
 * Mirrors the Swift storage exactly (`views` dict + explicit `lru` array +
 * `liveSessions` set), so `view(sessionId)` is a pure read that does NOT
 * reorder LRU — only [register] and [touch] move a session to the MRU end.
 */
class TerminalCache<T : Any>(
    /**
     * Maximum number of cached views. Once exceeded, the least-recently-used
     * entry is evicted unless it is the active session — the user's
     * currently-visible terminal is never evicted, even if that temporarily
     * holds the cache one over the limit (TerminalCache.swift:13-16, :86-91).
     */
    val limit: Int = 8,
) {
    init {
        require(limit > 0) { "TerminalCache limit must be positive" }
    }

    private val views = HashMap<UUID, T>()

    /** LRU order, oldest first (mirrors the Swift `lru` array). */
    private val lru = ArrayList<UUID>()

    /**
     * Sessions the cache has ever registered a live view for. Mirrors the Swift
     * `liveSessions` set (TerminalCache.swift:30).
     */
    private val liveSessions = mutableSetOf<UUID>()

    /** Current number of cached views (TerminalCache.swift:102). */
    val count: Int get() = views.size

    /** Current cached session ids (TerminalCache.swift:106). */
    val cachedIds: Set<UUID> get() = views.keys.toSet()

    /** Set of sessions a live view was ever registered for (test/diagnostic). */
    internal val liveSessionIds: Set<UUID> get() = liveSessions.toSet()

    /** Cached ids in LRU order, oldest first (test-only mirror of `lru`). */
    internal val lruOrder: List<UUID> get() = lru.toList()

    /**
     * Register a native terminal view for a session. Marks the session as the
     * most-recently-used entry and evicts the LRU victim if needed
     * (TerminalCache.swift:47-52). `activeSessionId` is used only for the
     * eviction decision — the active session is never evicted even if it's the
     * oldest entry.
     */
    fun register(view: T, sessionId: UUID, activeSessionId: UUID? = null) {
        views[sessionId] = view
        liveSessions.add(sessionId)
        touch(sessionId)
        enforceLimit(activeSessionId)
    }

    /** Look up the cached native view for a session, if any. Does NOT touch LRU. */
    fun view(sessionId: UUID): T? = views[sessionId]

    /**
     * Stores [view] for [sessionId] without touching LRU or enforcing the limit.
     * Mirrors the Swift `terminalViewModels[id] = vm` dictionary assignment used
     * by the create/switch/attach ops, which `touch` + `enforceLimit` separately
     * AFTER the active session is set. Use [register] when the caller has nothing
     * more to sequence and wants the touch/enforce in one shot.
     */
    fun put(sessionId: UUID, view: T) {
        views[sessionId] = view
        liveSessions.add(sessionId)
    }

    /**
     * Record that the given session is now the most-recently-used without
     * changing the cached view (TerminalCache.swift:62-65). Call this when the
     * user switches to a session whose view is already cached.
     */
    fun touch(sessionId: UUID) {
        lru.remove(sessionId)
        lru.add(sessionId)
    }

    /** Evict a single session's cached view and LRU entry (TerminalCache.swift:68-72). */
    fun evict(sessionId: UUID) {
        views.remove(sessionId)
        liveSessions.remove(sessionId)
        lru.remove(sessionId)
    }

    /**
     * Evict any cached sessions whose id is NOT in [knownSessionIds]
     * (TerminalCache.swift:77-80). Used after a server-side session list refresh
     * to drop terminals for sessions that no longer exist on the server.
     *
     * Returns the ids that were removed so the coordinator can react (e.g. clear
     * the active session if it was pruned). The Swift original returns Void; the
     * Android coordinator design needs the removed set, so we surface it here.
     */
    fun pruneStale(knownSessionIds: Set<UUID>): List<UUID> {
        val stale = views.keys.filter { it !in knownSessionIds }
        stale.forEach { evict(it) }
        return stale
    }

    /**
     * If the cache exceeds [limit], evict least-recently-used entries until it
     * fits (TerminalCache.swift:86-91). The active session is never a victim —
     * if every remaining entry is the active session, the cache stays one over
     * the limit until a non-active entry becomes available.
     */
    fun enforceLimit(activeSessionId: UUID? = null) {
        while (views.size > limit) {
            val victim = lru.firstOrNull { it != activeSessionId } ?: return
            evict(victim)
        }
    }

    /** Clear every cached view (TerminalCache.swift:94-98). Called on coordinator teardown. */
    fun removeAll() {
        views.clear()
        liveSessions.clear()
        lru.clear()
    }
}
