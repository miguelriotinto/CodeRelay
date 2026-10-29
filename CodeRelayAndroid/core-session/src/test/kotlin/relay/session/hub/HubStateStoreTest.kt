package relay.session.hub

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.SessionRef
import java.util.UUID

class MapPreferences : HubPreferences {
    val map = mutableMapOf<String, String>()
    override fun get(key: String) = map[key]
    override fun put(key: String, value: String?) { if (value == null) map.remove(key) else map[key] = value }
}

class HubStateStoreTest {
    @Test fun activeRefRoundTripsAndAGarbledValueReadsAsNone() {
        val prefs = MapPreferences()
        val store = HubStateStore(prefs, "relay")
        val ref = SessionRef(UUID.randomUUID(), UUID.randomUUID())
        store.saveActiveRef(ref); assertEquals(ref, store.loadActiveRef())
        store.saveActiveRef(null); assertNull(store.loadActiveRef())
        prefs.put("relay.hub.activeRef", "nonsense"); assertNull(store.loadActiveRef())
    }

    @Test fun collapsedServersAndMigratedFlag() {
        val store = HubStateStore(MapPreferences(), "relay")
        val a = UUID.randomUUID(); val b = UUID.randomUUID()
        assertTrue(store.loadCollapsedServers().isEmpty())
        store.saveCollapsedServers(setOf(a, b)); assertEquals(setOf(a, b), store.loadCollapsedServers())
        assertFalse(store.isMigrated); store.markMigrated(); assertTrue(store.isMigrated)
    }
}
