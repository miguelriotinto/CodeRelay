package relay.feature.workspace

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext

/**
 * Shared haptic-feedback helper, ported from the iOS `UIFeedbackGenerator` call
 * sites that are gated on `AppSettings.hapticFeedbackEnabled`.
 *
 * ## Why the `Vibrator` API instead of `View.performHapticFeedback`
 * `performHapticFeedback` is gated by the system-wide "Touch feedback" setting
 * (`Settings.System.HAPTIC_FEEDBACK_ENABLED`), and the flag that used to bypass
 * it (`FLAG_IGNORE_GLOBAL_SETTING`) is a no-op since Android 13. With Touch
 * feedback off — a common user setting — every call silently did nothing, while
 * IME keyboards (which use `Vibrator` directly) kept buzzing. Driving the
 * `Vibrator` service directly honors the app's own opt-in toggle regardless of
 * Touch feedback, which is the behavior the iOS app has: once
 * `hapticFeedbackEnabled` is on, the generator always fires. Only the master
 * "vibration off" / DND hardware switch can still suppress it.
 *
 * ## iOS → Android effect mapping
 * | iOS `UIFeedbackGenerator`                                | Android `VibrationEffect`                      |
 * |----------------------------------------------------------|------------------------------------------------|
 * | `UIImpactFeedbackGenerator(.light)` → [lightTap]         | `EFFECT_TICK` (API 29+) / 20 ms one-shot       |
 * | `UIImpactFeedbackGenerator(.medium)` → [mediumTap]       | `EFFECT_CLICK` (API 29+) / 40 ms one-shot      |
 * | `UINotificationFeedbackGenerator(.success)` → [success]  | double pulse waveform (30 ms × 2)              |
 * | `UINotificationFeedbackGenerator(.warning)` → [warning]  | heavier double pulse (50 ms + 70 ms)           |
 *
 * Predefined effects are vendor-tuned and crisper than raw one-shots, so they
 * are preferred where available (`createPredefined` is API 29+; minSdk is 28).
 * iOS notification haptics are double-pulses with no predefined Android
 * equivalent, hence the explicit waveforms (all-API-safe).
 *
 * ## Gating
 * EVERY method is a no-op when the controller was created with `enabled = false`
 * (the `AppSettings.hapticFeedbackEnabled` flow). The gating decision is the pure,
 * testable [shouldFireHaptic]; the actual buzz is device-deferred (no emulator
 * vibrator in CI), so the controller's *wiring* is what's verified offline.
 */
class HapticController internal constructor(
    private val vibrator: Vibrator?,
    private val enabled: Boolean,
) {
    /** iOS `UIImpactFeedbackGenerator(style: .light)` — special-key / toggle taps. */
    fun lightTap() = perform {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK)
        } else {
            VibrationEffect.createOneShot(20, VibrationEffect.DEFAULT_AMPLITUDE)
        }
    }

    /** iOS `UIImpactFeedbackGenerator(style: .medium)` — mic record start/stop. */
    fun mediumTap() = perform {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)
        } else {
            VibrationEffect.createOneShot(40, VibrationEffect.DEFAULT_AMPLITUDE)
        }
    }

    /** iOS `UINotificationFeedbackGenerator().notificationOccurred(.success)`. */
    fun success() = perform {
        VibrationEffect.createWaveform(longArrayOf(0, 30, 70, 30), -1)
    }

    /** iOS `UINotificationFeedbackGenerator().notificationOccurred(.warning)`. */
    fun warning() = perform {
        VibrationEffect.createWaveform(longArrayOf(0, 50, 80, 70), -1)
    }

    // The effect is built lazily INSIDE the gate so a disabled controller touches
    // no Android SDK API at all (the `Build` SDK-version check + the effect
    // construction only run once the gate + non-null vibrator both pass). This is
    // what lets the gating unit tests run on the bare JVM with no device stubs.
    private inline fun perform(effect: () -> VibrationEffect) {
        if (!shouldFireHaptic(enabled)) return
        val v = vibrator ?: return
        runCatching { v.vibrate(effect()) }
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
 * Resolves the device's default [Vibrator], branching on the API 31 rename to
 * [VibratorManager]. Returns null on vibrator-less hardware (the controller
 * null-guards, so callers never need to).
 */
fun defaultVibrator(context: Context): Vibrator? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        val manager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
        manager?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }

/**
 * Remembers a [HapticController] bound to the device's default [Vibrator], gated
 * on [enabled] (the collected `AppSettings.hapticFeedbackEnabled` value). When the
 * setting is off the returned controller's methods are no-ops.
 */
@Composable
fun rememberHaptics(enabled: Boolean): HapticController {
    val context = LocalContext.current
    return remember(context, enabled) { HapticController(defaultVibrator(context), enabled) }
}
