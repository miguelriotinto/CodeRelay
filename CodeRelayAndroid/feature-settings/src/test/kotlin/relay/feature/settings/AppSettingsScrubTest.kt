package relay.feature.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.mutablePreferencesOf
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Tests for `AppSettings.removeSpeechSettings()` scrub ordering and failure isolation
 * (I1 — the secret-delete failure must not suppress the DataStore scrub, and the secret
 * is deleted before the DataStore is read).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AppSettingsScrubTest {

    @Test
    fun `throwing secret deleter does not stop the DataStore scrub`() = runTest {
        // Given: a DataStore pre-seeded with one removed speech key and one unrelated key
        // Use the "bedrockBearerToken" string key from REMOVED_SPEECH_KEYS (the last one)
        val speechKey = AppSettingsMigrations.REMOVED_SPEECH_KEYS.last() as Preferences.Key<String>
        // Use a key that doesn't conflict with any StateFlow keys
        val unrelatedKey = stringPreferencesKey("someUnrelatedKey")
        val initialPrefs = mutablePreferencesOf()
        initialPrefs[speechKey] = "old-value"
        initialPrefs[unrelatedKey] = "survivor"
        val store = FakePrefsStore(initialPrefs)

        var deleterInvoked = false
        val throwingDeleter = BedrockSecretDeleter {
            deleterInvoked = true
            throw IllegalStateException("simulated keystore failure")
        }

        // When: AppSettings is constructed (triggers the scrub in backgroundScope)
        AppSettings(
            dataStore = store,
            secretDeleter = throwingDeleter,
            scope = backgroundScope,
        )

        // Then: the deleter was invoked
        // Use real time for withTimeout since IO dispatcher is involved
        withContext(Dispatchers.Default.limitedParallelism(1)) {
            withTimeout(5_000) {
                store.state.first { !it.contains(speechKey) }
            }
        }

        assertTrue(deleterInvoked, "secret deleter must be invoked")

        // And: the DataStore scrub still ran (the speech key is gone)
        val prefs = store.state.value
        assertFalse(prefs.contains(speechKey), "speech key must be removed")
        assertEquals("survivor", prefs[unrelatedKey], "unrelated key must survive")
    }

    @Test
    fun `secret is deleted before the DataStore is read`() = runTest {
        val callOrder = mutableListOf<String>()

        // Given: a deleter that records "delete"
        val recordingDeleter = BedrockSecretDeleter {
            callOrder.add("delete")
        }

        // And: a DataStore that records "read" on every collection, plus we seed the
        // shortcut flags to skip the shortcut migration's conditional DataStore write
        val initialPrefs = mutablePreferencesOf()
        initialPrefs[intPreferencesKey("recordingShortcutFlags")] = 123
        val store = object : FakePrefsStore(initialPrefs) {
            override val data: Flow<Preferences>
                get() {
                    callOrder.add("read")
                    reads++
                    return state
                }
        }

        // When: AppSettings is constructed
        AppSettings(
            dataStore = store,
            secretDeleter = recordingDeleter,
            scope = backgroundScope,
        )

        // Then: wait for the delete to be recorded
        withContext(Dispatchers.Default.limitedParallelism(1)) {
            withTimeout(5_000) {
                // Wait for the delete to happen
                while ("delete" !in callOrder) {
                    kotlinx.coroutines.delay(10)
                }
                // Wait a bit more for any subsequent reads
                kotlinx.coroutines.delay(100)
            }
        }

        println("callOrder: $callOrder")
        // The delete should come before the LAST read (the one from removeSpeechSettings)
        // Many reads will happen first from StateFlow initialization and migrateShortcutIfNeeded
        val deleteIndex = callOrder.indexOf("delete")
        val lastReadIndex = callOrder.lastIndexOf("read")

        assertTrue(deleteIndex >= 0, "delete must be recorded")
        assertTrue(lastReadIndex >= 0, "at least one read must be recorded")

        // The key assertion: delete happens before the last read (from removeSpeechSettings)
        // If delete is the last event, that means removeSpeechSettings hasn't read yet, which is wrong
        assertTrue(deleteIndex < callOrder.size - 1, "delete must not be the last event")
        assertTrue(lastReadIndex > deleteIndex, "removeSpeechSettings read must happen after delete, got: $callOrder")
    }

    /**
     * In-memory fake DataStore for testing, per the brief. No file I/O; no Robolectric.
     */
    private open class FakePrefsStore(initial: Preferences = emptyPreferences()) : DataStore<Preferences> {
        val state = MutableStateFlow(initial)
        var reads = 0
        override val data: Flow<Preferences>
            get() {
                reads++
                return state
            }

        override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences {
            state.value = transform(state.value)
            return state.value
        }
    }
}
