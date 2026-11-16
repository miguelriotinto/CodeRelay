package relay.feature.settings

import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

/**
 * Linux builds ≤ v0.3.25 wrote five speech preferences, and builds before the
 * prompt optimizer's removal wrote its share-screen gate and shortcut settings;
 * all must be pruned. The scrub runs at construction (idempotent, no flag) so
 * older settings files are cleaned on first launch after upgrade.
 */
class AppSettingsLegacyScrubTest {

    private fun store(tmp: File, scope: TestScope) =
        PreferenceStore(File(tmp, "settings.json"), scope)

    /**
     * The five legacy keys written by builds with the speech stack: four bools
     * plus `wakeWord` (user-typed text).
     */
    @Test
    fun `legacy speech preferences are pruned at construction`(@TempDir tmp: File) = runTest {
        val prefs = store(tmp, this)
        // Seed a store the way a v0.3.25 build would have written it.
        prefs.put("smartCleanupEnabled", true)
        prefs.put("promptEnhancementEnabled", false)
        prefs.put("bedrockRegion", "us-west-2")
        prefs.put("continuousListeningEnabled", true)
        prefs.put("wakeWord", "hey computer")
        prefs.put("hapticFeedbackEnabled", false)  // live key, must survive

        // Construct AppSettings — the scrub runs in init.
        AppSettings(prefs)

        // All five legacy keys must be gone.
        assertFalse(prefs.contains("smartCleanupEnabled"))
        assertFalse(prefs.contains("promptEnhancementEnabled"))
        assertFalse(prefs.contains("bedrockRegion"))
        assertFalse(prefs.contains("continuousListeningEnabled"))
        assertFalse(prefs.contains("wakeWord"))

        // Live preference must survive.
        assertTrue(prefs.contains("hapticFeedbackEnabled"))
        assertFalse(prefs.boolFlow("hapticFeedbackEnabled", true).value)
    }

    /** The scrub is idempotent: running it again on a clean store is a no-op. */
    @Test
    fun `scrub is idempotent on a clean store`(@TempDir tmp: File) = runTest {
        val prefs = store(tmp, this)
        prefs.put("autoConnectEnabled", true)
        AppSettings(prefs)
        // Second construction: no legacy keys to scrub, no crash.
        AppSettings(prefs)
        assertTrue(prefs.contains("autoConnectEnabled"))
    }

    /** The prompt optimizer's four keys are pruned; live keys survive. */
    @Test
    fun `removed optimizer preferences are pruned at construction`(@TempDir tmp: File) = runTest {
        val prefs = store(tmp, this)
        prefs.put("shareScreenWithOptimizer", false)
        prefs.put("recordingShortcutEnabled", true)
        prefs.put("recordingShortcutFlags", 123)
        prefs.put("recordingShortcutKey", "r")
        prefs.put("hapticFeedbackEnabled", false)  // live key, must survive

        AppSettings(prefs)

        assertFalse(prefs.contains("shareScreenWithOptimizer"))
        assertFalse(prefs.contains("recordingShortcutEnabled"))
        assertFalse(prefs.contains("recordingShortcutFlags"))
        assertFalse(prefs.contains("recordingShortcutKey"))
        assertTrue(prefs.contains("hapticFeedbackEnabled"))
    }
}
