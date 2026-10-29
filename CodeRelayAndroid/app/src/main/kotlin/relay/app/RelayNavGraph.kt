package relay.app

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
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
import relay.protocol.SessionInfo
import relay.protocol.SessionRef
import relay.session.NetworkObserver
import relay.session.hub.attachRemote

/** Nav-graph route constants. */
private object Routes {
    const val SPLASH = "splash"
    const val SERVERS = "servers"
    const val WORKSPACE = "workspace"
    const val SETTINGS = "settings"
    const val PAIR_SCANNER = "pair_scanner"
}

/**
 * Splash → Workspace, with Servers (management), Settings and the pairing
 * scanner on top (multi-server spec §8.4).
 *
 * The workspace is the hub's: every enabled server is live in it, so there is
 * no Connect and no single "active connection". The hub is owned by the
 * activity-retained [HubViewModel], so a rotation or a fold's display switch
 * re-binds to the same sockets; it is started by [MainActivity] before the
 * first frame. With no server enabled the workspace presents Servers itself.
 *
 * ## Recovery wiring
 *  - **ON_RESUME** → [HubViewModel.onForeground] (every server, staggered; the
 *    active one also repaints its terminal).
 *  - **Connectivity restored** → [HubViewModel.onConnectivityRestored].
 */
@Composable
fun RelayNavGraph(
    settings: AppSettings,
    connectivity: NetworkObserver,
    hubViewModel: HubViewModel<AppServerSlot>,
    pendingPairing: StateFlow<relay.protocol.PairingURL?>,
    clearPendingPairing: () -> Unit,
    onPairScanned: (relay.protocol.PairingURL) -> Unit,
    appVersion: String,
    buildNumber: String,
) {
    val navController = rememberNavController()
    val hub = hubViewModel.hub

    // A pairing link (deep link or scan) opens the management screen, which
    // consumes it into its prefilled pairing sheet.
    val pairing by pendingPairing.collectAsStateWithLifecycle()
    val currentRoute = navController.currentBackStackEntryAsState().value?.destination?.route
    LaunchedEffect(pairing, currentRoute) {
        if (pairing != null && currentRoute != null && currentRoute != Routes.SPLASH && currentRoute != Routes.SERVERS) {
            navController.openServers()
        }
    }

    NavHost(navController = navController, startDestination = Routes.SPLASH) {
        composable(Routes.SPLASH) {
            SplashScreen(
                appVersion = appVersion,
                onComplete = {
                    navController.navigate(Routes.WORKSPACE) {
                        popUpTo(Routes.SPLASH) { inclusive = true }
                    }
                },
            )
        }

        composable(Routes.WORKSPACE) {
            WorkspaceRoute(
                hubViewModel = hubViewModel,
                settings = settings,
                connectivity = connectivity,
                onOpenServers = { navController.openServers() },
            )
        }

        composable(Routes.SERVERS) {
            val aggregate by hub.aggregate.collectAsStateWithLifecycle()
            val activity = LocalContext.current as? Activity
            // With nothing enabled the workspace would only send the user back
            // here, so Back leaves the app instead of looping.
            BackHandler(enabled = aggregate.enabledServers == 0) { activity?.finish() }
            ServersRoute(
                hubViewModel = hubViewModel,
                pendingPairing = pendingPairing,
                clearPendingPairing = clearPendingPairing,
                onDone = { if (!navController.popBackStack()) navController.navigate(Routes.WORKSPACE) },
                onOpenSettings = { navController.navigate(Routes.SETTINGS) },
                onScanPair = { navController.navigate(Routes.PAIR_SCANNER) },
            )
        }

        composable(Routes.PAIR_SCANNER) {
            // A scanned `coderelay://pair` QR joins the deep-link path: the
            // pending-pairing flow, consumed by the management screen. Non-pairing
            // QRs are rejected (onDecoded returns false) so the camera stays up.
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

/** Servers over the workspace, never stacked twice. */
private fun NavHostController.openServers() {
    navigate(Routes.SERVERS) { launchSingleTop = true }
}

@Composable
private fun ServersRoute(
    hubViewModel: HubViewModel<AppServerSlot>,
    pendingPairing: StateFlow<relay.protocol.PairingURL?>,
    clearPendingPairing: () -> Unit,
    onDone: () -> Unit,
    onOpenSettings: () -> Unit,
    onScanPair: () -> Unit,
) {
    val context = LocalContext.current
    val viewModel: ServersViewModel = viewModel(factory = ServersViewModel.factory(context))
    val pendingPairingUrl by pendingPairing.collectAsStateWithLifecycle()

    Box(modifier = Modifier.fillMaxSize()) {
        ServersScreen(
            viewModel = viewModel,
            hub = hubViewModel.hub,
            onDone = onDone,
            modifier = Modifier.fillMaxSize(),
            pendingPairingUrl = pendingPairingUrl,
            clearPendingPairing = clearPendingPairing,
            onScanPair = onScanPair,
        )
        // ServersScreen's app bar is internal to its module; the Settings gear is
        // overlaid top-end, left of the Done action.
        IconButton(
            onClick = onOpenSettings,
            modifier = Modifier.align(Alignment.TopEnd).padding(top = 4.dp, end = 72.dp),
        ) {
            Icon(Icons.Filled.Settings, contentDescription = "Settings", tint = MaterialTheme.colorScheme.onSurface)
        }
    }
}

@Composable
private fun WorkspaceRoute(
    hubViewModel: HubViewModel<AppServerSlot>,
    settings: AppSettings,
    connectivity: NetworkObserver,
    onOpenServers: () -> Unit,
) {
    val hub = hubViewModel.hub
    val hapticsEnabled by settings.hapticFeedbackEnabled.collectAsStateWithLifecycle()
    val shareScreen by settings.shareScreenWithOptimizer.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { hubViewModel.onForeground() }
    LaunchedEffect(connectivity) {
        connectivity.connectivityRestored.collect { hubViewModel.onConnectivityRestored() }
    }

    var shareRef by remember { mutableStateOf<SessionRef?>(null) }
    // Attach modal for one server: the slot and its fetched attachable list.
    var attachable by remember { mutableStateOf<Pair<AppServerSlot, List<SessionInfo>>?>(null) }
    var loadingAttachable by remember { mutableStateOf(false) }

    WorkspaceScreen(
        hub = hub,
        onOpenServers = onOpenServers,
        onAttach = { slot ->
            if (!loadingAttachable) {
                loadingAttachable = true
                scope.launch {
                    attachable = slot to slot.coordinator.fetchAttachableSessions()
                    loadingAttachable = false
                }
            }
        },
        onShareQr = { ref -> shareRef = ref },
        shareScreen = shareScreen,
        hapticsEnabled = hapticsEnabled,
        modifier = Modifier.fillMaxSize(),
    )

    shareRef?.let { ref ->
        val coordinator = hub.slot(ref.serverId)?.coordinator
        QrShareSheet(
            sessionId = ref.sessionId,
            sessionName = coordinator?.name(ref.sessionId),
            serverInstanceId = hub.sections.value.firstOrNull { it.id == ref.serverId }?.config?.instanceId,
            onDismiss = { shareRef = null },
        )
    }

    attachable?.let { (slot, list) ->
        AttachSessionSheet(
            sessions = list,
            nameFor = { id -> slot.coordinator.name(id) },
            onAttachSession = { id, name ->
                attachable = null
                scope.launch { hub.attachRemote(slot.config.id, id, name) }
            },
            onScannedSession = { id ->
                attachable = null
                scope.launch { hub.attachRemote(slot.config.id, id, null) }
            },
            onDismiss = { attachable = null },
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
        // No Android host reads `recordingShortcut*` (the Apple clients do), so
        // rendering the section would advertise a shortcut that does nothing.
        visibleSections = relay.feature.settings.SettingsSection.entries.toSet() -
            relay.feature.settings.SettingsSection.KEYBOARD_SHORTCUTS,
    )
}
