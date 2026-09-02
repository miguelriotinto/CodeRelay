package relay.feature.settings

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import relay.protocol.SessionNamingTheme
import relay.storage.TokenStore

/**
 * The 14 persisted app preferences plus the Bedrock bearer token.
 *
 * Linux counterpart of the Android `AppSettings`. **The public API is identical
 * on purpose** — the same `StateFlow` properties and `setX` methods — so the
 * shared `SettingsScreen.kt` (471 lines, whose only non-portable import is
 * `androidx.lifecycle.compose.collectAsStateWithLifecycle`, which Compose
 * Multiplatform provides under the same package name) compiles against this
 * unchanged.
 *
 * ### Why there are no migrations here
 *
 * The Android class runs two forward migrations at startup: a legacy
 * `recordingShortcutModifier` String → flags Int, and a legacy plaintext
 * Bedrock token → the secure store. Both exist because *older builds of that
 * app* wrote those keys.
 *
 * Linux is a brand-new platform. No CodeRelay build has ever written a
 * preference on this machine, so there is no legacy data to migrate — by
 * construction, not by assumption. Porting the migration machinery would be
 * dead code that still has to be maintained and can still go wrong.
 * `AppSettingsMigrations` is therefore not compiled into this module.
 *
 * (If settings import from another device is ever added, the migrations become
 * relevant again — and the shared `AppSettingsMigrations` is pure Kotlin, so it
 * can be pulled in at that point without a rewrite.)
 *
 * ### The Bedrock token
 *
 * Not a preference: it is a credential, so it lives in [TokenStore] (the desktop
 * keyring), never in `settings.json`. The debounce-and-drop-first pattern is
 * ported exactly — see [bedrockBearerToken].
 */
