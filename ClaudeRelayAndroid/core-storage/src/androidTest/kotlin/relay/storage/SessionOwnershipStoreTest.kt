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

    // MARK: - Legacy deviceId-namespace migration (commit 7d8daba)

    @Test
    fun migratesLegacyOwnedKeyToAidNamespace() {
        val id = UUID.randomUUID()
        val legacyUuid = "11111111-2222-3333-4444-555555555555"

        // Simulate a pre-upgrade install: owned set under the legacy UUID
        // namespace, and DeviceIdentifier's legacy persisted-UUID prefs.
        context.getSharedPreferences("relay.ownership", Context.MODE_PRIVATE)
            .edit().putString("ownedSessions.$legacyUuid", "[\"${id.toString().lowercase()}\"]").commit()
        context.getSharedPreferences("relay.device", Context.MODE_PRIVATE)
            .edit().putString("deviceId", legacyUuid).commit()

        // First launch on the new aid-* namespace: migration forward-copies the
        // legacy owned set, so the claim survives.
        val migrated = SessionOwnershipStore(context, "aid-abc123")
        assertTrue("legacy owned claim must survive the namespace change", id in migrated.owned)
    }

    @Test
    fun doesNotMigrateWhenNewKeyAlreadyPopulated() {
        val legacyId = UUID.randomUUID()
        val newId = UUID.randomUUID()
        val legacyUuid = "11111111-2222-3333-4444-555555555555"

        context.getSharedPreferences("relay.ownership", Context.MODE_PRIVATE).edit()
            .putString("ownedSessions.$legacyUuid", "[\"${legacyId.toString().lowercase()}\"]")
            .putString("ownedSessions.aid-abc123", "[\"${newId.toString().lowercase()}\"]")
            .commit()
        context.getSharedPreferences("relay.device", Context.MODE_PRIVATE)
            .edit().putString("deviceId", legacyUuid).commit()

        // The new namespace already has its own set → migration must NOT clobber it.
        val store = SessionOwnershipStore(context, "aid-abc123")
        assertTrue(newId in store.owned)
        assertFalse("must not overwrite an already-populated new key", legacyId in store.owned)
    }

    @Test
    fun doesNotMigrateForNonAidDeviceId() {
        val id = UUID.randomUUID()
        val legacyUuid = "11111111-2222-3333-4444-555555555555"
        context.getSharedPreferences("relay.ownership", Context.MODE_PRIVATE)
            .edit().putString("ownedSessions.$legacyUuid", "[\"${id.toString().lowercase()}\"]").commit()
        context.getSharedPreferences("relay.device", Context.MODE_PRIVATE)
            .edit().putString("deviceId", legacyUuid).commit()

        // A non-aid deviceId (e.g. still the legacy UUID itself) must not trigger
        // the migration onto a different key.
        val store = SessionOwnershipStore(context, "some-other-namespace")
        assertFalse(id in store.owned)
    }
}
