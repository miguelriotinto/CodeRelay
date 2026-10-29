package relay.session.hub

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionConfig
import java.util.UUID

class HubMigrationTest {
    private fun cfg(n: String) = ConnectionConfig(name = n, host = "$n.local")

    @Test fun onlyTheLastUsedBookmarkStaysEnabledAndGetsTheLegacyMaps() = runTest {
        val a = cfg("a"); val b = cfg("b"); val c = cfg("c")
        val store = InMemoryBookmarks(listOf(a, b, c)); val state = HubStateStore(MapPreferences(), "relay")
        var movedInto: UUID? = UUID.randomUUID()
        assertTrue(HubMigration.run(store, b.id.toString(), state) { movedInto = it })
        assertEquals(listOf(false, true, false), store.loadAll().map { it.enabled })
        assertEquals(b.id, movedInto)
        assertTrue(state.isMigrated)
    }

    @Test fun aSingleBookmarkIsEnabledEvenWithoutALastUsedId() = runTest {
        val store = InMemoryBookmarks(listOf(cfg("a"))); val state = HubStateStore(MapPreferences(), "relay")
        var movedInto: UUID? = UUID.randomUUID()
        HubMigration.run(store, "", state) { movedInto = it }
        assertTrue(store.loadAll().single().enabled, "G8: a one-server user sees exactly what they saw before")
        assertEquals(store.loadAll().single().id, movedInto, "with one bookmark the legacy maps can only be its own")
    }

    @Test fun aStaleLastUsedIdWithSeveralBookmarksDisablesAllAndDropsTheLegacyMaps() = runTest {
        val store = InMemoryBookmarks(listOf(cfg("a"), cfg("b"))); val state = HubStateStore(MapPreferences(), "relay")
        var movedInto: UUID? = UUID.randomUUID()
        HubMigration.run(store, UUID.randomUUID().toString(), state) { movedInto = it }
        assertTrue(store.loadAll().none { it.enabled })
        assertNull(movedInto, "maps of a server that no longer exists are dropped, not guessed onto one")
    }

    @Test fun runsOnce() = runTest {
        val store = InMemoryBookmarks(listOf(cfg("a"), cfg("b"))); val state = HubStateStore(MapPreferences(), "relay")
        HubMigration.run(store, "", state) {}
        store.saveAll(store.loadAll().map { it.copy(enabled = true) })
        assertFalse(HubMigration.run(store, "", state) {})
        assertTrue(store.loadAll().all { it.enabled }, "a second launch never touches the user's choices")
    }
}