@OptIn(FlowPreview::class)
class AppSettings(
    private val prefs: PreferenceStore,
    private val tokenStore: TokenStore,
    private val scope: CoroutineScope,
) {

    // ---- the 14 persisted preferences ----

    val smartCleanupEnabled: StateFlow<Boolean> = prefs.boolFlow(SMART_CLEANUP, true)
    fun setSmartCleanupEnabled(value: Boolean) = prefs.put(SMART_CLEANUP, value)

    val promptEnhancementEnabled: StateFlow<Boolean> = prefs.boolFlow(PROMPT_ENHANCEMENT, false)
    fun setPromptEnhancementEnabled(value: Boolean) = prefs.put(PROMPT_ENHANCEMENT, value)

    val bedrockRegion: StateFlow<String> = prefs.stringFlow(BEDROCK_REGION, "us-east-1")
    fun setBedrockRegion(value: String) = prefs.put(BEDROCK_REGION, value)

    /**
     * Retained for API parity with Android so the shared settings screen
     * compiles. There is no haptic hardware on a desktop, so the value is
     * persisted and simply never consulted.
     */
    val hapticFeedbackEnabled: StateFlow<Boolean> = prefs.boolFlow(HAPTIC_FEEDBACK, true)
    fun setHapticFeedbackEnabled(value: Boolean) = prefs.put(HAPTIC_FEEDBACK, value)

    val autoConnectEnabled: StateFlow<Boolean> = prefs.boolFlow(AUTO_CONNECT, false)
    fun setAutoConnectEnabled(value: Boolean) = prefs.put(AUTO_CONNECT, value)

    val lastConnectedServerId: StateFlow<String> = prefs.stringFlow(LAST_CONNECTED_SERVER_ID, "")
    fun setLastConnectedServerId(value: String) = prefs.put(LAST_CONNECTED_SERVER_ID, value)

    val sessionNamingTheme: StateFlow<SessionNamingTheme> =
        prefs.mapped(SESSION_NAMING_THEME) { SessionNamingTheme.fromRaw(it ?: "") }
    fun setSessionNamingTheme(value: SessionNamingTheme) =
        prefs.put(SESSION_NAMING_THEME, value.rawValue)

    val terminalFontSize: StateFlow<Double> = prefs.doubleFlow(TERMINAL_FONT_SIZE, 12.0)
    fun setTerminalFontSize(value: Double) = prefs.put(TERMINAL_FONT_SIZE, value)

    val terminalScrollbackLines: StateFlow<Int> = prefs.intFlow(TERMINAL_SCROLLBACK_LINES, 5_000)
    fun setTerminalScrollbackLines(value: Int) = prefs.put(TERMINAL_SCROLLBACK_LINES, value)

    val recordingShortcutEnabled: StateFlow<Boolean> = prefs.boolFlow(RECORDING_SHORTCUT_ENABLED, true)
    fun setRecordingShortcutEnabled(value: Boolean) = prefs.put(RECORDING_SHORTCUT_ENABLED, value)

    val recordingShortcutFlags: StateFlow<Int> = prefs.intFlow(RECORDING_SHORTCUT_FLAGS, ShortcutFlags.DEFAULT)
    fun setRecordingShortcutFlags(value: Int) = prefs.put(RECORDING_SHORTCUT_FLAGS, value)

    val recordingShortcutKey: StateFlow<String> = prefs.stringFlow(RECORDING_SHORTCUT_KEY, "")
    fun setRecordingShortcutKey(value: String) = prefs.put(RECORDING_SHORTCUT_KEY, value)

    val continuousListeningEnabled: StateFlow<Boolean> = prefs.boolFlow(CONTINUOUS_LISTENING, false)
    fun setContinuousListeningEnabled(value: Boolean) = prefs.put(CONTINUOUS_LISTENING, value)

    val wakeWord: StateFlow<String> = prefs.stringFlow(WAKE_WORD, "claude")
    fun setWakeWord(value: String) = prefs.put(WAKE_WORD, value)

    // ---- the Bedrock credential (keyring, not settings.json) ----

    private val _bedrockBearerToken = MutableStateFlow("")
    val bedrockBearerToken: StateFlow<String> = _bedrockBearerToken.asStateFlow()

    fun setBedrockBearerToken(value: String) {
        _bedrockBearerToken.value = value
    }

    init {
        // Declared LAST on purpose. Kotlin executes init blocks and property
        // initialisers in DECLARATION order, so an init block placed above
        // `_bedrockBearerToken` hands this coroutine a field that is still
        // null — and because the launch lands on a background dispatcher it
        // can win that race. Observed at runtime as:
        //   Exception in thread "DefaultDispatcher-worker-1"
        //   NullPointerException: Cannot invoke MutableStateFlow.setValue(...)
        // Keeping it here guarantees every property is constructed before the
        // coroutine can observe one.
        scope.launch {
            // Seed from the keyring BEFORE installing the write collector, so
            // the seeded value is never written back — the `dropFirst()`
            // semantic the iOS and Android versions both rely on.
            _bedrockBearerToken.value = runCatching { tokenStore.loadBedrockToken() }.getOrNull().orEmpty()
            installDebouncedBedrockWrite()
        }
    }

    /**
     * Persists edits to the keyring, debounced 500 ms and dropping the seeded
     * value.
     *
     * Both halves matter. **Debounce**: the settings field emits per keystroke,
     * and each write is a D-Bus round trip to the keyring — writing per
     * character would stall the UI and spam the daemon. **Drop the first**: the
     * initial emission is the value we just seeded *from* the keyring, so
     * writing it back is pointless and, on a locked keyring, produces a
     * spurious failure at startup.
     */
    private suspend fun installDebouncedBedrockWrite() {
        _bedrockBearerToken
            .drop(1)
            .debounce(BEDROCK_WRITE_DEBOUNCE_MS)
            .collect { token ->
                runCatching { tokenStore.saveBedrockToken(token) }
            }
    }

    companion object {
        private const val BEDROCK_WRITE_DEBOUNCE_MS = 500L

        // Key names match the Android store's exactly, so a settings file moved
        // between platforms is intelligible and a future import path is trivial.
        const val SMART_CLEANUP = "smartCleanupEnabled"
        const val PROMPT_ENHANCEMENT = "promptEnhancementEnabled"
        const val BEDROCK_REGION = "bedrockRegion"
        const val HAPTIC_FEEDBACK = "hapticFeedbackEnabled"
        const val AUTO_CONNECT = "autoConnectEnabled"
        const val LAST_CONNECTED_SERVER_ID = "lastConnectedServerId"
        const val SESSION_NAMING_THEME = "sessionNamingTheme"
        const val TERMINAL_FONT_SIZE = "terminalFontSize"
        const val TERMINAL_SCROLLBACK_LINES = "terminalScrollbackLines"
        const val RECORDING_SHORTCUT_ENABLED = "recordingShortcutEnabled"
        const val RECORDING_SHORTCUT_FLAGS = "recordingShortcutFlags"
        const val RECORDING_SHORTCUT_KEY = "recordingShortcutKey"
        const val CONTINUOUS_LISTENING = "continuousListeningEnabled"
        const val WAKE_WORD = "wakeWord"
    }
}
