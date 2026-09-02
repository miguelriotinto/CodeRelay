package relay.storage

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import relay.protocol.ConnectionConfig
import java.io.File
import java.util.UUID

class SavedConnectionStoreTest {

    private fun store(tmp: File) = SavedConnectionStore(File(tmp, "servers.json"))

    private fun config(name: String, id: UUID = UUID.randomUUID()) =
        ConnectionConfig(id = id, name = name, host = "10.0.0.5", port = 9200u, useTLS = false)

    @Test
    fun `missing file loads as empty`(@TempDir tmp: File) = runTest {
        assertEquals(emptyList<ConnectionConfig>(), store(tmp).loadAll())
    }

    @Test
    fun `round-trips a list`(@TempDir tmp: File) = runTest {
        val s = store(tmp)
        val items = listOf(config("Mac mini"), config("Studio"))
        s.saveAll(items)
        assertEquals(items, s.loadAll())
    }

    @Test
    fun `preserves TLS and port`(@TempDir tmp: File) = runTest {
        val s = store(tmp)
        val c = ConnectionConfig(name = "Remote", host = "relay.example.com", port = 443u, useTLS = true)
        s.saveAll(listOf(c))
        val loaded = s.loadAll().single()
        assertEquals(443u.toUShort(), loaded.port)
        assertTrue(loaded.useTLS)
        assertEquals("wss://relay.example.com:443", loaded.wsUrl)
    }

    @Test
    fun `add appends a new connection`(@TempDir tmp: File) = runTest {
        val s = store(tmp)
        s.add(config("one"))
        val all = s.add(config("two"))
        assertEquals(listOf("one", "two"), all.map { it.name })
    }

    @Test
    fun `add replaces in place when the id matches`(@TempDir tmp: File) = runTest {
        val s = store(tmp)
        val id = UUID.randomUUID()
        s.add(config("before", id))
        s.add(config("filler"))
        val all = s.add(config("after", id))

        assertEquals(2, all.size, "replacing must not append a duplicate")
        assertEquals("after", all[0].name)
        assertEquals(0, all.indexOfFirst { it.id == id }, "replacement must keep its position")
    }

    @Test
    fun `delete removes only the named connection`(@TempDir tmp: File) = runTest {
        val s = store(tmp)
        val doomed = UUID.randomUUID()
        s.add(config("keep"))
        s.add(config("doomed", doomed))
        val all = s.delete(doomed)
        assertEquals(listOf("keep"), all.map { it.name })
        assertEquals(listOf("keep"), s.loadAll().map { it.name })
    }

    @Test
    fun `delete of an unknown id is a no-op`(@TempDir tmp: File) = runTest {
        val s = store(tmp)
        s.add(config("keep"))
        assertEquals(1, s.delete(UUID.randomUUID()).size)
    }

    /**
     * A parse failure degrades to empty rather than throwing, matching the
     * Android store. Losing bookmarks is recoverable; a crash loop on a corrupt
     * file would lock the user out of the app entirely.
     */
    @Test
    fun `corrupt json degrades to empty rather than throwing`(@TempDir tmp: File) = runTest {
        val f = File(tmp, "servers.json")
        f.writeText("{ this is not json")
        assertEquals(emptyList<ConnectionConfig>(), SavedConnectionStore(f).loadAll())
    }

    @Test
    fun `empty file degrades to empty`(@TempDir tmp: File) = runTest {
        val f = File(tmp, "servers.json")
        f.writeText("")
        assertEquals(emptyList<ConnectionConfig>(), SavedConnectionStore(f).loadAll())
    }

    @Test
    fun `a corrupt file is recoverable by writing`(@TempDir tmp: File) = runTest {
        val f = File(tmp, "servers.json")
        f.writeText("garbage")
        val s = SavedConnectionStore(f)
        s.add(config("fresh"))
        assertEquals(listOf("fresh"), s.loadAll().map { it.name })
    }

    /**
     * `add`/`delete` are each a load-then-save. Without the store's mutex two
     * concurrent adds interleave and the second overwrites the first's change
     * with a stale list — the classic lost update. The Android original is safe
     * only because DataStore's `edit` is transactional; a plain file is not.
     */
    @Test
    fun `concurrent adds do not lose updates`(@TempDir tmp: File) = runTest {
        val s = store(tmp)
        val names = (1..20).map { "server-$it" }
        names.map { name -> async { s.add(config(name)) } }.awaitAll()

        val persisted = s.loadAll().map { it.name }.toSet()
        assertEquals(names.toSet(), persisted, "every concurrent add must survive")
    }

    @Test
    fun `written file is valid json readable by a fresh store`(@TempDir tmp: File) = runTest {
        val f = File(tmp, "servers.json")
        SavedConnectionStore(f).add(config("persisted"))
        // A brand-new instance proves nothing is held only in memory.
        assertEquals(listOf("persisted"), SavedConnectionStore(f).loadAll().map { it.name })
    }
}
