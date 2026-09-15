package relay.feature.settings

import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.mutablePreferencesOf
import androidx.datastore.preferences.core.stringPreferencesKey
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Pure-JVM tests for the `AppSettings` migrations: the legacy shortcut-modifier
 * mapping ported from `AppSettings.swift`, and the speech-removal scrub (spec §10).
 * The DataStore round-trip + secure-store I/O are instrumented/device tests
 * (DEFERRED — no emulator); the load-bearing logic here is exercised headless.
 */
class AppSettingsMigrationsTest {

    // MARK: - Shortcut-modifier mapping (AppSettings.swift:39-44)

    @Test
    fun `commandShift maps to Meta plus Shift`() {
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.SHIFT,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier("commandShift"),
        )
    }

    @Test
    fun `commandOption maps to Meta plus Alt`() {
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.ALT,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier("commandOption"),
        )
    }

    @Test
    fun `commandControl maps to Meta plus Ctrl`() {
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.CTRL,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier("commandControl"),
        )
    }

    @Test
    fun `unknown legacy modifier falls back to Meta plus Shift (iOS default branch)`() {
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.SHIFT,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier("somethingElse"),
        )
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.SHIFT,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier(""),
        )
    }

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
            booleanPreferencesKey("shareScreenWithOptimizer") to false,
            stringPreferencesKey("recordingShortcutKey") to "r",
        )

        AppSettingsMigrations.scrubSpeechKeys(prefs)

        AppSettingsMigrations.REMOVED_SPEECH_KEYS.forEach { key ->
            assertFalse(prefs.contains(key), "expected ${key.name} to be removed")
        }
        assertEquals(false, prefs[booleanPreferencesKey("hapticFeedbackEnabled")])
        assertEquals(false, prefs[booleanPreferencesKey("shareScreenWithOptimizer")])
        assertEquals("r", prefs[stringPreferencesKey("recordingShortcutKey")])
        assertEquals(3, prefs.asMap().size)
    }

    @Test
    fun `scrub is a no-op on a clean store`() {
        val prefs = mutablePreferencesOf(booleanPreferencesKey("autoConnectEnabled") to true)
        AppSettingsMigrations.scrubSpeechKeys(prefs)
        assertTrue(prefs.contains(booleanPreferencesKey("autoConnectEnabled")))
        assertEquals(1, prefs.asMap().size)
    }
}
