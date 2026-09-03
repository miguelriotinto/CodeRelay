package relay.feature.workspace

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember

/**
 * Desktop no-op haptics.
 *
 * Same API as the Android `HapticController` so the shared `WorkspaceScreen`,
 * `SessionSidebar` and `SessionTabs` call it unchanged. A desktop has no haptic
 * hardware, so every method does nothing — this is the correct behaviour, not an
 * unimplemented stub.
 *
 * `AppSettings.hapticFeedbackEnabled` is still persisted for parity with the
 * other clients; it simply has nothing to drive here.
 */
class HapticController internal constructor(@Suppress("UNUSED_PARAMETER") private val enabled: Boolean) {
    fun lightTap() = Unit
    fun mediumTap() = Unit
    fun success() = Unit
    fun warning() = Unit
}

@Composable
fun rememberHaptics(enabled: Boolean): HapticController =
    remember(enabled) { HapticController(enabled) }
