package relay.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import relay.platform.ActivityNotifier
import relay.platform.DesktopNotifier
import relay.platform.LinuxConnectivitySource
import relay.platform.OmarchyTheme
import relay.storage.DeviceIdentifier
import relay.storage.SavedConnectionStore
import relay.storage.SessionOwnershipStore
import relay.storage.TokenStore
import relay.terminal.TerminalPalette
import relay.feature.servers.ServersScreen
import relay.feature.servers.ServersViewModel
import relay.feature.settings.AppSettings
import relay.feature.settings.PreferenceStore
import relay.feature.workspace.WorkspaceScreen

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
const val WM_CLASS = "relay-app-MainKt"

private fun runApp(initialLink: DeepLink) = application {
    val environment = remember { AppEnvironment.create() }
    val windowState = rememberWindowState(width = 1200.dp, height = 800.dp)

    // One live connection at a time, mirroring the Android nav graph's
    // Servers → Workspace transition. Null means "show the server list".
    var session by remember { mutableStateOf<ConnectionSession?>(null) }
    var windowVisible by remember { mutableStateOf(true) }

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

    // Close-to-tray, mirroring the macOS client's menu-bar persistence: a relay
    // client is a thing you leave running, and quitting on window-close would
    // drop every session's connection.
    Tray(
        icon = remember(environment.theme) {
            TrayIconPainter(environment.theme?.let { Color(it.foreground) } ?: Color.White)
        },
        tooltip = session?.let { "CodeRelay — ${it.config.name}" } ?: "CodeRelay",
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
            Item("Quit CodeRelay") {
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
        title = session?.let { "CodeRelay — ${it.config.name}" } ?: "CodeRelay",
    ) {
        RelayTheme(environment) {
            Surface(modifier = Modifier.fillMaxSize()) {
                val active = session
                if (active == null) {
                    ServersScreen(
                        viewModel = serversViewModel,
                        onConnect = { config ->
                            // No saved token means the bookmark was never
                            // completed; the list surfaces that rather than
                            // opening a workspace that can never authenticate.
                            val token = serversViewModel.tokenFor(config)
                            if (!token.isNullOrEmpty()) {
                                session = ConnectionSession.create(
                                    config = config,
                                    token = token,
                                    settings = environment.settings,
                                    environment = environment,
                                )
                            }
                        },
                    )
                } else {
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
                        // Haptics are a no-op on desktop; passed for API parity.
                        hapticsEnabled = false,
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

    MaterialTheme(colorScheme = colors, content = content)
}

/** The ANSI palette the terminal should use: Omarchy's if present, else built-in. */
fun AppEnvironment.terminalPalette(): IntArray =
    theme?.ansi ?: TerminalPalette.colors

/** Default terminal background/foreground, following the same precedence. */
fun AppEnvironment.terminalDefaults(): Pair<Int, Int> =
    theme?.let { it.foreground to it.background }
        ?: (TerminalPalette.foreground to TerminalPalette.background)
