package relay.app

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Process-wide holder for the FCM device token and notification-permission
 * state — the Android analog of the iOS `PushTokenBridge`.
 *
 * `FirebaseMessagingService.onNewToken` and the runtime-permission result feed
 * this; the [relay.session.SessionCoordinator] reads it in its push-registration
 * sync. A `StateFlow` (not `LiveData`/Compose state) keeps it usable from the
 * pure background service and the coordinator alike.
 */
object FcmTokenBridge {
    private val _deviceToken = MutableStateFlow<String?>(null)
    val deviceToken: StateFlow<String?> = _deviceToken

    private val _permissionGranted = MutableStateFlow<Boolean?>(null)
    val permissionGranted: StateFlow<Boolean?> = _permissionGranted

    /** Called from FirebaseMessagingService.onNewToken and the initial fetch. */
    fun setToken(token: String) { _deviceToken.value = token }

    /** Called after the POST_NOTIFICATIONS runtime-permission result. */
    fun setPermissionGranted(granted: Boolean) { _permissionGranted.value = granted }

    /** Invoked when a fresh token arrives so the coordinator can (re)register. */
    var onTokenRefreshed: (() -> Unit)? = null
}
