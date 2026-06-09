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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import relay.protocol.SessionNamingTheme
import relay.storage.TokenStore

/**
 * App-wide user settings, ported from `AppSettings.swift`.
 *
 * iOS persists these via SwiftUI `@AppStorage` (UserDefaults). The Android analog
 * is a single Preferences [DataStore] (`app_settings`) holding **exactly the 14
 * keys** the iOS `AppSettings` exposes (AppSettings.swift:112-145), each surfaced
 * here as a [StateFlow] plus a `set…` mutator. The 15th persisted preference, the
 * Bedrock bearer token, is the same exception iOS makes: it lives in the secure
 * [TokenStore] (Android's Keychain analog — EncryptedSharedPreferences), **not**
 * DataStore, and its write is debounced (see [bedrockBearerToken]).
 *
 * `turnEndSilenceTimeout` is intentionally NOT a setting (it defaults from
 * `SpeechProcessingOptions`), matching iOS.
 *
 * ## The 14 DataStore keys (defaults from AppSettings.swift:112-145)
 *  1. `smartCleanupEnabled`        = true
 *  2. `promptEnhancementEnabled`   = false
 *  3. `bedrockRegion`              = "us-east-1"
 *  4. `hapticFeedbackEnabled`      = true
 *  5. `autoConnectEnabled`         = false
 *  6. `lastConnectedServerId`      = ""
 *  7. `sessionNamingTheme`         = gameOfThrones
 *  8. `terminalFontSize`           = 12.0
 *  9. `terminalScrollbackLines`    = 5000
 * 10. `recordingShortcutEnabled`   = true
 * 11. `recordingShortcutFlags`     = Meta+Alt ([ShortcutFlags.DEFAULT])
 * 12. `recordingShortcutKey`       = ""
 * 13. `continuousListeningEnabled` = false
 * 14. `wakeWord`                   = "claude"
 * (+ `bedrockBearerToken` in [TokenStore], not counted above.)
 *
 * @param scope a long-lived scope (the host injects an application-scoped one);
 *   owns the StateFlow hot mirrors and the debounced Bedrock write.
 */
