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
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import relay.feature.servers.ServersScreen
import relay.feature.servers.ServersViewModel
import relay.feature.settings.AppSettings
import relay.feature.workspace.QrScannerScreen
import relay.feature.workspace.QrShareSheet
import relay.feature.workspace.WorkspaceScreen
import relay.protocol.ConnectionConfig
import relay.session.NetworkObserver
import java.util.UUID

/** Nav-graph route constants. */
private object Routes {
    const val SPLASH = "splash"
    const val SERVERS = "servers"
    const val WORKSPACE = "workspace"
    const val SETTINGS = "settings"
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
    autoConnectConfig: ConnectionConfig?,
    appVersion: String,
    buildNumber: String,
) {
    val navController = rememberNavController()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    // The single live connection session (coordinator + workspace VM), or null.
    var activeSession by remember { mutableStateOf<ConnectionSession?>(null) }
    // True while a connect()/authenticate() round-trip is in flight.
    var connecting by remember { mutableStateOf(false) }
    val snackbarHostState = remember { SnackbarHostState() }

    // Tears down the current session (cancel recovery, disconnect, cancel scope).
    suspend fun teardownActive() {
        activeSession?.let { session ->
            session.coordinator.tearDown()
            session.scope.cancel()
        }
        activeSession = null
    }

    // Builds + connects a session for [config]+[token], records last-connected,
    // and navigates to Workspace. Surfaces failures as a snackbar on Servers.
    suspend fun connectAndOpen(config: ConnectionConfig, token: String) {
        if (connecting) return
        connecting = true
        try {
            teardownActive()
            val session = ConnectionSession.create(
                context = context,
                config = config,
                token = token,
                theme = settings.sessionNamingTheme.value,
            )
            session.coordinator.connect()
            activeSession = session
            settings.setLastConnectedServerId(config.id.toString())
            navController.navigate(Routes.WORKSPACE) {
                // Drop the splash from the back stack so back from Workspace lands
                // on Servers, never the splash.
                popUpTo(Routes.SERVERS) { inclusive = false }
            }
        } catch (e: Throwable) {
            teardownActive()
            snackbarHostState.currentSnackbarData?.dismiss()
            snackbarHostState.showSnackbar("Failed to connect: ${e.message ?: "unknown error"}")
        } finally {
            connecting = false
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
                    // M3: preload speech models here (no-op until M3).
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
            )
        }

        composable(Routes.WORKSPACE) {
            val session = activeSession
            if (session == null) {
                // Defensive: workspace with no live session pops back to Servers.
                LaunchedEffect(Unit) { navController.popBackStack(Routes.SERVERS, inclusive = false) }
            } else {
                WorkspaceRoute(
                    session = session,
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
    onConnect: (ConnectionConfig) -> Unit,
    onOpenSettings: () -> Unit,
) {
    val context = LocalContext.current
    val viewModel: ServersViewModel = viewModel(factory = ServersViewModel.factory(context))

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
    connectivity: NetworkObserver,
    pendingSessionId: StateFlow<UUID?>,
    clearPendingSession: () -> Unit,
    onDisconnect: () -> Unit,
) {
    val coordinator = session.coordinator

    // ON_RESUME → handleForegroundTransition (the scenePhase == .active analog).
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        coordinator.handleForegroundTransition()
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

    // QR share / scan sheet state.
    var shareSessionId by remember { mutableStateOf<UUID?>(null) }
    var showScanner by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    WorkspaceScreen(
        vm = session.workspaceViewModel,
        onDisconnect = onDisconnect,
        onAttach = { showScanner = true },
        onShareQr = { id -> shareSessionId = id },
        modifier = Modifier.fillMaxSize(),
    )

    shareSessionId?.let { id ->
        QrShareSheet(
            sessionId = id,
            sessionName = coordinator.name(id),
            onDismiss = { shareSessionId = null },
        )
    }

    if (showScanner) {
        QrScannerScreen(
            onSessionScanned = { id ->
                showScanner = false
                scope.launch { coordinator.attachRemoteSession(id) }
            },
            onCancel = { showScanner = false },
            modifier = Modifier.fillMaxSize(),
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
