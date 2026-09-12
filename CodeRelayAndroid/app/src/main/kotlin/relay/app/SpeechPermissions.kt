package relay.app

import android.Manifest
import android.os.Build

/**
 * Runtime-permission seam for the speech pipeline (M3 Task 10/11).
 *
 * The dangerous runtime permissions speech needs:
 *  - `RECORD_AUDIO` — mic capture (PTT + continuous).
 *  - `POST_NOTIFICATIONS` — only on API 33+ (Android 13), for the
 *    continuous-listening foreground-service notification.
 *
 * The actual request goes through an `ActivityResultContracts.RequestMultiplePermissions`
 * launcher registered in [MainActivity] (Compose `rememberLauncherForActivityResult`
 * cannot live in the device-deferred `:speech`/`:feature-workspace` layers without
 * dragging the Activity in). [SpeechSession] triggers the request via the
 * process-wide [requester] before the first mic interaction. **The runtime grant
 * itself is device-deferred** (no emulator) — this is the compile-verified wiring.
 */
object SpeechPermissions {

    /**
     * The permissions to request, API-gated. `POST_NOTIFICATIONS` is only a
     * runtime permission on API 33+; on older releases it is granted at install.
     */
    val required: Array<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS)
        } else {
            arrayOf(Manifest.permission.RECORD_AUDIO)
        }

    /**
     * Set by [MainActivity] to its ActivityResult launcher; invoked by
     * [SpeechSession] to request mic + notification permissions. No-op until the
     * activity wires it (e.g. during config-change recreation).
     */
    @Volatile
    var requester: (() -> Unit)? = null

    /** Triggers the runtime permission request, if a launcher is registered. */
    fun request() {
        requester?.invoke()
    }
}
