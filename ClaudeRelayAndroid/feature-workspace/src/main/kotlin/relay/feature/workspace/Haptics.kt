package relay.feature.workspace

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalView

/**
 * Shared haptic-feedback helper, ported from the iOS `UIFeedbackGenerator` call
 * sites that are gated on `AppSettings.hapticFeedbackEnabled`.
 *
 * ## Why a custom helper instead of Compose's `LocalHapticFeedback`
 * Compose's `HapticFeedback` only exposes two constants in the pinned Compose BOM
 * (`LongPress` / `TextHandleMove`) — not enough to distinguish iOS's *impact*
 * styles (light/medium) from its *notification* styles (success/warning). The
 * platform `View.performHapticFeedback(HapticFeedbackConstants.*)` API gives the
 * full palette (incl. `CONFIRM` / `REJECT` on API 30+) so each iOS style maps to
 * a distinct Android constant. This helper wraps that one root [View].
 *
 * ## iOS → Android style mapping
 * | iOS `UIFeedbackGenerator`                          | Android `HapticFeedbackConstants`            |
 * |----------------------------------------------------|----------------------------------------------|
 * | `UIImpactFeedbackGenerator(.light)` → [lightTap]   | `KEYBOARD_TAP` (a crisp, light key tick)     |
 * | `UIImpactFeedbackGenerator(.medium)` → [mediumTap] | `VIRTUAL_KEY` (a firmer, medium tick)        |
 * | `UINotificationFeedbackGenerator(.success)` → [success] | `CONFIRM` (API 30+) → `VIRTUAL_KEY` fallback |
 * | `UINotificationFeedbackGenerator(.warning)` → [warning] | `REJECT` (API 30+) → `LONG_PRESS` fallback  |
 *
 * ## minSdk 28 safety
 * `CONFIRM` and `REJECT` are `HapticFeedbackConstants` added in **API 30**
 * (`Build.VERSION_CODES.R`). minSdk here is **28**, so [success] / [warning]
 * branch on [Build.VERSION.SDK_INT] and fall back to the always-available
 * `VIRTUAL_KEY` / `LONG_PRESS` constants below API 30.
 *
 * ## Gating
 * EVERY method is a no-op when the controller was created with `enabled = false`
 * (the `AppSettings.hapticFeedbackEnabled` flow). The gating decision is the pure,
 * testable [shouldFireHaptic]; the actual buzz is device-deferred (no emulator
 * vibrator in CI), so the controller's *wiring* is what's verified offline.
 */
class HapticController internal constructor(
    private val view: View?,
    private val enabled: Boolean,
) {
    /** iOS `UIImpactFeedbackGenerator(style: .light)` — special-key / toggle taps. */
    fun lightTap() = perform { HapticFeedbackConstants.KEYBOARD_TAP }

    /** iOS `UIImpactFeedbackGenerator(style: .medium)` — mic record start/stop. */
    fun mediumTap() = perform { HapticFeedbackConstants.VIRTUAL_KEY }

    /** iOS `UINotificationFeedbackGenerator().notificationOccurred(.success)`. */
    fun success() = perform {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) HapticFeedbackConstants.CONFIRM
        else HapticFeedbackConstants.VIRTUAL_KEY
    }

    /** iOS `UINotificationFeedbackGenerator().notificationOccurred(.warning)`. */
    fun warning() = perform {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) HapticFeedbackConstants.REJECT
        else HapticFeedbackConstants.LONG_PRESS
    }

    // The constant is resolved lazily INSIDE the gate so a disabled controller
    // touches no Android SDK API at all (the `Build` SDK-version check + the
    // constant lookup only run once the gate + non-null view both pass). This is
    // what lets the gating unit tests run on the bare JVM with no device stubs.
    private inline fun perform(constant: () -> Int) {
        if (!shouldFireHaptic(enabled)) return
        val v = view ?: return
        // Ignore the system's "haptics off in settings" view flag: the user has
        // explicitly opted in via the app's hapticFeedbackEnabled toggle, mirroring
        // iOS firing the generator unconditionally once the setting is on.
        v.performHapticFeedback(constant(), HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING)
    }
}

/**
 * Pure gating predicate — the testable seam. Mirrors the iOS guard
 * `if settings.hapticFeedbackEnabled { generator… }`: a haptic only fires when the
 * setting is on. Extracted so the gating logic is unit-tested without a device
 * vibrator (the actual buzz is device-deferred).
 */
fun shouldFireHaptic(enabled: Boolean): Boolean = enabled

/**
 * Remembers a [HapticController] bound to the current root [LocalView], gated on
 * [enabled] (the collected `AppSettings.hapticFeedbackEnabled` value). When the
 * setting is off the returned controller's methods are no-ops.
 */
@Composable
fun rememberHaptics(enabled: Boolean): HapticController {
    val view = LocalView.current
    return remember(view, enabled) { HapticController(view, enabled) }
}
