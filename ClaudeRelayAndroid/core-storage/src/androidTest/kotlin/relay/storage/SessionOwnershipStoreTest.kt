package relay.storage

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/**
 * Ownership is NOT persisted — the server's token-scoped session list is
 * authoritative. This store keeps only the device-independent auxiliary maps
 * (display names, last-seen agent per session), and these tests cover their
 * persistence round-trips and diff-checked writes.
 */
@RunWith(AndroidJUnit4::class)
class SessionOwnershipStoreTest {

    private lateinit var context: Context
    private val deviceA = "device-a"

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        // The SharedPreferences file persists across runs on a real device.
        // Start each test from a known-empty state.
        context.getSharedPreferences("relay.ownership", Context.MODE_PRIVATE)
            .edit().clear().commit()
    }

    private fun store(deviceId: String = deviceA) =
        SessionOwnershipStore(context, deviceId)

    @Test
    fun nameAndAgentPersistAcrossInstances() {
        val id = UUID.randomUUID()
        val s1 = store()
        assertTrue(s1.setName(id, "Arya"))
        assertTrue(s1.setAgent(id, "claude"))

        // A new instance reads the persisted state.
        val s2 = store()
        assertEquals("Arya", s2.names[id])
        assertEquals("claude", s2.agents[id])
    }

    @Test
    fun nullRemovalPersists() {
        val id = UUID.randomUUID()
        val s1 = store()
        s1.setName(id, "Arya")
        s1.setAgent(id, "claude")

        assertTrue(s1.setName(id, null))
        assertTrue(s1.setAgent(id, null))

        val s2 = store()
        assertNull(s2.names[id])
        assertNull(s2.agents[id])
    }

    @Test
    fun namesAndAgentsAreDeviceIndependent() {
        // The auxiliary maps are NOT device-scoped (names/agents are shared) —
        // a second instance with a different deviceId sees the same entries.
        val id = UUID.randomUUID()
        store(deviceA).setName(id, "Arya")

        val other = SessionOwnershipStore(context, "device-b")
        assertEquals("Arya", other.names[id])
    }

    @Test
    fun noOpWriteDoesNotReportChange() {
        val id = UUID.randomUUID()
        val s = store()
        assertTrue(s.setName(id, "Arya"))
        // Setting the same value again is a no-op (diff-checked).
        assertFalse(s.setName(id, "Arya"))

        assertTrue(s.setAgent(id, "claude"))
        assertFalse(s.setAgent(id, "claude"))

        // Removing something absent is also a no-op.
        val absent = UUID.randomUUID()
        assertFalse(s.setName(absent, null))
        assertFalse(s.setAgent(absent, null))
    }
}
