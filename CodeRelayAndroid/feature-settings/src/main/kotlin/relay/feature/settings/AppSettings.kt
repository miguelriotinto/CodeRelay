package relay.feature.settings

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import relay.protocol.SessionNamingTheme
import relay.storage.TokenStore

/**
 * Tiny seam for the Bedrock secret deletion, extracted so `AppSettings`' speech-removal
 * scrub is testable without a real `EncryptedSharedPreferences` (which `TokenStore` wraps).
 */
fun interface BedrockSecretDeleter {
    fun deleteBedrockToken()
}

/**
 * App-wide user settings, ported from `AppSettings.swift`.
 *
 * iOS persists these via SwiftUI `@AppStorage` (UserDefaults). The Android analog
 * is a single Preferences [DataStore] (`app_settings`) holding **the 10 keys this
 * client persists** — a subset of iOS's twelve, which additionally carries the two
 * push prefs (`pushNotificationsEnabled`, `pushNotifyOnFinished`; Android hardcodes
 * those in `PushSync`). Key *names* match iOS verbatim. Each is surfaced here as a
 * [StateFlow] plus a `set…` mutator.
 *
 * ## The 10 DataStore keys (defaults match AppSettings.swift)
 *  1. `hapticFeedbackEnabled`      = true
 *  2. `autoConnectEnabled`         = false
 *  3. `lastConnectedServerId`      = ""
 *  4. `sessionNamingTheme`         = gameOfThrones
 *  5. `terminalFontSize`           = 12.0
 *  6. `terminalScrollbackLines`    = 5000
 *  7. `recordingShortcutEnabled`   = true
 *  8. `recordingShortcutFlags`     = Meta+Alt ([ShortcutFlags.DEFAULT])
 *  9. `recordingShortcutKey`       = ""
 * 10. `shareScreenWithOptimizer`   = true   (spec §7.1 — sent as `shareScreen` on every `optimize_prompt`)
 *
 * The speech stack's six keys (`smartCleanupEnabled`, `promptEnhancementEnabled`,
 * `bedrockRegion`, `continuousListeningEnabled`, `wakeWord`, and the legacy
 * plaintext `bedrockBearerToken`) plus the Bedrock credential in the secure
 * [TokenStore] are **scrubbed on every launch** by [removeSpeechSettings]
 * (spec §10) — every shipped build before the speech removal wrote them.
 *
 * @param scope a long-lived scope (the host injects an application-scoped one);
 *   owns the StateFlow hot mirrors and the startup migrations.
 */
