package relay.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Receives FCM pushes (F1 Android push). Two jobs:
 *
 *  1. `onNewToken` — publish the new registration token to [FcmTokenBridge] and
 *     trigger a (re)register so the server sends to the current token.
 *  2. `onMessageReceived` — display a notification whose tap fires the
 *     `clauderelay://session/<uuid>` deep link (parsed by [MainActivity]).
 *
 * The server (PushDispatcher → FCMClient) sends `notification.{title,body}` plus
 * `data.deepLink`. A message carrying a `notification` block is auto-displayed by
 * the system only when the app is backgrounded; to attach our deep-link tap
 * intent (and to show it in the foreground) we build the notification ourselves
 * from whichever fields are present.
 */
class RelayFirebaseMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        FcmTokenBridge.setToken(token)
        // Ask the app to (re)register with the server if it's connected.
        FcmTokenBridge.onTokenRefreshed?.invoke()
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val notification = message.notification
        val title = notification?.title ?: message.data["title"] ?: "CodeRelay"
        val body = notification?.body ?: message.data["body"] ?: ""
        val deepLink = message.data["deepLink"]

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannel(manager)

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)

        // Tap → launch MainActivity with the deep-link URI so it routes to the
        // session (MainActivity.handleDeepLink already parses clauderelay://).
        if (deepLink != null) {
            val intent = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                data = Uri.parse(deepLink)
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            builder.setContentIntent(
                PendingIntent.getActivity(this, deepLink.hashCode(), intent, flags)
            )
        }

        // Collapse per workspace-group: the server coalesces on a hashed
        // collapse id; reuse it as the notification tag so repeated pushes for
        // the same group replace rather than stack.
        val tag = message.collapseKey ?: message.messageId
        manager.notify(tag, NOTIFICATION_ID, builder.build())
    }

    private fun ensureChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "Agent activity",
                        NotificationManager.IMPORTANCE_HIGH,
                    ).apply {
                        description = "Alerts when a coding agent needs input or finishes."
                    }
                )
            }
        }
    }

    companion object {
        const val CHANNEL_ID = "agent_activity"
        private const val NOTIFICATION_ID = 42
    }
}
