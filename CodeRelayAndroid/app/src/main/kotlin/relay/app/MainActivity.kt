package relay.app

import android.Manifest
import android.content.Intent
import android.graphics.Color as AndroidColor
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import relay.feature.settings.AppSettings
import relay.session.NetworkObserver

private const val TAG = "MainActivity"

/**
 * Single-activity host for [RelayNavGraph] (Splash → Workspace, with Servers,
 * Settings and the pairing scanner on top). Ported in role from
 * `CodeRelayApp.swift`:
 *  - owns the multi-server hub through the activity-retained [HubViewModel] and
 *    starts it before the first frame (idempotent across recreation);
 *  - routes `coderelay://` links on cold start (`onCreate`) and warm start
 *    (`onNewIntent`, `launchMode="singleTop"`): a session link — a push tap
 *    included — goes to the hub with its `?server=` hint (the hub waits for its
 *    first start, so a cold launch from a notification still opens the right
 *    session on the right server); a pairing link opens management;
 *  - owns the long-lived [AppSettings] + [AndroidConnectivitySource] +
 *    [NetworkObserver].
 */
class MainActivity : ComponentActivity() {

    /** App-lifetime scope for settings flows. */
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private lateinit var settings: AppSettings
    private lateinit var connectivitySource: AndroidConnectivitySource
    private lateinit var networkObserver: NetworkObserver

    private val hubViewModel: HubViewModel<AppServerSlot> by viewModels { HubViewModel.factory(application) }

    /**
     * POST_NOTIFICATIONS runtime request (API 33+). Push needs the grant; the
     * result re-syncs registration on every relay.
     */
    private val notificationPermissionLauncher: ActivityResultLauncher<String> =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            FcmTokenBridge.setPermissionGranted(granted)
            if (granted) FcmTokenBridge.onTokenRefreshed?.invoke()
        }

    /**
     * The most recent pairing URL parsed from a `coderelay://pair?...` deep link
     * or the in-app scanner, or null. The management screen presents the pairing
     * sheet prefilled from it, then clears it via [clearPendingPairing].
     */
    val pendingPairing: StateFlow<relay.protocol.PairingURL?> get() = _pendingPairing.asStateFlow()
    private val _pendingPairing = MutableStateFlow<relay.protocol.PairingURL?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        // Draw edge-to-edge with TRANSPARENT system bars so the app content (a
        // black terminal + dark chrome) fills behind the status bar (top) and
        // navigation bar (bottom). `dark(...)` forces LIGHT bar icons (we're
        // always-dark; see RelayTheme).
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)

        settings = AppSettings.create(this, appScope)
        connectivitySource = AndroidConnectivitySource(this)
        networkObserver = NetworkObserver(connectivitySource)
        connectivitySource.start()

        // First creation only. A display change (Huawei Fold outer↔inner) restarts
        // the Activity despite our configChanges, as does a process-death restore, and
        // re-prompting a user who already declined is what locks the OS into auto-deny.
        if (savedInstanceState == null &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !PushSync.notificationsGranted(this)
        ) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }

        hubViewModel.start()
        // A fresh FCM token or a newly granted permission re-registers on every relay.
        FcmTokenBridge.onTokenRefreshed = { hubViewModel.syncPush() }

        // Cold-start deep link (app launched from the link or a notification).
        handleDeepLink(intent)

        setContent {
            RelayTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    RelayNavGraph(
                        settings = settings,
                        connectivity = networkObserver,
                        hubViewModel = hubViewModel,
                        pendingPairing = pendingPairing,
                        clearPendingPairing = ::clearPendingPairing,
                        onPairScanned = ::setPendingPairing,
                        appVersion = BuildConfig.VERSION_NAME,
                        buildNumber = BuildConfig.VERSION_CODE.toString(),
                    )
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Warm-start deep link (app already running).
        setIntent(intent)
        handleDeepLink(intent)
    }

    override fun onDestroy() {
        if (!isChangingConfigurations) FcmTokenBridge.onTokenRefreshed = null
        connectivitySource.stop()
        appScope.cancel()
        super.onDestroy()
    }

    /** Clears the pending pairing once the management screen has consumed it. */
    fun clearPendingPairing() {
        _pendingPairing.value = null
    }

    /** Feeds a pairing URL from the in-app QR scanner into the same flow a `coderelay://pair` link uses. */
    fun setPendingPairing(url: relay.protocol.PairingURL) {
        _pendingPairing.value = url
    }

    private fun handleDeepLink(intent: Intent?) {
        val data = intent?.data?.toString() ?: return
        when (val route = DeepLinkRouting.route(data)) {
            is DeepLinkRouting.Route.Pair -> {
                Log.i(TAG, "Deep link → pending pairing: ${route.url.host}:${route.url.port}")
                _pendingPairing.value = route.url
            }
            is DeepLinkRouting.Route.Session -> {
                Log.i(TAG, "Deep link → session ${route.link.sessionId} (server hint: ${route.link.serverInstanceId != null})")
                hubViewModel.open(route.link)
            }
            DeepLinkRouting.Route.None -> {
                val uri = intent.data
                Log.w(TAG, "Ignoring unparseable deep link: ${uri?.scheme}://${uri?.host}${uri?.path}")
            }
        }
    }
}
