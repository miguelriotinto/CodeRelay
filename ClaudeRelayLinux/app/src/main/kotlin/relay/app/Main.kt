@file:JvmName("CodeRelay")

package relay.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.Tray
import androidx.compose.ui.window.rememberWindowState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import relay.protocol.ConnectionConfig
import relay.protocol.SessionInfo
import relay.session.NetworkObserver
import relay.platform.ActivityNotifier
import relay.platform.DesktopNotifier
import relay.platform.LinuxConnectivitySource
import relay.platform.OmarchyTheme
import relay.storage.DeviceIdentifier
import relay.storage.SavedConnectionStore
import relay.storage.SessionOwnershipStore
import relay.storage.TokenStore
import relay.terminal.TerminalPalette
import relay.terminal.linux.LocalTerminalTheme
import relay.terminal.linux.TerminalTheme
import relay.feature.servers.ServersScreen
import relay.feature.servers.ServersViewModel
import relay.feature.settings.AppSettings
import relay.feature.settings.PreferenceStore
import relay.feature.workspace.QrShareSheet
import relay.feature.workspace.WorkspaceScreen
import relay.feature.workspace.ui.AttachSessionSheet
import java.util.UUID

/**
 * Entry point for the CodeRelay Linux desktop client.
 *
 * Wires the platform seams to the shared session stack. Everything below
 * [AppEnvironment] is code shared verbatim with the Android client; everything
 * inside it is Linux-specific.
 */
fun main(args: Array<String>) {
    // The .desktop entry passes the URL as %u, so a deep link arrives in argv.
    // Parsed before any UI exists so a malformed one cannot block startup.
    runApp(DeepLinks.fromArgs(args))
}

/**
 * The WM class this window actually reports, measured with `hyprctl clients`.
 *
 * Pinned by the `@file:JvmName("CodeRelay")` at the top of this file. Without
 * it the class is derived from the FILE name (`MainKt`), so renaming Main.kt
 * would silently change the WM class and break every window rule a user had
 * written. JvmName makes it an intentional, stable identifier.
 *
 * Compose Desktop's skiko backend creates the window itself and derives the
 * class from the main class name; it does **not** honour `awt.appClassName`.
 * That was verified both by setting the property in `main()` and by passing
 * `-Dawt.appClassName=coderelay` directly on the JVM command line — the class
 * stayed `relay-app-MainKt` in both cases.
 *
 * `packaging/coderelay.desktop` therefore declares THIS value as its
 * `StartupWMClass`, so Hyprland window rules and taskbar grouping match. It must
 * be re-measured if the main class is ever renamed, and re-checked against the
 * jpackage launcher, which may report a different class again.
 */
/**
 * The user-visible product name.
 *
 * `Code[Relay]` with the brackets, matching `CFBundleDisplayName` on iOS and
 * macOS and `app_name` on Android exactly. The brackets are the brand; dropping
 * them here would make Linux the only client showing a different name.
 */
const val DISPLAY_NAME = "Code[Relay]"

const val WM_CLASS = "relay-app-CodeRelay"

