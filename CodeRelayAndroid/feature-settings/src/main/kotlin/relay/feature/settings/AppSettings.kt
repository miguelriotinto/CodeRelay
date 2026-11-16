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
 * is a single Preferences [DataStore] (`app_settings`) holding **the 6 keys this
 * client persists** — a subset of iOS's, which additionally carries the two
 * push prefs (`pushNotificationsEnabled`, `pushNotifyOnFinished`; Android hardcodes
 * those in `PushSync`). Key *names* match iOS verbatim. Each is surfaced here as a
 * [StateFlow] plus a `set…` mutator.
 *
 * ## The 6 DataStore keys (defaults match AppSettings.swift)
 *  1. `hapticFeedbackEnabled`      = true
 *  2. `autoConnectEnabled`         = false
 *  3. `lastConnectedServerId`      = ""
 *  4. `sessionNamingTheme`         = gameOfThrones
 *  5. `terminalFontSize`           = 12.0
 *  6. `terminalScrollbackLines`    = 5000
 *
 * The speech stack's six keys (`smartCleanupEnabled`, `promptEnhancementEnabled`,
 * `bedrockRegion`, `continuousListeningEnabled`, `wakeWord`, and the legacy
 * plaintext `bedrockBearerToken`) plus the Bedrock credential in the secure
 * [TokenStore] are **scrubbed on every launch** by [removeSpeechSettings]
 * (spec §10) — every shipped build before the speech removal wrote them. The
 * prompt optimizer's keys (`shareScreenWithOptimizer` and the
 * `recordingShortcut*` keys) are scrubbed the same way by [removeOptimizerSettings].
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
     * Removed-feature scrubs, in launch order: the speech scrub first (it owns the
     * Bedrock secret), then the prompt-optimizer one.
     *
     * The order and the guards are both load-bearing. `app_settings` is created with
     * no `corruptionHandler`, so a malformed file makes **every** DataStore read
     * throw for the life of the install. The secret delete must therefore come
     * first and never wait on DataStore health, and every DataStore step is guarded
     * so the exception cannot escape this `scope.launch` into the default uncaught
     * handler and kill the process during `MainActivity.onCreate`.
     */
    private suspend fun runMigrations() {
        removeSpeechSettings()
        removeOptimizerSettings()
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

    /**
     * Prompt-optimizer-removal scrub, the sibling of [removeSpeechSettings]. Runs
     * every launch for the same reasons: idempotent, cheap, and no "done" flag that
     * could be set before the deletion landed. The read is guarded like the speech
     * scrub's, so an unreadable DataStore cannot escape.
     */
    private suspend fun removeOptimizerSettings() {
        runCatching {
            val prefs = dataStore.data.first()
            if (AppSettingsMigrations.REMOVED_OPTIMIZER_KEYS.any { prefs.contains(it) }) {
                dataStore.edit { AppSettingsMigrations.scrubOptimizerKeys(it) }
            }
        }.onFailure { if (it is CancellationException) throw it }
    }

    // MARK: - StateFlow mirrors + setters (the 6 keys)

    val hapticFeedbackEnabled: StateFlow<Boolean> = boolFlow(HAPTIC_FEEDBACK, true)
    fun setHapticFeedbackEnabled(value: Boolean) = put(HAPTIC_FEEDBACK, value)

    val autoConnectEnabled: StateFlow<Boolean> = boolFlow(AUTO_CONNECT, false)
    fun setAutoConnectEnabled(value: Boolean) = put(AUTO_CONNECT, value)

    val lastConnectedServerId: StateFlow<String> = stringFlow(LAST_CONNECTED_SERVER_ID, "")
    fun setLastConnectedServerId(value: String) = put(LAST_CONNECTED_SERVER_ID, value)

    /**
     * The persisted value, awaited from disk. At cold start the StateFlow's
     * `.value` is still the seed default because the DataStore read is async —
     * the one-time multi-server migration must decide against the real value.
     */
    suspend fun lastConnectedServerIdNow(): String =
        dataStore.data.first()[LAST_CONNECTED_SERVER_ID] ?: ""

    /** Stored as the [SessionNamingTheme.rawValue]; resolves via `fromRaw` (falls back to DEFAULT). */
    val sessionNamingTheme: StateFlow<SessionNamingTheme> =
        dataStore.data
            .map { SessionNamingTheme.fromRaw(it[SESSION_NAMING_THEME] ?: SessionNamingTheme.DEFAULT.rawValue) }
            .stateIn(scope, SharingStarted.Eagerly, SessionNamingTheme.DEFAULT)
    fun setSessionNamingTheme(value: SessionNamingTheme) = put(SESSION_NAMING_THEME, value.rawValue)

    /** The persisted theme, awaited from disk (the StateFlow seeds DEFAULT until the async read lands). */
    suspend fun sessionNamingThemeNow(): SessionNamingTheme =
        SessionNamingTheme.fromRaw(dataStore.data.first()[SESSION_NAMING_THEME] ?: SessionNamingTheme.DEFAULT.rawValue)

    val terminalFontSize: StateFlow<Double> = doubleFlow(TERMINAL_FONT_SIZE, 12.0)
    fun setTerminalFontSize(value: Double) = put(TERMINAL_FONT_SIZE, value)

    val terminalScrollbackLines: StateFlow<Int> = intFlow(TERMINAL_SCROLLBACK_LINES, 5_000)
    fun setTerminalScrollbackLines(value: Int) = put(TERMINAL_SCROLLBACK_LINES, value)

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
        // The 6 DataStore keys (names match the iOS @AppStorage keys verbatim so
        // a cross-platform import round-trips).
        private val HAPTIC_FEEDBACK = booleanPreferencesKey("hapticFeedbackEnabled")
        private val AUTO_CONNECT = booleanPreferencesKey("autoConnectEnabled")
        private val LAST_CONNECTED_SERVER_ID = stringPreferencesKey("lastConnectedServerId")
        private val SESSION_NAMING_THEME = stringPreferencesKey("sessionNamingTheme")
        private val TERMINAL_FONT_SIZE = doublePreferencesKey("terminalFontSize")
        private val TERMINAL_SCROLLBACK_LINES = intPreferencesKey("terminalScrollbackLines")

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
