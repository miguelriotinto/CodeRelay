package relay.storage

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class DeviceIdentifierTest {

    @Test
    fun getReturnsStableIdAcrossCalls() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val first = DeviceIdentifier.get(context)
        val second = DeviceIdentifier.get(context)
        assertEquals(first, second)
    }

    @Test
    fun getReturnsNonEmptyUuidParseableString() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val id = DeviceIdentifier.get(context)
        assertTrue("device id should be non-empty", id.isNotEmpty())
        // Parses as a UUID without throwing.
        assertEquals(id, UUID.fromString(id).toString())
    }
}