private fun runApp(initialLink: DeepLink) = application {
    val environment = remember { AppEnvironment.create() }
    val windowState = rememberWindowState(width = 1200.dp, height = 800.dp)

    // One live connection at a time, mirroring the Android nav graph's
    // Servers → Workspace transition. Null means "show the server list".
    var session by remember { mutableStateOf<ConnectionSession?>(null) }
    var windowVisible by remember { mutableStateOf(true) }

    // In-flight connect (gates double-clicks) and the last failure to report.
    var connecting by remember { mutableStateOf(false) }
    var connectError by remember { mutableStateOf<String?>(null) }

    // Attach sheet: null = closed, non-null = the fetched attachable sessions.
    var attachableSessions by remember { mutableStateOf<List<SessionInfo>?>(null) }
    var loadingAttachable by remember { mutableStateOf(false) }
    // Session whose QR share sheet is open (the top-bar QR chip and the sidebar
    // row menu both set it). Like `onAttach`, leaving `onShareQr` at its default
    // `{}` is why the button did nothing.
    var shareSessionId by remember { mutableStateOf<UUID?>(null) }

    // The offline→online edge feeding recovery, from the link-state poll. Only
    // the edge matters, so one observer is shared by every connection.
    val network = remember(environment) { NetworkObserver(environment.connectivity) }

    // A session deep link is held until a connection exists to attach it to —
    // the link can arrive before the user has connected to any server.
    var pendingSessionId by remember {
        mutableStateOf((initialLink as? DeepLink.Session)?.id)
    }

    val serversViewModel = remember {
        ServersViewModel.create(
            store = environment.connections,
            tokenStore = environment.tokens,
            scope = environment.scope,
        )
    }

    /**
     * Opens a bookmark: build the session, then run the launch handshake before
     * showing the workspace. Mirrors the Android `ConnectionViewModel.connect`.
     *
     * **The handshake is the point.** `ConnectionSession.create` only assembles
     * the object graph — it dials nothing. Without the `coordinator.connect()`
     * below the workspace opened on a socket that was never connected, and the
     * first thing the user did there (create a session) found a dead connection
     * and fell straight into the recovery scrim: a permanent "Reconnecting…"
     * against a server the list had just probed as Live.
     *
     * `connect()` throws only when the handshake exhausted its retries AND never
     * authenticated (bad token / unreachable host). That keeps the user on the
     * server list with the reason, rather than in a workspace that can never
     * work. A handshake that authenticated but could not list sessions returns
     * normally — the workspace opens and pull-to-refresh is the retry.
     *
     * Launched on the session's own scope (`Dispatchers.Main.immediate`, the AWT
     * event thread), which is the coordinator's confined dispatcher — so the
     * state writes below land on the same thread Compose renders on.
     */
    fun connectTo(config: ConnectionConfig) {
        if (connecting) return
        // No saved token means the bookmark was never completed. Say so, rather
        // than opening a workspace that can never authenticate — or, as before,
        // silently doing nothing when the row is clicked.
        val token = serversViewModel.tokenFor(config)
        if (token.isNullOrEmpty()) {
            connectError = "No auth token is saved for \"${config.name}\". " +
                "Edit the server to add one, or pair with the host again."
            return
        }
        connecting = true
        val candidate = ConnectionSession.create(
            config = config,
            token = token,
            settings = environment.settings,
            environment = environment,
        )
        candidate.scope.launch {
            val failure = runCatching { candidate.coordinator.connect() }.exceptionOrNull()
            if (failure == null) {
                session = candidate
            } else {
                candidate.close()
                connectError = "Couldn't connect to ${config.name}: " +
                    (failure.message ?: failure::class.simpleName ?: "unknown error")
            }
            connecting = false
        }
    }

    // Close-to-tray, mirroring the macOS client's menu-bar persistence: a relay
    // client is a thing you leave running, and quitting on window-close would
    // drop every session's connection.
    Tray(
        icon = remember(environment.theme) {
            TrayIconPainter(environment.theme?.let { Color(it.foreground) } ?: Color.White)
        },
        tooltip = session?.let { "$DISPLAY_NAME — ${it.config.name}" } ?: DISPLAY_NAME,
        onAction = { windowVisible = true },
        menu = {
            Item(if (windowVisible) "Hide window" else "Show window") {
                windowVisible = !windowVisible
            }
            if (session != null) {
                Item("Disconnect") {
                    session?.close()
                    session = null
                }
            }
            Separator()
            Item("Quit $DISPLAY_NAME") {
                session?.close()
                environment.close()
                exitApplication()
            }
        },
    )

    Window(
        visible = windowVisible,
        onCloseRequest = {
            // Hide rather than exit; Quit in the tray menu is the real exit.
            windowVisible = false
        },
        state = windowState,
        title = session?.let { "$DISPLAY_NAME — ${it.config.name}" } ?: DISPLAY_NAME,
    ) {
        RelayTheme(environment) {
            Surface(modifier = Modifier.fillMaxSize()) {
                val active = session
                if (active == null) {
                    ServersScreen(
                        viewModel = serversViewModel,
                        onConnect = ::connectTo,
                    )
                    if (connecting) {
                        // The handshake owns the window until it settles, so a
                        // second click cannot start a competing connection.
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .background(Color.Black.copy(alpha = 0.4f)),
                            contentAlignment = Alignment.Center,
                        ) {
                            CircularProgressIndicator()
                        }
                    }
                } else {
                    // Network restored → user recovery, the same edge the Android
                    // nav graph collects and the macOS client drives from wake.
                    LaunchedEffect(active) {
                        network.connectivityRestored.collect {
                            active.coordinator.triggerUserRecovery()
                        }
                    }
                    LaunchedEffect(active, pendingSessionId) {
                        val id = pendingSessionId ?: return@LaunchedEffect
                        pendingSessionId = null
                        runCatching { active.coordinator.switchToSession(id) }
                    }
                    WorkspaceScreen(
                        vm = active.workspaceViewModel,
                        onDisconnect = {
                            active.close()
                            session = null
                        },
                        // Attach: fetch the token's attachable sessions, THEN
                        // present the sheet, so it opens populated (the order
                        // the Android nav graph and iOS both use). Gated on
                        // `loadingAttachable` so a double click fires one fetch.
                        // Leaving this at its default `{}` is why the Attach
                        // button did nothing at all.
                        onAttach = {
                            if (!loadingAttachable) {
                                loadingAttachable = true
                                active.scope.launch {
                                    attachableSessions =
                                        runCatching { active.coordinator.fetchAttachableSessions() }
                                            .getOrDefault(emptyList())
                                    loadingAttachable = false
                                }
                            }
                        },
                        onShareQr = { id -> shareSessionId = id },
                        // Haptics are a no-op on desktop; passed for API parity.
                        hapticsEnabled = false,
                    )

                    shareSessionId?.let { id ->
                        QrShareSheet(
                            sessionId = id,
                            sessionName = active.coordinator.name(id),
                            onDismiss = { shareSessionId = null },
                        )
                    }

                    attachableSessions?.let { list ->
                        AttachSessionSheet(
                            sessions = list,
                            nameFor = { id -> active.coordinator.name(id) },
                            onAttachSession = { id, name ->
                                attachableSessions = null
                                active.scope.launch {
                                    active.coordinator.attachRemoteSession(id, name)
                                }
                            },
                            // The QR scanner is CameraX + ML Kit, excluded from
                            // this build; the sheet's list is the only path in.
                            onScannedSession = {},
                            onDismiss = { attachableSessions = null },
                        )
                    }
                }

                connectError?.let { message ->
                    AlertDialog(
                        onDismissRequest = { connectError = null },
                        title = { Text("Couldn't connect") },
                        text = { Text(message) },
                        confirmButton = {
                            TextButton(onClick = { connectError = null }) { Text("OK") }
                        },
                    )
                }
            }
        }
    }
}

