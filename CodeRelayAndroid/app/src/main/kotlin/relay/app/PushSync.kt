package relay.app

import android.content.Context
import relay.session.hub.PushSettings
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.suspendCancellableCoroutine
import relay.storage.DeviceIdentifier
import kotlin.coroutines.resume

/**
 * App-level glue that gathers this device's push inputs for the hub, which
 * registers them with every relay through each coordinator's pure
 * `syncPushRegistration`. Gathers the
 * Android-specific inputs (token from Firebase / [FcmTokenBridge], POST_NOTIFICATIONS
 * grant, deviceId) here so the coordinator stays pure-JVM. Mirrors the iOS
 * WorkspaceView → coordinator.syncPushRegistration call.
 */
object PushSync {

    /** True when POST_NOTIFICATIONS is granted (always true below API 33). */
    fun notificationsGranted(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            context, android.Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * The push inputs for the hub: the FCM token (fetched once if the bridge is
     * empty), the POST_NOTIFICATIONS grant and the device id. The hub fans them
     * out to every relay and remembers them for servers enabled later.
     */
    suspend fun settings(context: Context): PushSettings {
        if (FcmTokenBridge.deviceToken.value == null) {
            fetchToken()?.let { FcmTokenBridge.setToken(it) }
        }
        val granted = notificationsGranted(context)
        FcmTokenBridge.setPermissionGranted(granted)
        return PushSettings(
            deviceToken = FcmTokenBridge.deviceToken.value,
            permissionGranted = granted,
            deviceId = DeviceIdentifier.get(context),
            pushEnabled = true,
            notifyOnFinished = false,
        )
    }

    /** Fetch the current FCM token, bridging the Play-services Task to suspend
     *  without pulling in coroutines-play-services. Returns null on failure. */
    private suspend fun fetchToken(): String? =
        suspendCancellableCoroutine { cont ->
            FirebaseMessaging.getInstance().token
                .addOnSuccessListener { token -> cont.resume(token) }
                .addOnFailureListener { cont.resume(null) }
                .addOnCanceledListener { cont.resume(null) }
        }
}
