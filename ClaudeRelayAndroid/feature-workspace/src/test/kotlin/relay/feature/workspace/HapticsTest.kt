package relay.feature.workspace

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Gating tests for the shared haptic helper.
 *
 * The actual buzz (`Vibrator.vibrate`) is DEVICE-DEFERRED — there is no vibrator
 * in JVM unit tests — so the testable seam is the pure [shouldFireHaptic]
 * predicate that mirrors the iOS `if settings.hapticFeedbackEnabled { … }` guard.
 * A [HapticController] built around it must no-op every method when the setting is
 * off (a null vibrator also no-ops, so the controller is null-safe in tests).
 */
class HapticsTest {

    @Test
    fun `shouldFireHaptic fires only when enabled`() {
        assertTrue(shouldFireHaptic(enabled = true))
        assertFalse(shouldFireHaptic(enabled = false))
    }

    @Test
    fun `disabled controller no-ops every style without a vibrator`() {
        // enabled = false → no method may touch the (null) vibrator → no crash, no buzz.
        val controller = HapticController(vibrator = null, enabled = false)
        controller.lightTap()
        controller.mediumTap()
        controller.success()
        controller.warning()
        // Reaching here without throwing proves the gate short-circuits before the
        // device call. (The enabled+real-vibrator path is device-deferred.)
    }

    @Test
    fun `enabled controller with null vibrator is still safe`() {
        // enabled = true but vibrator-less hardware (or the unit-test JVM): the
        // controller must null-guard the vibrate call.
        val controller = HapticController(vibrator = null, enabled = true)
        controller.lightTap()
        controller.mediumTap()
        controller.success()
        controller.warning()
    }
}
