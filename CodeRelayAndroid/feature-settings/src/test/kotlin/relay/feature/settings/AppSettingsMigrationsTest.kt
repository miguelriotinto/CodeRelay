package relay.feature.settings

import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.mutablePreferencesOf
import androidx.datastore.preferences.core.stringPreferencesKey
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Pure-JVM tests for the `AppSettings` scrubs: the speech-removal scrub (spec §10)
 * and the prompt-optimizer-removal scrub.
 * The DataStore round-trip + secure-store I/O are instrumented/device tests
 * (DEFERRED — no emulator); the load-bearing logic here is exercised headless.
 */
class AppSettingsMigrationsTest {

    // MARK: - Speech-removal scrub (spec §10)

    @Test
    fun `removed speech keys are exactly the six the speech stack wrote`() {
        // Names are the iOS @AppStorage keys verbatim (they were shared for import
        // round-trips), plus the legacy plaintext Bedrock token key.
        assertEquals(
            listOf(
                "smartCleanupEnabled",
                "promptEnhancementEnabled",
                "bedrockRegion",
                "continuousListeningEnabled",
                "wakeWord",
                "bedrockBearerToken",
            ),
            AppSettingsMigrations.REMOVED_SPEECH_KEYS.map { it.name },
        )
    }

    @Test
    fun `scrub removes every speech key and nothing else`() {
        val prefs = mutablePreferencesOf(
            booleanPreferencesKey("smartCleanupEnabled") to true,
            booleanPreferencesKey("promptEnhancementEnabled") to true,
            stringPreferencesKey("bedrockRegion") to "eu-west-1",
            booleanPreferencesKey("continuousListeningEnabled") to true,
            stringPreferencesKey("wakeWord") to "computer",
            stringPreferencesKey("bedrockBearerToken") to "legacy-plaintext",
            // Survivors:
            booleanPreferencesKey("hapticFeedbackEnabled") to false,
            intPreferencesKey("terminalScrollbackLines") to 1_000,
        )

        AppSettingsMigrations.scrubSpeechKeys(prefs)

        AppSettingsMigrations.REMOVED_SPEECH_KEYS.forEach { key ->
            assertFalse(prefs.contains(key), "expected ${key.name} to be removed")
        }
        assertEquals(false, prefs[booleanPreferencesKey("hapticFeedbackEnabled")])
        assertEquals(1_000, prefs[intPreferencesKey("terminalScrollbackLines")])
        assertEquals(2, prefs.asMap().size)
    }

    @Test
    fun `scrub is a no-op on a clean store`() {
        val prefs = mutablePreferencesOf(booleanPreferencesKey("autoConnectEnabled") to true)
        AppSettingsMigrations.scrubSpeechKeys(prefs)
        assertTrue(prefs.contains(booleanPreferencesKey("autoConnectEnabled")))
        assertEquals(1, prefs.asMap().size)
    }

    // MARK: - Prompt-optimizer-removal scrub

    @Test
    fun `removed optimizer keys are the share-screen gate and the optimizer shortcut`() {
        assertEquals(
            listOf(
                "shareScreenWithOptimizer",
                "recordingShortcutEnabled",
                "recordingShortcutFlags",
                "recordingShortcutKey",
                "recordingShortcutModifier",
            ),
            AppSettingsMigrations.REMOVED_OPTIMIZER_KEYS.map { it.name },
        )
    }

    @Test
    fun `optimizer scrub removes every optimizer key and nothing else`() {
        val prefs = mutablePreferencesOf(
            booleanPreferencesKey("shareScreenWithOptimizer") to false,
            booleanPreferencesKey("recordingShortcutEnabled") to true,
            intPreferencesKey("recordingShortcutFlags") to 123,
            stringPreferencesKey("recordingShortcutKey") to "r",
            stringPreferencesKey("recordingShortcutModifier") to "commandShift",
            // Survivors:
            booleanPreferencesKey("hapticFeedbackEnabled") to false,
            intPreferencesKey("terminalScrollbackLines") to 1_000,
        )

        AppSettingsMigrations.scrubOptimizerKeys(prefs)

        AppSettingsMigrations.REMOVED_OPTIMIZER_KEYS.forEach { key ->
            assertFalse(prefs.contains(key), "expected ${key.name} to be removed")
        }
        assertEquals(false, prefs[booleanPreferencesKey("hapticFeedbackEnabled")])
        assertEquals(1_000, prefs[intPreferencesKey("terminalScrollbackLines")])
        assertEquals(2, prefs.asMap().size)
    }

    @Test
    fun `optimizer scrub is a no-op on a clean store`() {
        val prefs = mutablePreferencesOf(booleanPreferencesKey("autoConnectEnabled") to true)
        AppSettingsMigrations.scrubOptimizerKeys(prefs)
        assertTrue(prefs.contains(booleanPreferencesKey("autoConnectEnabled")))
        assertEquals(1, prefs.asMap().size)
    }
}
