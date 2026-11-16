package relay.feature.settings

import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey

/**
 * Pure (side-effect-free) pieces of the [AppSettings] startup scrubs, factored
 * out so the load-bearing logic is unit-testable on the JVM without DataStore, the
 * EncryptedSharedPreferences-backed `TokenStore`, or an emulator.
 *
 * Both scrubs are the "removed feature" case: every shipped build before the
 * removal **did** write these keys (the speech settings and the Bedrock token;
 * the prompt-optimizer share-screen toggle and its keyboard-shortcut settings), so
 * [REMOVED_SPEECH_KEYS] and [REMOVED_OPTIMIZER_KEYS] must stay in place for as long
 * as such installs can update.
 */
object AppSettingsMigrations {

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

    // MARK: - Prompt-optimizer-removal scrub

    /**
     * Every DataStore key the removed prompt optimizer wrote: the device-side
     * share-screen gate, and the "Optimizer Shortcut" settings (enabled, modifier
     * flags, key) together with the pre-flags `recordingShortcutModifier` String.
     * `AppSettings` removes them on every launch.
     */
    val REMOVED_OPTIMIZER_KEYS: List<Preferences.Key<*>> = listOf(
        booleanPreferencesKey("shareScreenWithOptimizer"),
        booleanPreferencesKey("recordingShortcutEnabled"),
        intPreferencesKey("recordingShortcutFlags"),
        stringPreferencesKey("recordingShortcutKey"),
        stringPreferencesKey("recordingShortcutModifier"),
    )

    /** Removes [REMOVED_OPTIMIZER_KEYS] from [prefs]; leaves every other key untouched. */
    fun scrubOptimizerKeys(prefs: MutablePreferences) {
        REMOVED_OPTIMIZER_KEYS.forEach { prefs.remove(it) }
    }
}
