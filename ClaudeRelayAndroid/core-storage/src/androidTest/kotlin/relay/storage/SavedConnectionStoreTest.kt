package relay.storage

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import relay.protocol.ConnectionConfig

@RunWith(AndroidJUnit4::class)
class SavedConnectionStoreTest {

    private lateinit var store: SavedConnectionStore

    @Before
    fun setUp() = runBlocking {
        store = SavedConnectionStore(ApplicationProvider.getApplicationContext())
        // Start each test from a known-empty state (the DataStore file persists
        // across runs on a real device).
        store.saveAll(emptyList())
    }

    @Test
    fun emptyStoreLoadsEmptyList() = runBlocking {
        assertTrue(store.loadAll().isEmpty())
    }

    @Test
    fun savesAndLoadsListWithMatchingFields() = runBlocking {
        val first = ConnectionConfig(name = "Home", host = "192.168.1.10", port = 9200u, useTLS = false)
        val second = ConnectionConfig(name = "Cloud", host = "relay.example.com", port = 443u, useTLS = true)

        store.saveAll(listOf(first, second))
        val loaded = store.loadAll()

        assertEquals(2, loaded.size)

        val loadedFirst = loaded.first { it.id == first.id }
        assertEquals(first.name, loadedFirst.name)
        assertEquals(first.host, loadedFirst.host)
        assertEquals(first.port, loadedFirst.port)
        assertEquals(first.useTLS, loadedFirst.useTLS)

        val loadedSecond = loaded.first { it.id == second.id }
        assertEquals(second.name, loadedSecond.name)
        assertEquals(second.host, loadedSecond.host)
        assertEquals(second.port, loadedSecond.port)
        assertEquals(second.useTLS, loadedSecond.useTLS)
    }

    @Test
    fun addAndDeleteUpdateTheList() = runBlocking {
        val config = ConnectionConfig(name = "One", host = "10.0.0.1", port = 9200u, useTLS = false)
        store.add(config)
        assertEquals(1, store.loadAll().size)

        store.delete(config.id)
        assertTrue(store.loadAll().isEmpty())
    }
}
