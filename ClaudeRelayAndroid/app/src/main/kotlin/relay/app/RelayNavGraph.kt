package relay.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import relay.feature.servers.ServersScreen
import relay.feature.servers.ServersViewModel
import relay.feature.settings.AppSettings
import relay.feature.workspace.QrShareSheet
import relay.feature.workspace.WorkspaceScreen
import relay.feature.workspace.ui.AttachSessionSheet
import relay.protocol.ConnectionConfig
import relay.protocol.SessionInfo
import relay.session.NetworkObserver
import java.util.UUID

/** Nav-graph route constants. */
private object Routes {
    const val SPLASH = "splash"
    const val SERVERS = "servers"
    const val WORKSPACE = "workspace"
    const val SETTINGS = "settings"
    const val PAIR_SCANNER = "pair_scanner"
}

/**
 * The real M2 nav graph (Splash → Servers → Workspace + Settings), replacing the
 * M1 demo. Ported in spirit from `ClaudeRelayApp.swift` (the SwiftUI scene with
 * the splash overlay, deep-link consume, auto-connect, and scenePhase recovery).
 *
 * ## Connection lifecycle
 * Connecting is the nav host's job (the `ServersViewModel` is list-only). On
 * `onConnect` the graph builds a [ConnectionSession] (coordinator + workspace VM)
 * via [ConnectionSession.create], runs `connect()` (connect → authenticate →
 * fetch), records `lastConnectedServerId`, and navigates to Workspace. On
 * Workspace `onDisconnect` it tears the session down and pops back to Servers.
 * Only one connection is live at a time (`activeSession`).
 *
 * ## Recovery wiring
 *  - **ON_RESUME** → `coordinator.handleForegroundTransition()` (the scenePhase
 *    `.active` analog), via [LifecycleEventEffect].
 *  - **Connectivity restored** → `coordinator.triggerUserRecovery()`, by
 *    collecting [NetworkObserver.connectivityRestored] (the offline→online edge).
 *  - **Auto-Connect** on launch: handled in [MainActivity] before the splash
 *    completes — see [autoConnectConfig].
 *
 * @param settings the persisted [AppSettings] (theme, auto-connect, version)
 * @param connectivity the network observer feeding recovery
 * @param pendingSessionId deep-link session id to consume on workspace entry
 * @param clearPendingSession clears [pendingSessionId] once consumed
 * @param pendingPairing deep-link pairing URL to consume on servers entry
 * @param clearPendingPairing clears [pendingPairing] once consumed
 * @param autoConnectConfig the server to auto-connect to on launch, or null
 * @param appVersion / @param buildNumber BuildConfig values for the About section
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RelayNavGraph(
    settings: AppSettings,
    connectivity: NetworkObserver,
    pendingSessionId: StateFlow<UUID?>,
    clearPendingSession: () -> Unit,
    pendingPairing: StateFlow<relay.protocol.PairingURL?>,
    clearPendingPairing: () -> Unit,
    onPairScanned: (relay.protocol.PairingURL) -> Unit,
    autoConnectConfig: ConnectionConfig?,
    appVersion: String,
    buildNumber: String,
) {
    val navController = rememberNavController()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    // The live connection lives in an Activity-RETAINED ViewModel, not a composition
    // `remember`, so it survives Activity recreation — crucially the Huawei Fold's
    // inner↔outer display switch on fold/unfold, which forces an Activity restart
    // that `android:configChanges` cannot suppress (a display change isn't a config
    // it covers). The nav back stack survives via rememberSaveable, so on recreation
    // the graph restores to WORKSPACE and re-binds to this still-alive session — the
    // user keeps typing in the same terminal instead of being bounced to Servers.
    val connectionVm: ConnectionViewModel = viewModel()
    val activeSession by connectionVm.activeSession.collectAsStateWithLifecycle()
    val connecting by connectionVm.connecting.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }

    // Tears down the current session (cancel recovery, disconnect, cancel scope).
    suspend fun teardownActive() {
        connectionVm.teardown()
    }

    // Builds + connects a session for [config]+[token], records last-connected,
    // and navigates to Workspace. Surfaces failures as a snackbar on Servers.
    suspend fun connectAndOpen(config: ConnectionConfig, token: String) {
        val error = connectionVm.connect(context, config, token, settings)
        if (error != null) {
            snackbarHostState.currentSnackbarData?.dismiss()
            snackbarHostState.showSnackbar(error)
            return
        }
        navController.navigate(Routes.WORKSPACE) {
            // Drop the splash from the back stack so back from Workspace lands
            // on Servers, never the splash.
            popUpTo(Routes.SERVERS) { inclusive = false }
        }
    }

    // Auto-connect on launch (ClaudeRelayApp.swift auto-connect). Gated on the nav
    // graph having advanced past the splash to Servers, so the WORKSPACE navigate's
    // `popUpTo(SERVERS)` has a valid anchor and the back stack stays Servers ←
    // Workspace (never Splash ← Workspace). Fires once per resolved config.
    val currentRoute = navController.currentBackStackEntryAsState().value?.destination?.route
    var autoConnectTried by remember { mutableStateOf(false) }
    LaunchedEffect(autoConnectConfig, currentRoute) {
        if (autoConnectTried) return@LaunchedEffect
        if (currentRoute != Routes.SERVERS) return@LaunchedEffect
        val config = autoConnectConfig ?: return@LaunchedEffect
        autoConnectTried = true
        val token = loadTokenFor(context, config.id) ?: return@LaunchedEffect
        connectAndOpen(config, token)
    }

    NavHost(navController = navController, startDestination = Routes.SPLASH) {
        composable(Routes.SPLASH) {
            SplashScreen(
                appVersion = appVersion,
                onComplete = {
                    // Best-effort, non-blocking speech-model preload/check (M3 Task 11).
                    // Re-derives model-readiness from disk so a download finished on a
                    // previous launch is reflected; does NOT trigger a download (that is
                    // user-gated behind the mic button's prompt — iOS preload parity).
                    scope.launch { runCatching { preloadSpeechModels(context) } }
                    navController.navigate(Routes.SERVERS) {
                        popUpTo(Routes.SPLASH) { inclusive = true }
                    }
                },
            )
        }

        composable(Routes.SERVERS) {
            ServersRoute(
                snackbarHostState = snackbarHostState,
                connecting = connecting,
                pendingPairing = pendingPairing,
                clearPendingPairing = clearPendingPairing,
                onConnect = { config ->
                    val token = loadTokenFor(context, config.id)
                    if (token.isNullOrEmpty()) {
                        scope.launch {
                            snackbarHostState.currentSnackbarData?.dismiss()
                            snackbarHostState.showSnackbar("No saved token for ${config.name}. Edit the server to add one.")
                        }
                    } else {
                        scope.launch { connectAndOpen(config, token) }
                    }
                },
                onOpenSettings = { navController.navigate(Routes.SETTINGS) },
                onScanPair = { navController.navigate(Routes.PAIR_SCANNER) },
            )
        }

        composable(Routes.PAIR_SCANNER) {
            // Camera QR scanner for pairing. A scanned `coderelay://pair` QR is
            // parsed to a PairingURL and handed to `onPairScanned` (→ the host's
            // pending-pairing flow), then we pop back to Servers, which shows the
            // prefilled sheet — the exact same consumer the deep-link path uses.
            // Non-pairing QRs are rejected by the scanner (onDecoded returns false),
            // so an unrelated code never dismisses the camera.
            relay.feature.workspace.QrScannerFullScreen(
                onDecoded = { raw ->
                    val url = relay.protocol.PairingURL.parse(raw) ?: return@QrScannerFullScreen false
                    onPairScanned(url)
                    navController.popBackStack(Routes.SERVERS, inclusive = false)
                    true
                },
                onCancel = { navController.popBackStack(Routes.SERVERS, inclusive = false) },
                modifier = Modifier.fillMaxSize(),
            )
        }

        composable(Routes.WORKSPACE) {
            val session = activeSession
            if (session == null) {
                // No live session behind a restored WORKSPACE route. This is the
                // PROCESS-DEATH path: Android killed the app under memory pressure,
                // then restored the saved NavHost back stack (which lands on
                // WORKSPACE), but ConnectionViewModel is a plain ViewModel with no
                // SavedStateHandle — a live WebSocket + coroutine scope cannot be
                // serialized across process death — so activeSession comes back null.
                //
                // (This branch does NOT fire on a fold/rotation/config change: there
                // the Activity-retained ConnectionViewModel survives, so activeSession
                // is still non-null and we re-bind to the live terminal below — the
                // Huawei Fold survival fix, commit 970496c. The null check is exactly
                // the process-death-vs-config-change discriminator.)
                //
                // Route to SERVERS deterministically by popping WORKSPACE ITSELF
                // (inclusive), NOT popBackStack(SERVERS): the latter silently no-ops
                // if SERVERS isn't on the restored stack, which would strand the user
                // on a dead workspace. If SERVERS is somehow absent too, navigate to
                // it as a fallback so we always land somewhere live. Render nothing
                // meanwhile so the empty workspace chrome never flashes.
                LaunchedEffect(Unit) {
                    val popped = navController.popBackStack(Routes.WORKSPACE, inclusive = true)
                    if (!popped || navController.currentBackStackEntry?.destination?.route != Routes.SERVERS) {
                        navController.navigate(Routes.SERVERS) {
                            popUpTo(navController.graph.id) { inclusive = true }
                        }
                    }
                }
            } else {
                WorkspaceRoute(
                    session = session,
                    settings = settings,
                    connectivity = connectivity,
                    pendingSessionId = pendingSessionId,
                    clearPendingSession = clearPendingSession,
                    onDisconnect = {
                        scope.launch {
                            teardownActive()
                            navController.popBackStack(Routes.SERVERS, inclusive = false)
                        }
                    },
                )
            }
        }

        composable(Routes.SETTINGS) {
            SettingsRoute(
                settings = settings,
                appVersion = appVersion,
                buildNumber = buildNumber,
                onDone = { navController.popBackStack() },
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ServersRoute(
    snackbarHostState: SnackbarHostState,
    connecting: Boolean,
    pendingPairing: StateFlow<relay.protocol.PairingURL?>,
    clearPendingPairing: () -> Unit,
    onConnect: (ConnectionConfig) -> Unit,
    onOpenSettings: () -> Unit,
    onScanPair: () -> Unit,
) {
    val context = LocalContext.current
    val viewModel: ServersViewModel = viewModel(factory = ServersViewModel.factory(context))

    // Consume pending pairing deep link (Task 7→8 seam). The URL flows into
    // ServersScreen, which triggers the pairing sheet prefilled from the URL and
    // calls clearPendingPairing after presentation.
    val pendingPairingUrl by pendingPairing.collectAsStateWithLifecycle()

    // ServersScreen owns its own Scaffold/TopAppBar/Add-FAB, gates cleartext on
    // connect, and owns the add/edit sheet (onEdit → AddEditServerSheet). We host
    // it directly and forward onConnect to the nav host's connect flow. The
    // Settings gear (the M2-E review flagged it missing) is overlaid top-end —
    // ServersScreen's app bar is internal, so an overlay is the lightest-touch
    // entry point without changing that module's public API; the snackbar host +
    // connecting overlay sit in the same Box.
    Box(modifier = Modifier.fillMaxSize()) {
        ServersScreen(
            viewModel = viewModel,
            onConnect = onConnect,
            modifier = Modifier.fillMaxSize(),
            pendingPairingUrl = pendingPairingUrl,
            clearPendingPairing = clearPendingPairing,
            onScanPair = onScanPair,
        )

        IconButton(
            onClick = onOpenSettings,
            modifier = Modifier.align(Alignment.TopEnd).padding(4.dp),
        ) {
            Icon(
                Icons.Filled.Settings,
                contentDescription = "Settings",
                tint = MaterialTheme.colorScheme.onSurface,
            )
        }

        SnackbarHost(
            snackbarHostState,
            modifier = Modifier.align(Alignment.BottomCenter),
        )

        if (connecting) {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator()
                    Text("Connecting…", style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
    }
}

@Composable
private fun WorkspaceRoute(
    session: ConnectionSession,
    settings: AppSettings,
    connectivity: NetworkObserver,
    pendingSessionId: StateFlow<UUID?>,
    clearPendingSession: () -> Unit,
    onDisconnect: () -> Unit,
) {
    val coordinator = session.coordinator
    val hapticsEnabled by settings.hapticFeedbackEnabled.collectAsStateWithLifecycle()

    // ON_RESUME → restore + repaint the active terminal (the scenePhase == .active
    // analog). restoreActiveOnForeground() is the SINGLE foreground entry point:
    //  - dead socket → it defers to full recovery (reconnect → reauth → resume),
    //  - live-but-stalled socket → it resumes in place so the server replays
    //    scrollback into the live emulator and the terminal repaints.
    // It deliberately replaces the old bare handleForegroundTransition() call here:
    // calling BOTH would race two resumes on one connection when the socket is
    // alive (handleForegroundTransition's recovery short-circuits to fetch WITHOUT
    // setting isRecovering, so it would not gate the repaint path). The
    // network-restored edge still drives handleForegroundTransition via the
    // connectivityRestored collector below.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        coordinator.restoreActiveOnForeground()
    }

    // Connectivity restored → user-recovery (NetworkMonitor.connectivityRestored).
    LaunchedEffect(connectivity) {
        connectivity.connectivityRestored.collect {
            coordinator.triggerUserRecovery()
        }
    }

    // Consume a pending deep-link session id once: attach then clear (Task 9 seam).
    val pending by pendingSessionId.collectAsStateWithLifecycle()
    LaunchedEffect(pending) {
        val id = pending ?: return@LaunchedEffect
        coordinator.attachRemoteSession(id)
        clearPendingSession()
    }

    // QR share sheet state.
    var shareSessionId by remember { mutableStateOf<UUID?>(null) }
    // Attach modal: null = closed; non-null = the fetched attachable-session list
    // to show (iOS `showAttachSheet` + `attachableSessions`). A fetch runs on
    // tap-Attach before presenting, so the list is populated when the sheet opens.
    var attachableSessions by remember { mutableStateOf<List<SessionInfo>?>(null) }
    var loadingAttachable by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    WorkspaceScreen(
        vm = session.workspaceViewModel,
        onDisconnect = onDisconnect,
        onAttach = {
            // iOS: fetch attachable sessions, THEN present the sheet. Gate on
            // loadingAttachable so a double tap doesn't fire two fetches.
            if (!loadingAttachable) {
                loadingAttachable = true
                scope.launch {
                    attachableSessions = coordinator.fetchAttachableSessions()
                    loadingAttachable = false
                }
            }
        },
        onShareQr = { id -> shareSessionId = id },
        micButton = { session.speech.MicButtonSlot(session.workspaceViewModel) },
        hapticsEnabled = hapticsEnabled,
        modifier = Modifier.fillMaxSize(),
    )

    shareSessionId?.let { id ->
        QrShareSheet(
            sessionId = id,
            sessionName = coordinator.name(id),
            onDismiss = { shareSessionId = null },
        )
    }

    attachableSessions?.let { list ->
        AttachSessionSheet(
            sessions = list,
            nameFor = { id -> coordinator.name(id) },
            onAttachSession = { id, name ->
                attachableSessions = null
                scope.launch { coordinator.attachRemoteSession(id, name) }
            },
            onScannedSession = { id ->
                attachableSessions = null
                scope.launch { coordinator.attachRemoteSession(id) }
            },
            onDismiss = { attachableSessions = null },
        )
    }
}

@Composable
private fun SettingsRoute(
    settings: AppSettings,
    appVersion: String,
    buildNumber: String,
    onDone: () -> Unit,
) {
    relay.feature.settings.SettingsScreen(
        settings = settings,
        appVersion = appVersion,
        buildNumber = buildNumber,
        onDone = onDone,
        modifier = Modifier.fillMaxSize(),
    )
}

// MARK: - Helpers

/** Loads the saved token for [connectionId] from the secure store, or null. */
private fun loadTokenFor(context: android.content.Context, connectionId: UUID): String? =
    relay.storage.TokenStore(context.applicationContext).loadToken(connectionId)

/**
 * Best-effort splash-time speech-model preload/check (M3 Task 11). Runs on
 * [kotlinx.coroutines.Dispatchers.IO] (filesystem stat). Constructs a transient
 * app-rooted [relay.speech.SpeechModelStore] and refreshes its readiness flags
 * from disk. It is fine if models aren't downloaded yet — this just checks. The
 * per-connection [SpeechSession] owns the real engines + (user-gated) download.
 */
private suspend fun preloadSpeechModels(context: android.content.Context) {
    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
        relay.speech.SpeechModelStore.create(context.applicationContext).refreshFromDisk()
    }
}
