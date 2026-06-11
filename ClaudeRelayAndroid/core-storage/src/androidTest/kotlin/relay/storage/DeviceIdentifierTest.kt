package relay.storage

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DeviceIdentifierTest {

    @Test
    fun getReturnsStableIdAcrossCalls() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val first = DeviceIdentifier.get(context)
        val second = DeviceIdentifier.get(context)
        assertEquals(first, second)
    }

    @Test
    fun getReturnsNonEmptyString() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val id = DeviceIdentifier.get(context)
        assertTrue("device id should be non-empty", id.isNotEmpty())
    }

    /**
     * The load-bearing guarantee for the Huawei session-loss fix: the id must be
     * stable even if the (non-encrypted) device prefs file is wiped between reads,
     * because it is derived from the OS `ANDROID_ID` (or, failing that, memoised in
     * process). A regenerating id silently re-namespaces device-scoped storage and
     * the owned-session set reads back empty.
     */
    @Test
    fun getIsStableEvenWhenDevicePrefsAreCleared() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val first = DeviceIdentifier.get(context)

        // Wipe the fallback prefs file the old implementation depended on.
        context.getSharedPreferences("relay.device", Context.MODE_PRIVATE)
            .edit().clear().commit()

        val second = DeviceIdentifier.get(context)
        assertEquals("device id must not change when device prefs are cleared", first, second)
    }
}
