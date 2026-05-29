import Foundation

/// LRU-bounded cache for native terminal views (NSView on macOS, UIView on iOS).
///
/// The coordinator owns one `TerminalCache` and forwards calls into it. Keeping
/// the cache in its own type means the "never evict the active session"
/// invariant is enforced in one place and tested against one API, not smeared
/// across the 900-line `SharedSessionCoordinator`.
@MainActor
public final class TerminalCache {

    /// Maximum number of cached native views. Once exceeded, the least-
    /// recently-used entry is evicted unless it is the active session — the
    /// user's currently-visible terminal is never evicted, even if that
    /// temporarily holds the cache one over the limit.
    public let limit: Int

    /// Snapshot of the cached session ids in LRU order (oldest first). Exposed
    /// for tests only; production code does not read this.
    public var _testOnly_lruOrder: [UUID] { lru }

    /// Snapshot of the set of sessions the cache has ever registered a live
    /// terminal for. Exposed for tests only; production code does not read this.
    public var liveSessionIds: Set<UUID> { liveSessions }

    // MARK: - Storage

    private var views: [UUID: AnyObject] = [:]
    private var lru: [UUID] = []
    private var liveSessions: Set<UUID> = []

    // MARK: - Init

    public init(limit: Int = 8) {
        precondition(limit > 0, "TerminalCache limit must be positive")
        self.limit = limit
    }

    // MARK: - API

    /// Register a native terminal view for a session. Marks the session as
    /// the most-recently-used entry and evicts the LRU victim if needed.
    /// After registration, `liveSessionIds` contains `sessionId`.
    ///
    /// `activeSessionId` is used only for the eviction decision — the active
    /// session is never evicted even if it's the oldest entry.
    public func register(view: AnyObject, for sessionId: UUID, activeSessionId: UUID? = nil) {
        views[sessionId] = view
        liveSessions.insert(sessionId)
        touch(sessionId)
        enforceLimit(activeSessionId: activeSessionId)
    }

    /// Look up the cached native view for a session, if any.
    public func view(for sessionId: UUID) -> AnyObject? {
        views[sessionId]
    }

    /// Record that the given session is now the most-recently-used without
    /// changing the cached view. Call this when the user switches to a
    /// session whose view is already cached.
    public func touch(_ sessionId: UUID) {
        lru.removeAll(where: { $0 == sessionId })
        lru.append(sessionId)
    }

    /// Evict a single session's cached view and LRU entry.
    public func evict(_ sessionId: UUID) {
        views.removeValue(forKey: sessionId)
        liveSessions.remove(sessionId)
        lru.removeAll(where: { $0 == sessionId })
    }

    /// Evict any cached sessions whose id is NOT in `knownSessionIds`. Used
    /// after a server-side session list refresh to drop terminals for
    /// sessions that no longer exist on the server.
    public func pruneStale(knownSessionIds: Set<UUID>) {
        let stale = Set(views.keys).subtracting(knownSessionIds)
        for id in stale { evict(id) }
    }

    /// If the cache exceeds `limit`, evict least-recently-used entries until
    /// it fits. The active session is never a victim — if every remaining
    /// entry is the active session, the cache stays one over the limit until
    /// a non-active entry becomes available.
    public func enforceLimit(activeSessionId: UUID? = nil) {
        while views.count > limit {
            guard let victim = lru.first(where: { $0 != activeSessionId }) else { return }
            evict(victim)
        }
    }

    /// Clear every cached view. Called on coordinator teardown.
    public func removeAll() {
        views.removeAll()
        liveSessions.removeAll()
        lru.removeAll()
    }

    /// Current number of cached views. Exposed for tests and the coordinator
    /// that forwards `fetchSessions`' stale-prune logic.
    public var count: Int { views.count }

    /// Current cached session ids. Used by the coordinator's `fetchSessions`
    /// to compute the stale set before calling `pruneStale`.
    public var cachedIds: Set<UUID> { Set(views.keys) }
}
