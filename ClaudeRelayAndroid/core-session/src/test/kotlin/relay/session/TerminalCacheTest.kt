package relay.session

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.UUID

/**
 * Verifies the LRU-8 cache contract ported from
 * Sources/ClaudeRelayClient/ViewModels/TerminalCache.swift:
 *   - default limit is 8 (TerminalCache.swift:34)
 *   - the active session is never a victim (TerminalCache.swift:86-91)
 *   - pruneStale drops ids absent from the known set (TerminalCache.swift:77-80)
 */
class TerminalCacheTest {

    private fun ids(count: Int): List<UUID> = List(count) { UUID.randomUUID() }

    @Test
    fun `evicts least-recently-used beyond limit`() {
        val cache = TerminalCache<String>(limit = 8)
        val sessions = ids(9)
        sessions.forEachIndexed { i, id -> cache.register(view = "view-$i", sessionId = id) }

        // 9 registered into an 8-slot cache with no active session: the oldest
        // (first registered) is evicted.
        assertEquals(8, cache.count)
        assertNull(cache.view(sessions[0]))
        for (i in 1..8) assertNotNull(cache.view(sessions[i]))
    }

    @Test
    fun `never evicts the active session even at limit plus one`() {
        val cache = TerminalCache<String>(limit = 8)
        val sessions = ids(8)
        sessions.forEachIndexed { i, id -> cache.register(view = "view-$i", sessionId = id) }

        // sessions[0] is the LRU entry AND the active session. Registering a 9th
        // would normally evict sessions[0]; with it active, the next-oldest
        // (sessions[1]) is the victim instead and the active one survives.
        val active = sessions[0]
        val ninth = UUID.randomUUID()
        cache.register(view = "view-9", sessionId = ninth, activeSessionId = active)

        assertEquals(8, cache.count)
        assertNotNull(cache.view(active))
        assertNull(cache.view(sessions[1]))
        assertNotNull(cache.view(ninth))
    }

    @Test
    fun `enforceLimit picks the next non-active victim when the LRU entry is active`() {
        // The active session is the oldest entry. Filling past the limit must
        // evict the next-oldest NON-active entry, leaving the active one cached
        // (TerminalCache.swift:86-91 — `lru.first(where: { $0 != active })`).
        val cache = TerminalCache<String>(limit = 2)
        val active = UUID.randomUUID()
        val second = UUID.randomUUID()
        cache.register(view = "active", sessionId = active)
        cache.register(view = "second", sessionId = second)
        // lru order: [active, second]. Register a third with `active` protected.
        val third = UUID.randomUUID()
        cache.register(view = "third", sessionId = third, activeSessionId = active)

        assertEquals(2, cache.count)
        assertNotNull(cache.view(active)) // protected despite being LRU-oldest
        assertNull(cache.view(second))    // evicted instead
        assertNotNull(cache.view(third))
    }

    @Test
    fun `stays one over the limit when every entry is the active session`() {
        // The only way enforceLimit cannot find a victim is when every cached
        // entry is the active session — i.e. re-registering the same active id
        // does not evict it, and the cache can momentarily hold limit entries
        // that are all protected. With a single id this collapses to one entry,
        // so we verify the guard returns without evicting the active session.
        val cache = TerminalCache<String>(limit = 1)
        val active = UUID.randomUUID()
        cache.register(view = "active-1", sessionId = active, activeSessionId = active)
        // Re-register the same active session (view refresh) — no eviction.
        cache.register(view = "active-2", sessionId = active, activeSessionId = active)
        assertEquals(1, cache.count)
        assertEquals("active-2", cache.view(active))
    }

    @Test
    fun `touch promotes a session to most-recently-used`() {
        val cache = TerminalCache<String>(limit = 8)
        val sessions = ids(8)
        sessions.forEachIndexed { i, id -> cache.register(view = "view-$i", sessionId = id) }

        // Touch the oldest so it is no longer the LRU victim.
        cache.touch(sessions[0])
        val ninth = UUID.randomUUID()
        cache.register(view = "view-9", sessionId = ninth)

        assertEquals(8, cache.count)
        // sessions[0] was promoted, so sessions[1] (now oldest) is evicted.
        assertNotNull(cache.view(sessions[0]))
        assertNull(cache.view(sessions[1]))
    }

    @Test
    fun `pruneStale removes and returns ids not in the known set`() {
        val cache = TerminalCache<String>(limit = 8)
        val sessions = ids(4)
        sessions.forEachIndexed { i, id -> cache.register(view = "view-$i", sessionId = id) }

        val known = setOf(sessions[0], sessions[2])
        val removed = cache.pruneStale(known)

        assertEquals(setOf(sessions[1], sessions[3]), removed.toSet())
        assertEquals(2, cache.count)
        assertNotNull(cache.view(sessions[0]))
        assertNull(cache.view(sessions[1]))
        assertNotNull(cache.view(sessions[2]))
        assertNull(cache.view(sessions[3]))
    }

    @Test
    fun `pruneStale with all known returns empty and keeps everything`() {
        val cache = TerminalCache<String>(limit = 8)
        val sessions = ids(3)
        sessions.forEachIndexed { i, id -> cache.register(view = "view-$i", sessionId = id) }

        val removed = cache.pruneStale(sessions.toSet())
        assertTrue(removed.isEmpty())
        assertEquals(3, cache.count)
    }

    @Test
    fun `evict drops a single entry`() {
        val cache = TerminalCache<String>(limit = 8)
        val id = UUID.randomUUID()
        cache.register(view = "view", sessionId = id)
        assertEquals(1, cache.count)
        cache.evict(id)
        assertEquals(0, cache.count)
        assertNull(cache.view(id))
        assertFalse(cache.cachedIds.contains(id))
    }

    @Test
    fun `removeAll clears the cache`() {
        val cache = TerminalCache<String>(limit = 8)
        ids(5).forEachIndexed { i, id -> cache.register(view = "view-$i", sessionId = id) }
        cache.removeAll()
        assertEquals(0, cache.count)
        assertTrue(cache.cachedIds.isEmpty())
    }

    @Test
    fun `cachedIds reflects current contents`() {
        val cache = TerminalCache<String>(limit = 8)
        val sessions = ids(3)
        sessions.forEachIndexed { i, id -> cache.register(view = "view-$i", sessionId = id) }
        assertEquals(sessions.toSet(), cache.cachedIds)
    }

    @Test
    fun `default limit is 8`() {
        assertEquals(8, TerminalCache<String>().limit)
    }
}