class AppSettings(
    private val dataStore: DataStore<Preferences>,
    private val secretDeleter: BedrockSecretDeleter,
    private val scope: CoroutineScope,
) {

    // MARK: - Startup: migrations

    init {
        scope.launch { runMigrations() }
    }

    /**
     * Best-effort forward migrations, in launch order: the speech scrub first, then
     * the shortcut one (a no-op on any real Android install — see
     * [AppSettingsMigrations]).
     *
     * The order and the guard are both load-bearing. `app_settings` is created with
     * no `corruptionHandler`, so a malformed file makes **every** DataStore read
     * throw for the life of the install. Running the shortcut migration first, and
     * unguarded, would then (a) skip the Bedrock secret delete forever — on exactly
     * the devices whose DataStore is broken, which is what "secret first" exists to
     * survive — and (b) let the exception escape this `scope.launch` into the
     * default uncaught handler, killing the process during `MainActivity.onCreate`.
     */
    private suspend fun runMigrations() {
        removeSpeechSettings()
        runCatching { migrateShortcutIfNeeded() }
            .onFailure { if (it is CancellationException) throw it }
    }

    /**
     * Migrate the legacy `recordingShortcutModifier` String → `recordingShortcutFlags`
     * Int. Mirrors AppSettings.swift:31-48: only migrate when the legacy key is
     * present and the new flags key has not been set, then delete the legacy key.
     */
    private suspend fun migrateShortcutIfNeeded() {
        val prefs = dataStore.data.first()
        val legacy = prefs[LEGACY_SHORTCUT_MODIFIER_KEY] ?: return
        if (prefs.contains(RECORDING_SHORTCUT_FLAGS)) return
        val flags = AppSettingsMigrations.shortcutFlagsForLegacyModifier(legacy)
        dataStore.edit {
            it[RECORDING_SHORTCUT_FLAGS] = flags
            it.remove(LEGACY_SHORTCUT_MODIFIER_KEY)
        }
    }

    /**
     * Speech-removal scrub (spec §10), the Android counterpart of the Apple
     * clients' `SpeechRemovalMigration`. Runs every launch: it is idempotent and
     * cheap, and having no "done" flag means it can never be marked complete before
     * the deletion landed. Order: secret first (it is the higher-value item), then
     * DataStore; each half guarded; the secure-store delete runs on IO.
     */
    private suspend fun removeSpeechSettings() {
        // Secret first: it is the higher-value item and must not wait on DataStore health.
        // `runCatching` catches Throwable, so each half rethrows CancellationException:
        // absorbing it would let a cancelled scope keep running the next statement.
        runCatching { withContext(Dispatchers.IO) { secretDeleter.deleteBedrockToken() } }
            .onFailure { if (it is CancellationException) throw it }
        runCatching {
            val prefs = dataStore.data.first()
            if (AppSettingsMigrations.REMOVED_SPEECH_KEYS.any { prefs.contains(it) }) {
                dataStore.edit { AppSettingsMigrations.scrubSpeechKeys(it) }
            }
        }.onFailure { if (it is CancellationException) throw it }
    }

    // MARK: - StateFlow mirrors + setters (the 10 keys)

    val hapticFeedbackEnabled: StateFlow<Boolean> = boolFlow(HAPTIC_FEEDBACK, true)
    fun setHapticFeedbackEnabled(value: Boolean) = put(HAPTIC_FEEDBACK, value)

    val autoConnectEnabled: StateFlow<Boolean> = boolFlow(AUTO_CONNECT, false)
    fun setAutoConnectEnabled(value: Boolean) = put(AUTO_CONNECT, value)

    val lastConnectedServerId: StateFlow<String> = stringFlow(LAST_CONNECTED_SERVER_ID, "")
    fun setLastConnectedServerId(value: String) = put(LAST_CONNECTED_SERVER_ID, value)

    /** Stored as the [SessionNamingTheme.rawValue]; resolves via `fromRaw` (falls back to DEFAULT). */
    val sessionNamingTheme: StateFlow<SessionNamingTheme> =
        dataStore.data
            .map { SessionNamingTheme.fromRaw(it[SESSION_NAMING_THEME] ?: SessionNamingTheme.DEFAULT.rawValue) }
            .stateIn(scope, SharingStarted.Eagerly, SessionNamingTheme.DEFAULT)
    fun setSessionNamingTheme(value: SessionNamingTheme) = put(SESSION_NAMING_THEME, value.rawValue)

    val terminalFontSize: StateFlow<Double> = doubleFlow(TERMINAL_FONT_SIZE, 12.0)
    fun setTerminalFontSize(value: Double) = put(TERMINAL_FONT_SIZE, value)

    val terminalScrollbackLines: StateFlow<Int> = intFlow(TERMINAL_SCROLLBACK_LINES, 5_000)
    fun setTerminalScrollbackLines(value: Int) = put(TERMINAL_SCROLLBACK_LINES, value)

    val recordingShortcutEnabled: StateFlow<Boolean> = boolFlow(RECORDING_SHORTCUT_ENABLED, true)
    fun setRecordingShortcutEnabled(value: Boolean) = put(RECORDING_SHORTCUT_ENABLED, value)

    val recordingShortcutFlags: StateFlow<Int> = intFlow(RECORDING_SHORTCUT_FLAGS, ShortcutFlags.DEFAULT)
    fun setRecordingShortcutFlags(value: Int) = put(RECORDING_SHORTCUT_FLAGS, value)

    val recordingShortcutKey: StateFlow<String> = stringFlow(RECORDING_SHORTCUT_KEY, "")
    fun setRecordingShortcutKey(value: String) = put(RECORDING_SHORTCUT_KEY, value)

    /**
     * Whether `optimize_prompt` may carry the last 40 screen lines (spec §7.1).
     * The device-side gate; the relay has its own (`promptOptimizerShareScreen`).
     * Eagerly seeded with the default until the first DataStore emission; the wand
     * needs an attached session, which takes longer than hydration.
     */
    val shareScreenWithOptimizer: StateFlow<Boolean> = boolFlow(SHARE_SCREEN_WITH_OPTIMIZER, true)
    fun setShareScreenWithOptimizer(value: Boolean) = put(SHARE_SCREEN_WITH_OPTIMIZER, value)

    // MARK: - DataStore plumbing

    private fun boolFlow(key: Preferences.Key<Boolean>, default: Boolean): StateFlow<Boolean> =
        dataStore.data.map { it[key] ?: default }.stateIn(scope, SharingStarted.Eagerly, default)

    private fun stringFlow(key: Preferences.Key<String>, default: String): StateFlow<String> =
        dataStore.data.map { it[key] ?: default }.stateIn(scope, SharingStarted.Eagerly, default)

    private fun intFlow(key: Preferences.Key<Int>, default: Int): StateFlow<Int> =
        dataStore.data.map { it[key] ?: default }.stateIn(scope, SharingStarted.Eagerly, default)

    private fun doubleFlow(key: Preferences.Key<Double>, default: Double): StateFlow<Double> =
        dataStore.data.map { it[key] ?: default }.stateIn(scope, SharingStarted.Eagerly, default)

    private fun <T> put(key: Preferences.Key<T>, value: T) {
        scope.launch { dataStore.edit { it[key] = value } }
    }

    companion object {
        // The 10 DataStore keys (names match the iOS @AppStorage keys verbatim so
        // a cross-platform import round-trips).
        private val HAPTIC_FEEDBACK = booleanPreferencesKey("hapticFeedbackEnabled")
        private val AUTO_CONNECT = booleanPreferencesKey("autoConnectEnabled")
        private val LAST_CONNECTED_SERVER_ID = stringPreferencesKey("lastConnectedServerId")
        private val SESSION_NAMING_THEME = stringPreferencesKey("sessionNamingTheme")
        private val TERMINAL_FONT_SIZE = doublePreferencesKey("terminalFontSize")
        private val TERMINAL_SCROLLBACK_LINES = intPreferencesKey("terminalScrollbackLines")
        private val RECORDING_SHORTCUT_ENABLED = booleanPreferencesKey("recordingShortcutEnabled")
        private val RECORDING_SHORTCUT_FLAGS = intPreferencesKey("recordingShortcutFlags")
        private val RECORDING_SHORTCUT_KEY = stringPreferencesKey("recordingShortcutKey")
        private val SHARE_SCREEN_WITH_OPTIMIZER = booleanPreferencesKey("shareScreenWithOptimizer")

        // Legacy key read by the shortcut migration only (never written on Android today).
        private val LEGACY_SHORTCUT_MODIFIER_KEY =
            stringPreferencesKey(AppSettingsMigrations.LEGACY_SHORTCUT_MODIFIER_KEY)

        /**
         * Builds the production [AppSettings] from a [Context] + a long-lived
         * [scope]. The DataStore is the single process-wide `app_settings` instance.
         */
        fun create(context: Context, scope: CoroutineScope): AppSettings {
            val app = context.applicationContext
            return AppSettings(
                dataStore = app.appSettingsDataStore,
                // Constructed *inside* the lambda on purpose: `TokenStore`'s
                // constructor runs `EncryptedSharedPreferences.create` (MasterKey
                // unwrap + a synchronous prefs read), and `create` is called from
                // `MainActivity.onCreate` on the main thread. The lambda runs inside
                // `removeSpeechSettings`' `withContext(Dispatchers.IO)` hop, so the
                // expensive half moves off main too — the delete is now this class's
                // only use of the store.
                secretDeleter = BedrockSecretDeleter { TokenStore(app).deleteBedrockToken() },
                scope = scope,
            )
        }
    }
}

/** Single process-wide DataStore instance backing [AppSettings]. */
private val Context.appSettingsDataStore: DataStore<Preferences> by
    preferencesDataStore(name = "app_settings")