/**
 * The Linux platform bindings, constructed once at startup.
 *
 * Deliberately a plain object graph rather than a DI framework: there are seven
 * dependencies and one construction site, so a container would add indirection
 * without removing any wiring.
 */
class AppEnvironment private constructor(
    val scope: CoroutineScope,
    val connections: SavedConnectionStore,
    val tokens: TokenStore,
    val ownership: SessionOwnershipStore,
    val deviceId: String,
    val connectivity: LinuxConnectivitySource,
    val notifier: ActivityNotifier,
    val theme: OmarchyTheme.Palette?,
    val settings: AppSettings,
) {
    /** Stops background work. Called when the window closes. */
    fun close() {
        runCatching { connectivity.stop() }
        runCatching { scope.cancel() }
    }

    companion object {
        fun create(): AppEnvironment {
            // SupervisorJob so one failing collector cannot cancel the others —
            // a notification failure must not take down the connectivity watch.
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val deviceId = DeviceIdentifier.get()
            val tokens = TokenStore()

            return AppEnvironment(
                scope = scope,
                connections = SavedConnectionStore(),
                tokens = tokens,
                ownership = SessionOwnershipStore(deviceId = deviceId),
                deviceId = deviceId,
                connectivity = LinuxConnectivitySource(scope),
                // focusedSession is wired once the coordinator exists; until
                // then every notification is delivered, which is the safe
                // default (over-notifying beats silently dropping).
                notifier = ActivityNotifier(DesktopNotifier()),
                // Absent on a non-Omarchy desktop; the terminal then keeps
                // TerminalPalette's built-in colours.
                theme = OmarchyTheme.load(),
                settings = AppSettings(
                    prefs = PreferenceStore(scope = scope),
                    tokenStore = tokens,
                    scope = scope,
                ),
            )
        }
    }
}

/**
 * Applies the Omarchy palette to the app chrome, falling back to a dark scheme.
 *
 * The terminal grid gets its colours separately, straight from the same palette
 * via `LinuxTerminalEmulator.applyPalette` — the two must not drift, which is
 * why both read [AppEnvironment.theme] rather than each deriving their own.
 */
@Composable
private fun RelayTheme(environment: AppEnvironment, content: @Composable () -> Unit) {
    val palette = environment.theme
    val isLight = palette?.mode == OmarchyTheme.Mode.LIGHT

    val colors = when {
        palette == null -> darkColorScheme()
        isLight -> lightColorScheme(
            primary = Color(palette.accent),
            background = Color(palette.background),
            surface = Color(palette.background),
            onBackground = Color(palette.foreground),
            onSurface = Color(palette.foreground),
        )
        else -> darkColorScheme(
            primary = Color(palette.accent),
            background = Color(palette.background),
            surface = Color(palette.background),
            onBackground = Color(palette.foreground),
            onSurface = Color(palette.foreground),
        )
    }

    // The terminal grid does not read MaterialTheme — it needs the raw ANSI
    // palette — so publish it alongside, from the SAME `environment.theme` the
    // chrome above is built from. Without this the grid fell back to its
    // built-in white-on-black while every other window on the desktop wore the
    // Omarchy palette, which is what made the relayed terminal read as a
    // different application rather than another terminal.
    val terminalTheme = remember(palette) {
        val (fg, bg) = terminalDefaultsFor(palette)
        TerminalTheme(ansi = palette?.ansi ?: TerminalPalette.colors, foreground = fg, background = bg)
    }

    CompositionLocalProvider(LocalTerminalTheme provides terminalTheme) {
        MaterialTheme(colorScheme = colors, content = content)
    }
}

/** Default terminal foreground/background: Omarchy's if present, else built-in. */
private fun terminalDefaultsFor(palette: OmarchyTheme.Palette?): Pair<Int, Int> =
    palette?.let { it.foreground to it.background }
        ?: (TerminalPalette.foreground to TerminalPalette.background)
