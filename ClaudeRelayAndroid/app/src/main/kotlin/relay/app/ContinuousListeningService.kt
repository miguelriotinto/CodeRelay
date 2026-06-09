package relay.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import relay.speech.ContinuousListeningEngine
import relay.speech.SpeechProcessingOptions

/**
 * Android-required foreground service hosting the always-on
 * [ContinuousListeningEngine]. **This is a documented divergence from iOS**, which
 * has no foreground-service analog — iOS runs continuous listening foreground-only
 * tied to `scenePhase == .active` with no background-audio entitlement. Android
 * requires a `foregroundServiceType="microphone"` service + a persistent
 * notification to capture audio while the workspace is in the foreground (and to
 * survive brief UI lifecycle churn like rotation), so the engine lives here.
 *
 * ## Lifecycle (wired by the workspace host — runtime DEVICE-DEFERRED)
 *  - **Start** ([start]) when continuous mode is on AND the workspace is
 *    foregrounded: `startForegroundService` → [onStartCommand] promotes to
 *    foreground with the microphone type + notification → `engine.enable()`.
 *  - **Stop** ([stop]) on background / disable: `engine.disable()` →
 *    `stopForeground` → `stopSelf`.
 *
 * ## What's real vs deferred
 *  - **Real (compile-verified):** the service skeleton, the notification channel +
 *    foreground promotion with `ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE`,
 *    the engine construction via [ContinuousListeningEngine.makeDefault] on a
 *    service-scoped [CoroutineScope], and the `onUtteranceReady → onUtterance`
 *    delegate seam.
 *  - **Device-deferred (no emulator / no mic / no JNI):** actual microphone
 *    capture (`StreamingAudioSourcing` is wired in M3-F device work), the
 *    whisper.cpp / llama.cpp loading, foreground-service runtime behaviour, the
 *    runtime `RECORD_AUDIO` / `POST_NOTIFICATIONS` permission grants, and the
 *    end-to-end speech → terminal path.
 *
 * The utterance sink and runtime options are handed to the active workspace via
 * the process-wide [Bridge] singleton — the service is started/stopped through
 * the Android `Context.startForegroundService` API (no binding), so a static
 * bridge is the lightest seam to hand the cleaned-utterance text back to the
 * foreground coordinator without a `Binder`/AIDL.
 */
class ContinuousListeningService : Service() {

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var engine: ContinuousListeningEngine? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground()
        if (engine == null) {
            val eng = ContinuousListeningEngine.makeDefault(
                scope = serviceScope,
                options = Bridge.options,
            )
            eng.onUtteranceReady = { text -> Bridge.onUtterance?.invoke(text) }
            engine = eng
        }
        engine?.enable()
        // STICKY so the OS recreates the service after a low-memory kill while
        // continuous mode is still on; the workspace re-enables on next foreground.
        return START_STICKY
    }

    override fun onDestroy() {
        engine?.disable()
        engine = null
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun startInForeground() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Voice Listening",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "On-device wake-word listening for Claude Relay" }
            manager.createNotificationChannel(channel)
        }

        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Claude Relay")
            .setContentText("Listening for the wake word")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /**
     * Process-wide seam to hand the active workspace's utterance sink + runtime
     * options to the service, since the service is launched fire-and-forget via
     * `startForegroundService` (no binder). The workspace sets [onUtterance] +
     * [options] before [start] and clears [onUtterance] on teardown.
     */
    object Bridge {
        /** Cleaned-utterance sink → the active terminal `sendInput(String)`. */
        @Volatile
        var onUtterance: ((String) -> Unit)? = null

        /** Latest speech options snapshot (cleanup/enhancement/wake-word). */
        @Volatile
        var options: SpeechProcessingOptions = SpeechProcessingOptions()
    }

    companion object {
        private const val CHANNEL_ID = "continuous_listening"
        private const val NOTIFICATION_ID = 0x5EEC // arbitrary stable id

        /** Foregrounds the service (continuous mode on + workspace foreground). */
        fun start(context: Context) {
            val intent = Intent(context, ContinuousListeningService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Stops the service (background / disable). */
        fun stop(context: Context) {
            context.stopService(Intent(context, ContinuousListeningService::class.java))
        }
    }
}
