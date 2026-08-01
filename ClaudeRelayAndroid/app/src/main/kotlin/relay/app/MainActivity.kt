package relay.app

import android.content.Intent
import android.graphics.Color as AndroidColor
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import relay.feature.settings.AppSettings
import relay.feature.workspace.DeepLinks
import relay.protocol.ConnectionConfig
import relay.session.NetworkObserver
import relay.storage.SavedConnectionStore
import java.util.UUID

private const val TAG = "MainActivity"

/**
 * Single-activity host for the real M2 nav graph ([RelayNavGraph]), replacing the
 * M1 demo. Ported in role from `ClaudeRelayApp.swift`:
 *  - sets the Compose content to [RelayNavGraph] (Splash → Servers → Workspace +
 *    Settings);
 *  - parses `clauderelay://session/<uuid>` deep links on cold start (`onCreate`)
 *    and warm start (`onNewIntent`, `launchMode="singleTop"`), storing the id in
 *    [pendingSessionId] which the nav graph consumes on workspace entry;
 *  - owns the long-lived [AppSettings] + [AndroidConnectivitySource] +
 *    [NetworkObserver], and resolves the auto-connect target before the splash
 *    completes.
 *
 * `launchMode` is `singleTop` so warm deep links re-deliver to the existing
 * instance via [onNewIntent] instead of stacking a new activity.
 */
class MainActivity : ComponentActivity() {

    /** App-lifetime scope for settings flows + auto-connect resolution. */
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private lateinit var settings: AppSettings
    private lateinit var connectivitySource: AndroidConnectivitySource
    private lateinit var networkObserver: NetworkObserver

    /**
     * Speech runtime-permission launcher (RECORD_AUDIO + POST_NOTIFICATIONS on
     * API 33+). [SpeechSession] triggers it via [SpeechPermissions.request] before
     * the first mic interaction. Result is informational here — the mic flow is
     * device-deferred, so the grant outcome is not blocking in this build.
     */
    private val speechPermissionLauncher: ActivityResultLauncher<Array<String>> =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
            Log.i(TAG, "Speech permission grants: $grants")
        }

    /**
     * The most recent session id parsed from a `clauderelay://session/<uuid>`
     * deep link, or null. The nav graph collects this on workspace entry, calls
     * `SessionCoordinator.attachRemoteSession(id)`, then clears it via
     * [clearPendingSession].
     */
    val pendingSessionId: StateFlow<UUID?> get() = _pendingSessionId.asStateFlow()
    private val _pendingSessionId = MutableStateFlow<UUID?>(null)

    /**
     * The most recent pairing URL parsed from a `clauderelay://pair?...` deep link,
     * or null. The nav graph collects this on the Servers route, presents the pairing
     * sheet prefilled from it, then clears it via [clearPendingPairing].
     */
    val pendingPairing: StateFlow<relay.protocol.PairingURL?> get() = _pendingPairing.asStateFlow()
    private val _pendingPairing = MutableStateFlow<relay.protocol.PairingURL?>(null)

    /** The server to auto-connect to on launch, or null when auto-connect is off. */
    private val _autoConnectConfig = MutableStateFlow<ConnectionConfig?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        // Draw edge-to-edge with TRANSPARENT system bars so the app content (a
        // black terminal + dark chrome) fills behind the status bar (top) and
        // navigation bar (bottom) — those areas read as black, matching the
        // terminal, instead of the OS default light scrim. `dark(...)` forces
        // LIGHT bar icons (we're always-dark; see RelayTheme), regardless of the
        // device's system light/dark setting.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)

        settings = AppSettings.create(this, appScope)
        connectivitySource = AndroidConnectivitySource(this)
        networkObserver = NetworkObserver(connectivitySource)
        connectivitySource.start()

        // Register the speech runtime-permission requester for SpeechSession.
        SpeechPermissions.requester = { speechPermissionLauncher.launch(SpeechPermissions.required) }

        // Resolve the auto-connect target (ClaudeRelayApp.swift auto-connect): when
        // enabled AND lastConnectedServerId resolves to a saved bookmark.
        appScope.launch { resolveAutoConnect() }

        // Cold-start deep link (app launched from the link).
        handleDeepLink(intent)

        setContent {
            RelayTheme {
                // Black root behind everything so the edge-to-edge status/nav-bar
                // insets paint black (the terminal color), not a stray light gap.
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    RelayNavGraph(
                        settings = settings,
                        connectivity = networkObserver,
                        pendingSessionId = pendingSessionId,
                        clearPendingSession = ::clearPendingSession,
                        pendingPairing = pendingPairing,
                        clearPendingPairing = ::clearPendingPairing,
                        autoConnectConfig = collectAutoConnect(),
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
        connectivitySource.stop()
        SpeechPermissions.requester = null
        appScope.cancel()
        super.onDestroy()
    }

    /** Clears the pending session once the nav graph has consumed it. */
    fun clearPendingSession() {
        _pendingSessionId.value = null
    }

    /** Clears the pending pairing once the nav graph has consumed it. */
    fun clearPendingPairing() {
        _pendingPairing.value = null
    }

    /**
     * Resolves [_autoConnectConfig] from the persisted auto-connect setting +
     * last-connected server id. No-op (stays null) when auto-connect is off or the
     * id no longer maps to a saved bookmark.
     *
     * **AWAITs the persisted values with `.first()`, not `.value`.** At cold start
     * the StateFlow `.value` is still the seed default (`false` / `""`) because the
     * Preferences DataStore disk read is async — reading `.value` synchronously
     * would make auto-connect never fire. `.first()` suspends until the first real
     * emission (the on-disk value), so the decision is made against persisted data.
     * Runs in [appScope] (a coroutine), so suspending here is safe.
     *
     * After Fix C2, the resolved config flows into the nav-graph auto-connect
     * LaunchedEffect → `connectAndOpen` → `coordinator.connect` →
     * `RelayConnection.connect`, which enforces the cleartext gate. So an
     * auto-connect to a non-private cleartext host now correctly fails the gate
     * (surfaced as a "Failed to connect" snackbar) instead of connecting in clear.
     */
    private suspend fun resolveAutoConnect() {
        if (!settings.autoConnectEnabled.first()) return
        val lastId = settings.lastConnectedServerId.first()
        if (lastId.isBlank()) return
        val uuid = runCatching { UUID.fromString(lastId) }.getOrNull() ?: return
        val saved = SavedConnectionStore(applicationContext).loadAll()
        _autoConnectConfig.value = saved.firstOrNull { it.id == uuid }
    }

    /** Bridges [_autoConnectConfig] into Compose state for the nav graph. */
    @Composable
    private fun collectAutoConnect(): ConnectionConfig? =
        _autoConnectConfig.collectAsStateWithLifecycle().value

    private fun handleDeepLink(intent: Intent?) {
        val data = intent?.data?.toString() ?: return

        // Try pairing link first (clauderelay://pair?...).
        DeepLinks.parsePairingUrl(data)?.let {
            Log.i(TAG, "Deep link → pending pairing: ${it.host}:${it.port}")
            _pendingPairing.value = it
            return
        }

        // Then try session link (clauderelay://session/<uuid>).
        val sessionId = DeepLinks.parseSessionId(data)
        if (sessionId == null) {
            Log.w(TAG, "Ignoring unparseable deep link: $data")
            return
        }
        Log.i(TAG, "Deep link → pending session $sessionId")
        _pendingSessionId.value = sessionId
    }
}