@OptIn(FlowPreview::class)
class AppSettings(
    private val dataStore: DataStore<Preferences>,
    private val tokenStore: TokenStore,
    private val scope: CoroutineScope,
) {

    // MARK: - Startup: migrations → seed → install debounced Bedrock write

    init {
        // One ordered startup coroutine: run the migrations, seed the Bedrock
        // mirror, THEN install the debounced write collector. Sequencing the seed
        // before the collector is what gives us the iOS `dropFirst()` semantic —
        // the seed value (read FROM the secure store) is in place before any
        // emission can be observed, so it is never written back; only genuine
        // post-seed user edits persist. See [bedrockBearerToken].
        scope.launch {
            runMigrations()
            installDebouncedBedrockWrite()
        }
    }

    /**
     * Best-effort forward migrations, ported from `AppSettings.init`
     * (AppSettings.swift:12-13). On a fresh Android install both are no-ops (no
     * legacy data was ever written); see [AppSettingsMigrations] for the rationale.
     */
    private suspend fun runMigrations() {
        migrateShortcutIfNeeded()
        migrateBedrockTokenIfNeeded()
        // Seed the Bedrock token mirror from the secure store (with legacy
        // fallback), matching AppSettings.swift:16.
        _bedrockBearerToken.value = AppSettingsMigrations.loadBedrockTokenWithFallback(
            secure = tokenStore.loadBedrockToken(),
            legacy = readLegacyBedrock(),
        )
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
     * Migrate a legacy plaintext Bedrock token (if one was ever stored in DataStore)
     * into the secure [TokenStore], with the read-back-confirm-before-delete dance
     * + plaintext fallback. Mirrors `AppSettings.migrateBedrockToken`
     * (AppSettings.swift:77-98) — the pure decision lives in
     * [AppSettingsMigrations.decideBedrockMigration].
     */
    private suspend fun migrateBedrockTokenIfNeeded() {
        val legacy = readLegacyBedrock()
        when (val decision = AppSettingsMigrations.decideBedrockMigration(
            legacy = legacy,
            secureExisting = tokenStore.loadBedrockToken(),
        )) {
            AppSettingsMigrations.BedrockMigrationDecision.NoOp -> Unit
            AppSettingsMigrations.BedrockMigrationDecision.DeleteLegacyOnly ->
                dataStore.edit { it.remove(LEGACY_BEDROCK_KEY) }
            is AppSettingsMigrations.BedrockMigrationDecision.WriteThenConfirm -> {
                runCatching { tokenStore.saveBedrockToken(decision.token) }
                    .onSuccess {
                        val reread = tokenStore.loadBedrockToken()
                        if (AppSettingsMigrations.shouldScrubLegacyAfterWrite(decision.token, reread)) {
                            dataStore.edit { it.remove(LEGACY_BEDROCK_KEY) }
                        }
                    }
                // On a write failure, keep the legacy copy in place — the fallback
                // reader picks it up (AppSettings.swift:95-96).
            }
        }
    }

    private suspend fun readLegacyBedrock(): String? = dataStore.data.first()[LEGACY_BEDROCK_KEY]

    // MARK: - StateFlow mirrors + setters (the 14 keys)

    val smartCleanupEnabled: StateFlow<Boolean> = boolFlow(SMART_CLEANUP, true)
    fun setSmartCleanupEnabled(value: Boolean) = put(SMART_CLEANUP, value)

    val promptEnhancementEnabled: StateFlow<Boolean> = boolFlow(PROMPT_ENHANCEMENT, false)
    fun setPromptEnhancementEnabled(value: Boolean) = put(PROMPT_ENHANCEMENT, value)

    val bedrockRegion: StateFlow<String> = stringFlow(BEDROCK_REGION, "us-east-1")
    fun setBedrockRegion(value: String) = put(BEDROCK_REGION, value)

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

    val continuousListeningEnabled: StateFlow<Boolean> = boolFlow(CONTINUOUS_LISTENING, false)
    fun setContinuousListeningEnabled(value: Boolean) = put(CONTINUOUS_LISTENING, value)

    val wakeWord: StateFlow<String> = stringFlow(WAKE_WORD, "claude")
    fun setWakeWord(value: String) = put(WAKE_WORD, value)

    // MARK: - Bedrock bearer token (secure store, debounced write)

    private val _bedrockBearerToken = MutableStateFlow("")

    /**
     * Bedrock bearer token, persisted in the secure [TokenStore] (Android's
     * Keychain analog) — NOT DataStore. Mirrors `AppSettings.bedrockBearerToken`
     * (AppSettings.swift:121): the in-memory mirror is seeded from the secure store
     * at init; writes are **debounced 500 ms** so rapid typing in the masked field
     * collapses into a single secure write.
     */
    val bedrockBearerToken: StateFlow<String> = _bedrockBearerToken.asStateFlow()

    /** Updates the in-memory token mirror; the secure-store write fires debounced. */
    fun setBedrockBearerToken(value: String) {
        _bedrockBearerToken.value = value
    }

    /**
     * Installs the debounced secure-store write, called from the startup coroutine
     * AFTER the seed is in place. `.drop(1)` then discards the replayed current
     * (seed) value, so only post-seed user edits fire a write — the
     * `$bedrockBearerToken.dropFirst().debounce(500ms)` semantic from
     * AppSettings.swift:18-24. The 500 ms debounce collapses rapid typing in the
     * masked field into one write.
     */
    private fun installDebouncedBedrockWrite() {
        _bedrockBearerToken
            .drop(1)
            .debounce(BEDROCK_DEBOUNCE_MS)
            .onEach { token -> runCatching { tokenStore.saveBedrockToken(token) } }
            .launchIn(scope)
    }

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
        /** Bedrock-token write debounce, ms. Mirrors `AppSettings.bedrockDebounce` (500 ms). */
        const val BEDROCK_DEBOUNCE_MS = 500L

        // The 14 DataStore keys (names match the iOS @AppStorage keys verbatim so
        // a cross-platform import round-trips).
        private val SMART_CLEANUP = booleanPreferencesKey("smartCleanupEnabled")
        private val PROMPT_ENHANCEMENT = booleanPreferencesKey("promptEnhancementEnabled")
        private val BEDROCK_REGION = stringPreferencesKey("bedrockRegion")
        private val HAPTIC_FEEDBACK = booleanPreferencesKey("hapticFeedbackEnabled")
        private val AUTO_CONNECT = booleanPreferencesKey("autoConnectEnabled")
        private val LAST_CONNECTED_SERVER_ID = stringPreferencesKey("lastConnectedServerId")
        private val SESSION_NAMING_THEME = stringPreferencesKey("sessionNamingTheme")
        private val TERMINAL_FONT_SIZE = doublePreferencesKey("terminalFontSize")
        private val TERMINAL_SCROLLBACK_LINES = intPreferencesKey("terminalScrollbackLines")
        private val RECORDING_SHORTCUT_ENABLED = booleanPreferencesKey("recordingShortcutEnabled")
        private val RECORDING_SHORTCUT_FLAGS = intPreferencesKey("recordingShortcutFlags")
        private val RECORDING_SHORTCUT_KEY = stringPreferencesKey("recordingShortcutKey")
        private val CONTINUOUS_LISTENING = booleanPreferencesKey("continuousListeningEnabled")
        private val WAKE_WORD = stringPreferencesKey("wakeWord")

        // Legacy keys read by the migrations only (never written on Android today).
        private val LEGACY_SHORTCUT_MODIFIER_KEY =
            stringPreferencesKey(AppSettingsMigrations.LEGACY_SHORTCUT_MODIFIER_KEY)
        private val LEGACY_BEDROCK_KEY = stringPreferencesKey("bedrockBearerToken")

        /**
         * Builds the production [AppSettings] from a [Context] + a long-lived
         * [scope]. The DataStore is the single process-wide `app_settings` instance.
         */
        fun create(context: Context, scope: CoroutineScope): AppSettings =
            AppSettings(
                dataStore = context.applicationContext.appSettingsDataStore,
                tokenStore = TokenStore(context.applicationContext),
                scope = scope,
            )
    }
}

/** Single process-wide DataStore instance backing [AppSettings]. */
private val Context.appSettingsDataStore: DataStore<Preferences> by
    preferencesDataStore(name = "app_settings")
