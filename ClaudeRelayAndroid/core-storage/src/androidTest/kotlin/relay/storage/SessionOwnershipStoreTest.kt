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

@RunWith(AndroidJUnit4::class)
class SessionOwnershipStoreTest {

    private lateinit var context: Context
    private val deviceA = "device-a"
    private val deviceB = "device-b"

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
    fun claimAndNamePersistAcrossInstances() {
        val id = UUID.randomUUID()
        val s1 = store()
        assertTrue(s1.claim(id))
        assertTrue(s1.setName(id, "Arya"))
        assertTrue(s1.setAgent(id, "claude"))

        // A new instance with the same deviceId reads the persisted state.
        val s2 = store()
        assertTrue(id in s2.owned)
        assertEquals("Arya", s2.names[id])
        assertEquals("claude", s2.agents[id])
    }

    @Test
    fun unclaimAndNullRemovalPersist() {
        val id = UUID.randomUUID()
        val s1 = store()
        s1.claim(id)
        s1.setName(id, "Arya")
        s1.setAgent(id, "claude")

        assertTrue(s1.unclaim(id))
        assertTrue(s1.setName(id, null))
        assertTrue(s1.setAgent(id, null))

        val s2 = store()
        assertFalse(id in s2.owned)
        assertNull(s2.names[id])
        assertNull(s2.agents[id])
    }

    @Test
    fun ownedSetIsDeviceScoped() {
        val id = UUID.randomUUID()
        store(deviceA).claim(id)

        // A different deviceId sees no owned ids (device-scoped key), but the
        // device-independent names/agents maps would still be shared.
        val onB = store(deviceB)
        assertFalse(id in onB.owned)
        assertTrue(id in store(deviceA).owned)
    }

    @Test
    fun noOpWriteDoesNotChangeState() {
        val id = UUID.randomUUID()
        val s = store()
        assertTrue(s.setName(id, "Arya"))
        // Setting the same value again is a no-op (diff-checked).
        assertFalse(s.setName(id, "Arya"))

        assertTrue(s.claim(id))
        assertFalse(s.claim(id))

        assertTrue(s.setAgent(id, "claude"))
        assertFalse(s.setAgent(id, "claude"))

        // Removing something absent is also a no-op.
        val absent = UUID.randomUUID()
        assertFalse(s.unclaim(absent))
        assertFalse(s.setName(absent, null))
        assertFalse(s.setAgent(absent, null))
    }
}
