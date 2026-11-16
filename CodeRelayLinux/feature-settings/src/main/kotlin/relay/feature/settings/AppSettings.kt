package relay.feature.settings

import kotlinx.coroutines.flow.StateFlow
import relay.protocol.SessionNamingTheme

/**
 * The 6 shared preferences, plus 2 desktop-only ones (window geometry).
 *
 * Linux counterpart of the Android `AppSettings`. **The public API is identical
 * on purpose** — the same `StateFlow` properties and `setX` methods — so the
 * shared `SettingsScreen.kt` (whose only non-portable import is
 * `androidx.lifecycle.compose.collectAsStateWithLifecycle`, which Compose
 * Multiplatform provides under the same package name) compiles against this
 * unchanged.
 *
 * ### Startup scrubs
 *
 * The Android class runs two startup scrubs of settings written by removed
 * features; both exist because *older builds of that app* wrote those keys.
 *
 * Older Linux builds (≤ v0.3.25) DID write the speech preferences:
 * `smartCleanupEnabled`, `promptEnhancementEnabled`, `bedrockRegion`,
 * `continuousListeningEnabled`, and `wakeWord`. Builds up to the prompt
 * optimizer's removal also wrote `shareScreenWithOptimizer` and the three
 * `recordingShortcut*` keys (Linux never wrote the legacy
 * `recordingShortcutModifier` String key). All of them are pruned at
 * construction, idempotent, with no completion flag — the same rule as
 * Android's `removeSpeechSettings` / `removeOptimizerSettings` and the keyring
 * scrub (`TokenStore.deleteBedrockToken()` at launch in `Main.kt`).
 */
class AppSettings(
    private val prefs: PreferenceStore,
) {

    init {
        // Prune preferences written by builds that still had the speech stack
        // (≤ v0.3.25) or the prompt optimizer.
        LEGACY_SPEECH_KEYS.forEach { if (prefs.contains(it)) prefs.remove(it) }
        REMOVED_OPTIMIZER_KEYS.forEach { if (prefs.contains(it)) prefs.remove(it) }
    }

    // ---- the 6 shared persisted preferences ----

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

    /**
     * Whether the user has chosen a terminal font size at all.
     *
     * Linux-only. The desktop terminal follows the size in the user's own
     * Foot/Alacritty config until a size is set here, so that "12 pt" default
     * must be distinguishable from "12 pt, chosen" — the former means "match
     * my other terminals", the latter means twelve points. Ctrl+Shift+0 clears
     * the choice via [clearTerminalFontSize] and the grid goes back to
     * following the desktop.
     */
    val terminalFontSizeIsSet: StateFlow<Boolean> = prefs.mapped(TERMINAL_FONT_SIZE) { it != null }
    fun clearTerminalFontSize() = prefs.remove(TERMINAL_FONT_SIZE)

    // ---- desktop-only: window geometry ----

    val windowWidth: StateFlow<Int> = prefs.intFlow(WINDOW_WIDTH, 1200)
    val windowHeight: StateFlow<Int> = prefs.intFlow(WINDOW_HEIGHT, 800)
    fun setWindowSize(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        if (width != windowWidth.value) prefs.put(WINDOW_WIDTH, width)
        if (height != windowHeight.value) prefs.put(WINDOW_HEIGHT, height)
    }

    val terminalScrollbackLines: StateFlow<Int> = prefs.intFlow(TERMINAL_SCROLLBACK_LINES, 5_000)
    fun setTerminalScrollbackLines(value: Int) = prefs.put(TERMINAL_SCROLLBACK_LINES, value)

    companion object {
        // Key names match the Android store's exactly, so a settings file moved
        // between platforms is intelligible and a future import path is trivial.
        const val HAPTIC_FEEDBACK = "hapticFeedbackEnabled"
        const val AUTO_CONNECT = "autoConnectEnabled"
        const val LAST_CONNECTED_SERVER_ID = "lastConnectedServerId"
        const val SESSION_NAMING_THEME = "sessionNamingTheme"
        const val TERMINAL_FONT_SIZE = "terminalFontSize"
        const val TERMINAL_SCROLLBACK_LINES = "terminalScrollbackLines"

        // Desktop-only keys; no Android counterpart.
        const val WINDOW_WIDTH = "windowWidth"
        const val WINDOW_HEIGHT = "windowHeight"

        /** Legacy speech preferences written by builds ≤ v0.3.25, pruned at construction. */
        private val LEGACY_SPEECH_KEYS = listOf(
            "smartCleanupEnabled",
            "promptEnhancementEnabled",
            "bedrockRegion",
            "continuousListeningEnabled",
            "wakeWord"
        )

        /** Prompt-optimizer preferences (share-screen gate, optimizer shortcut), pruned at construction. */
        private val REMOVED_OPTIMIZER_KEYS = listOf(
            "shareScreenWithOptimizer",
            "recordingShortcutEnabled",
            "recordingShortcutFlags",
            "recordingShortcutKey",
        )
    }
}
