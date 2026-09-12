package relay.storage

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.util.UUID

class SessionOwnershipStoreTest {

    private val a: UUID = UUID.fromString("11111111-2222-3333-4444-555555555555")
    private val b: UUID = UUID.fromString("66666666-7777-8888-9999-000000000000")

    @Test
    fun `starts empty`(@TempDir tmp: File) {
        val s = SessionOwnershipStore(tmp)
        assertTrue(s.names.isEmpty())
        assertTrue(s.agents.isEmpty())
    }

    @Test
    fun `names and agents round-trip across instances`(@TempDir tmp: File) {
        SessionOwnershipStore(tmp).apply {
            setName(a, "api server")
            setAgent(a, "claude")
        }
        // Caches load once at construction, so a fresh instance proves the write.
        val reloaded = SessionOwnershipStore(tmp)
        assertEquals("api server", reloaded.names[a])
        assertEquals("claude", reloaded.agents[a])
    }

    @Test
    fun `names and agents are independent maps`(@TempDir tmp: File) {
        val s = SessionOwnershipStore(tmp)
        s.setName(a, "frontend")
        s.setAgent(b, "codex")
        assertEquals(mapOf(a to "frontend"), s.names)
        assertEquals(mapOf(b to "codex"), s.agents)
    }

    // ---- diff-checking: the return value drives whether callers repaint ----

    @Test
    fun `setName reports a change only when the value actually differs`(@TempDir tmp: File) {
        val s = SessionOwnershipStore(tmp)
        assertTrue(s.setName(a, "first"), "first write is a change")
        assertFalse(s.setName(a, "first"), "rewriting the same value is not a change")
        assertTrue(s.setName(a, "second"), "a different value is a change")
    }

    @Test
    fun `setAgent reports a change only when the value actually differs`(@TempDir tmp: File) {
        val s = SessionOwnershipStore(tmp)
        assertTrue(s.setAgent(a, "claude"))
        assertFalse(s.setAgent(a, "claude"))
        assertTrue(s.setAgent(a, "codex"))
    }

    @Test
    fun `null removes the entry and reports the change once`(@TempDir tmp: File) {
        val s = SessionOwnershipStore(tmp)
        s.setName(a, "gone soon")
        assertTrue(s.setName(a, null), "removing an existing entry is a change")
        assertFalse(s.setName(a, null), "removing an absent entry is not a change")
        assertTrue(s.names.isEmpty())
    }

    @Test
    fun `removal is persisted`(@TempDir tmp: File) {
        SessionOwnershipStore(tmp).setName(a, "temp")
        SessionOwnershipStore(tmp).setName(a, null)
        assertTrue(SessionOwnershipStore(tmp).names.isEmpty())
    }

    // ---- format compatibility with the Android store ----

    @Test
    fun `keys are written as lowercase hyphenated uuids`(@TempDir tmp: File) {
        SessionOwnershipStore(tmp).setName(a, "x")
        val json = File(tmp, "sessionNames.json").readText()
        assertTrue(
            json.contains(a.toString().lowercase()),
            "on-disk format must match Android's so the two stores stay conceptually identical: $json",
        )
    }

    @Test
    fun `reads a map written in the android format`(@TempDir tmp: File) {
        File(tmp, "sessionNames.json").writeText("""{"$a":"from android"}""")
        assertEquals("from android", SessionOwnershipStore(tmp).names[a])
    }

    // ---- degradation ----

    @Test
    fun `corrupt json degrades to empty`(@TempDir tmp: File) {
        File(tmp, "sessionNames.json").writeText("not json at all")
        assertTrue(SessionOwnershipStore(tmp).names.isEmpty())
    }

    /**
     * One unparseable key must not cost the user every session name they have
     * set — the loader skips bad entries rather than failing the whole map.
     */
    @Test
    fun `a malformed key is skipped but valid siblings survive`(@TempDir tmp: File) {
        File(tmp, "sessionNames.json").writeText("""{"not-a-uuid":"skip me","$a":"keep me"}""")
        val names = SessionOwnershipStore(tmp).names
        assertEquals(1, names.size)
        assertEquals("keep me", names[a])
    }

    @Test
    fun `snapshots are defensive copies`(@TempDir tmp: File) {
        val s = SessionOwnershipStore(tmp)
        s.setName(a, "original")
        val snapshot = s.names
        s.setName(b, "added later")
        assertEquals(1, snapshot.size, "a taken snapshot must not observe later mutation")
    }
}
