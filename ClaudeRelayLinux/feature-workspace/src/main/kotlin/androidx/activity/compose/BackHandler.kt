package androidx.activity.compose

import androidx.compose.runtime.Composable

/**
 * Desktop no-op stand-in for AndroidX's `BackHandler`.
 *
 * Declared in `androidx.activity.compose` on purpose: it lets the shared
 * `WorkspaceScreen.kt` — 816 lines of Compose that are otherwise entirely
 * portable — compile here **unchanged**, rather than being forked and then
 * drifting from the Android original. That file's single Android dependency is
 * one `BackHandler` call.
 *
 * A no-op is the semantically correct desktop behaviour, not a stub that skips
 * work. The one call site is:
 *
 * ```
 * BackHandler(enabled = true) { /* suppress back-dismiss during recovery */ }
 * ```
 *
 * It exists to *swallow* the Android system back gesture so a recovery overlay
 * cannot be dismissed mid-recovery. A desktop window has no system back
 * gesture, so there is nothing to swallow and nothing is lost. If a desktop
 * "back" affordance is ever added, this is the single place to implement it.
 *
 * Kept deliberately minimal — matching only the overload the shared source
 * calls — so it cannot accidentally satisfy some other AndroidX API and hide a
 * real portability problem.
 */
@Composable
@Suppress("UNUSED_PARAMETER")
fun BackHandler(enabled: Boolean = true, onBack: () -> Unit) {
    // Intentionally empty. See the KDoc: there is no system back gesture to
    // intercept on a desktop window.
}
