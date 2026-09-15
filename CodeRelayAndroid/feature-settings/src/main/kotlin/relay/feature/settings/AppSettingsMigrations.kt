package relay.feature.settings

import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey

/**
 * Pure (side-effect-free) pieces of the [AppSettings] startup migrations, factored
 * out so the load-bearing logic is unit-testable on the JVM without DataStore, the
 * EncryptedSharedPreferences-backed `TokenStore`, or an emulator.
 *
 * ## Android-faithfulness note
 *
 * On iOS the shortcut migration moves data written by **older app versions** (a
 * legacy `recordingShortcutModifier` String in `UserDefaults`) into the new Int
 * flags. No shipped Android build ever wrote that key, so on a real device it is a
 * no-op today. It is ported anyway — the same kind of best-effort forward-migration
 * hook the M1 `SavedConnectionStore` carries — so a future backup/restore or
 * cross-platform import that seeds the legacy key migrates identically to iOS.
 *
 * The speech-removal scrub is the opposite case: every shipped build before the
 * speech removal **did** write the speech settings and the Bedrock token (the build
 * that removes them is the one this comment ships in — `versionName` is deliberately
 * untouched by that change), so [REMOVED_SPEECH_KEYS] must stay in place for as long
 * as such installs can update.
 */
object AppSettingsMigrations {

    // MARK: - Shortcut-modifier migration (AppSettings.swift:31-48)

    /**
     * Legacy DataStore/prefs key that held the recording-shortcut modifier as a
     * String (`"commandShift"` / `"commandOption"` / `"commandControl"`) before it
     * became an Int flags bitmask. Matches the iOS `UserDefaults` key.
     */
    const val LEGACY_SHORTCUT_MODIFIER_KEY = "recordingShortcutModifier"

    /**
     * Maps a legacy `recordingShortcutModifier` String to the new
     * [ShortcutFlags] Int, mirroring the iOS `switch` exactly
     * (AppSettings.swift:39-44):
     *  - `"commandShift"`   → Meta + Shift
     *  - `"commandOption"`  → Meta + Alt   (Option)
     *  - `"commandControl"` → Meta + Control
     *  - anything else      → Meta + Shift (the iOS `default` branch)
     *
     * Pure — no I/O — so the mapping is unit-tested directly.
     */
    fun shortcutFlagsForLegacyModifier(legacyRaw: String): Int = when (legacyRaw) {
        "commandShift" -> ShortcutFlags.META or ShortcutFlags.SHIFT
        "commandOption" -> ShortcutFlags.META or ShortcutFlags.ALT
        "commandControl" -> ShortcutFlags.META or ShortcutFlags.CTRL
        else -> ShortcutFlags.META or ShortcutFlags.SHIFT
    }

    // MARK: - Speech-removal scrub (spec §10)

    /**
     * Every DataStore key the removed on-device speech stack wrote. Names are the
     * iOS `@AppStorage` keys verbatim (they were shared so an import could
     * round-trip), plus the legacy plaintext Bedrock token that predates the
     * secure store. `AppSettings` removes them on every launch; the Bedrock
     * credential in the secure store is deleted alongside.
     */
    val REMOVED_SPEECH_KEYS: List<Preferences.Key<*>> = listOf(
        booleanPreferencesKey("smartCleanupEnabled"),
        booleanPreferencesKey("promptEnhancementEnabled"),
        stringPreferencesKey("bedrockRegion"),
        booleanPreferencesKey("continuousListeningEnabled"),
        stringPreferencesKey("wakeWord"),
        stringPreferencesKey("bedrockBearerToken"),
    )

    /** Removes [REMOVED_SPEECH_KEYS] from [prefs]; leaves every other key untouched. */
    fun scrubSpeechKeys(prefs: MutablePreferences) {
        REMOVED_SPEECH_KEYS.forEach { prefs.remove(it) }
    }
}
