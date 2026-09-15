package relay.feature.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.mutablePreferencesOf
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.IOException
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * `AppSettings` startup behaviour: the speech-removal scrub's ordering and failure
 * isolation (I1 — the secret-delete failure must not suppress the DataStore scrub,
 * the secret is deleted before the DataStore is read, and an unreadable DataStore
 * neither skips the delete nor escapes `runMigrations`), plus the one new setting's
 * key name and default.
 *
 * `callOrder` / `deleterInvoked` are shared across threads on purpose: the deleter
 * runs inside `withContext(Dispatchers.IO)`, so plain mutable state here would be a
 * flake source rather than a test.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AppSettingsScrubTest {

    @Test
    fun `throwing secret deleter does not stop the DataStore scrub`() = runTest {
        // Given: a DataStore pre-seeded with one removed speech key and one unrelated key.
        val speechKey = stringPreferencesKey("bedrockBearerToken")
        assertTrue(
            speechKey in AppSettingsMigrations.REMOVED_SPEECH_KEYS,
            "the legacy plaintext token must still be one of the scrubbed keys",
        )
        // Use a key that doesn't conflict with any StateFlow keys
        val unrelatedKey = stringPreferencesKey("someUnrelatedKey")
        val initialPrefs = mutablePreferencesOf()
        initialPrefs[speechKey] = "old-value"
        initialPrefs[unrelatedKey] = "survivor"
        val store = FakePrefsStore(initialPrefs)

        val deleterInvoked = AtomicBoolean(false)
        val throwingDeleter = BedrockSecretDeleter {
            deleterInvoked.set(true)
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

        assertTrue(deleterInvoked.get(), "secret deleter must be invoked")

        // And: the DataStore scrub still ran (the speech key is gone)
        val prefs = store.state.value
        assertFalse(prefs.contains(speechKey), "speech key must be removed")
        assertEquals("survivor", prefs[unrelatedKey], "unrelated key must survive")
    }

    @Test
    fun `secret is deleted before the DataStore is read`() = runTest {
        val callOrder = Collections.synchronizedList(mutableListOf<String>())

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
                    delay(10)
                }
                // Wait a bit more for any subsequent reads
                delay(100)
            }
        }

        // The delete should come before the LAST read (the ones from the scrub and
        // the shortcut migration). Many reads happen first from StateFlow
        // initialization, which is construction-time and unrelated to the ordering.
        val deleteIndex = callOrder.indexOf("delete")
        val lastReadIndex = callOrder.lastIndexOf("read")

        assertTrue(deleteIndex >= 0, "delete must be recorded")
        assertTrue(lastReadIndex >= 0, "at least one read must be recorded")

        // The key assertion: delete happens before the last read (from removeSpeechSettings)
        // If delete is the last event, that means removeSpeechSettings hasn't read yet, which is wrong
        assertTrue(deleteIndex < callOrder.size - 1, "delete must not be the last event")
        assertTrue(lastReadIndex > deleteIndex, "removeSpeechSettings read must happen after delete, got: $callOrder")
    }

    @Test
    fun `an unreadable DataStore neither skips the secret delete nor escapes runMigrations`() = runTest {
        // The B1-I1 regression: with the shortcut migration first and unguarded, a
        // DataStore that throws on every read (a corrupt `app_settings` has no
        // corruption handler, so it throws for the life of the install) both skipped
        // the Bedrock delete forever and killed the process from `onCreate` —
        // an escape here fails this test, because backgroundScope reports it.
        val deleterInvoked = AtomicBoolean(false)
        val store = BreaksAfterDeleteStore(deleterInvoked)

        AppSettings(
            dataStore = store,
            secretDeleter = BedrockSecretDeleter { deleterInvoked.set(true) },
            scope = backgroundScope,
        )

        withContext(Dispatchers.Default.limitedParallelism(1)) {
            withTimeout(5_000) {
                while (store.failedReads.get() < 2) {
                    delay(10)
                }
            }
        }

        assertTrue(deleterInvoked.get(), "the secret delete must not wait on DataStore health")
        // Two reads reached the broken store and were swallowed: the scrub's own and
        // the shortcut migration's. One would mean the shortcut migration read first,
        // while the store was still healthy — the old, wrong order.
        assertEquals(2, store.failedReads.get(), "both migration reads must hit the broken store")
    }

    @Test
    fun `shareScreenWithOptimizer defaults to on and persists under the iOS key name`() = runTest {
        // The key string is load-bearing for import parity with iOS's
        // @AppStorage("shareScreenWithOptimizer"), and `true` is a privacy default.
        val key = booleanPreferencesKey("shareScreenWithOptimizer")
        val store = FakePrefsStore()
        val settings = AppSettings(
            dataStore = store,
            secretDeleter = BedrockSecretDeleter { },
            scope = backgroundScope,
        )

        assertTrue(settings.shareScreenWithOptimizer.value, "an empty store must read as on")

        settings.setShareScreenWithOptimizer(false)
        withContext(Dispatchers.Default.limitedParallelism(1)) {
            withTimeout(5_000) {
                store.state.first { it[key] == false }
            }
        }
        assertEquals(false, store.state.value[key], "the write must land under the iOS key name")
    }

    /**
     * In-memory fake DataStore for testing, per the brief. No file I/O; no Robolectric.
     */
    private open class FakePrefsStore(initial: Preferences = emptyPreferences()) : DataStore<Preferences> {
        val state = MutableStateFlow(initial)
        override val data: Flow<Preferences>
            get() = state

        override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences {
            state.value = transform(state.value)
            return state.value
        }
    }

    /**
     * Healthy while the constructor hydrates the ten eager `stateIn` mirrors, then
     * unreadable from the moment the secret delete runs — i.e. for exactly the two
     * reads `runMigrations` performs. Failing from time zero would instead break the
     * mirrors, which is a separate pre-existing hazard and would drown this
     * assertion.
     */
    private class BreaksAfterDeleteStore(private val broken: AtomicBoolean) : DataStore<Preferences> {
        val failedReads = AtomicInteger(0)
        private val state = MutableStateFlow(emptyPreferences())

        override val data: Flow<Preferences>
            get() = if (broken.get()) {
                flow {
                    failedReads.incrementAndGet()
                    throw IOException("simulated CorruptionException")
                }
            } else {
                state
            }

        override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences =
            throw IOException("simulated CorruptionException")
    }
}
