@file:JvmName("CodeRelay")

package relay.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Tray
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import relay.feature.servers.PastePairingLinkDialog
import relay.feature.servers.ServersScreen
import relay.feature.servers.ServersViewModel
import relay.feature.settings.AppSettings
import relay.feature.settings.PreferenceStore
import relay.feature.settings.SettingsScreen
import relay.feature.settings.SettingsSection
import relay.feature.workspace.QrShareSheet
import relay.feature.workspace.WorkspaceScreen
import relay.feature.workspace.ui.AttachSessionSheet
import relay.feature.workspace.ui.LocalTerminalHooks
import relay.feature.workspace.ui.TerminalHooks
import relay.platform.ActivityNotifier
import relay.platform.DesktopClipboard
import relay.platform.DesktopNotifier
import relay.platform.LinuxConnectivitySource
import relay.platform.OmarchyTheme
import relay.platform.OmarchyThemeWatcher
import relay.protocol.ConnectionConfig
import relay.protocol.PairingURL
import relay.protocol.SessionInfo
import relay.session.NetworkObserver
import relay.storage.DeviceIdentifier
import relay.storage.SavedConnectionStore
import relay.storage.SessionOwnershipStore
import relay.storage.TokenStore
import relay.terminal.TerminalPalette
import relay.terminal.linux.LocalTerminalTheme
import relay.terminal.linux.TerminalTheme
import java.util.UUID
import kotlin.system.exitProcess

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
    val launch = LaunchArgs.parse(args)

    // One instance per user session: a second launch (a coderelay:// click, the
    // "New Session" desktop action) hands its argv to the running app and exits.
    val instance = SingleInstance()
    val claim = runCatching { instance.claim(args.toList()) }.getOrNull()
    if (claim is SingleInstance.Claim.Forwarded) exitProcess(0)

    runApp(launch, (claim as? SingleInstance.Claim.Primary)?.server, instance)
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
const val WM_CLASS = "relay-app-CodeRelay"

/**
 * The user-visible product name.
 *
 * `Code[Relay]` with the brackets, matching `CFBundleDisplayName` on iOS and
 * macOS and `app_name` on Android exactly. The brackets are the brand; dropping
 * them here would make Linux the only client showing a different name.
 */
const val DISPLAY_NAME = "Code[Relay]"

/** Font-size bounds shared with the Settings stepper (8–16 pt). */
private const val FONT_MIN = 8.0
private const val FONT_MAX = 16.0

private fun runApp(
    initialLaunch: LaunchArgs,
    instanceServer: java.nio.channels.ServerSocketChannel?,
    instance: SingleInstance,
) = application {
    val environment = remember { AppEnvironment.create() }
    val windowState = rememberWindowState(
        width = environment.settings.windowWidth.value.coerceAtLeast(600).dp,
        height = environment.settings.windowHeight.value.coerceAtLeast(400).dp,
    )
    val uiScope = rememberCoroutineScope()

    // One live connection at a time, mirroring the Android nav graph's
    // Servers → Workspace transition. Null means "show the server list".
    var session by remember { mutableStateOf<ConnectionSession?>(null) }
    var windowVisible by remember { mutableStateOf(true) }
    var windowFocused by remember { mutableStateOf(true) }
    var composeWindow by remember { mutableStateOf<java.awt.Window?>(null) }

    // In-flight connect (gates double-clicks) and the last failure to report.
    var connecting by remember { mutableStateOf(false) }
    var connectError by remember { mutableStateOf<String?>(null) }

    // Overlays: settings, the server list while connected, the pairing-link
    // paste dialog, the attach sheet, the QR share sheet.
    var showSettings by remember { mutableStateOf(false) }
    var showServers by remember { mutableStateOf(false) }
    var showPasteLink by remember { mutableStateOf(false) }
    var attachableSessions by remember { mutableStateOf<List<SessionInfo>?>(null) }
    var loadingAttachable by remember { mutableStateOf(false) }
    var shareSessionId by remember { mutableStateOf<UUID?>(null) }

    // Deep-link state. A session link is held until a connection exists to
    // attach it to; a pairing link prefills the sheet on the server list.
    var pendingSessionId by remember { mutableStateOf((initialLaunch.link as? DeepLink.Session)?.id) }
    var pendingPairing by remember { mutableStateOf((initialLaunch.link as? DeepLink.Pair)?.url) }
    var pendingNewSession by remember { mutableStateOf(initialLaunch.newSession) }

    // Terminal-side state the hooks feed back: the OSC title of the active
    // session, and the copy/paste request counters the accelerators bump.
    var terminalTitle by remember { mutableStateOf<String?>(null) }
    var pasteRequest by remember { mutableStateOf(0) }
    var copyRequest by remember { mutableStateOf(0) }
    val sidebarToggles = remember { MutableSharedFlow<Unit>(extraBufferCapacity = 4) }

    // The offline→online edge feeding recovery, from the link-state poll. Only
    // the edge matters, so one observer is shared by every connection.
    val network = remember(environment) { NetworkObserver(environment.connectivity) }

    val serversViewModel = remember {
        ServersViewModel.create(
            store = environment.connections,
            tokenStore = environment.tokens,
            scope = environment.scope,
        )
    }
    val servers by serversViewModel.servers.collectAsState()
    val settings = environment.settings
    val fontSizeIsSet by settings.terminalFontSizeIsSet.collectAsState()
    val fontSize by settings.terminalFontSize.collectAsState()
    val scrollbackLines by settings.terminalScrollbackLines.collectAsState()

    fun raiseWindow() {
        windowVisible = true
        composeWindow?.let { w ->
            runCatching {
                w.toFront()
                w.requestFocus()
            }
        }
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
            settings = settings,
            environment = environment,
        )
        candidate.scope.launch {
            val failure = runCatching { candidate.coordinator.connect() }.exceptionOrNull()
            if (failure == null) {
                // Switching servers from the overlay: the old connection is
                // dropped only once the new one is up, so a failed switch
                // leaves the working session untouched.
                session?.let { old ->
                    environment.notifier.reset()
                    old.close()
                }
                session = candidate
                showServers = false
                terminalTitle = null
                settings.setLastConnectedServerId(config.id.toString())
            } else {
                candidate.close()
                connectError = "Couldn't connect to ${config.name}: " +
                    (failure.message ?: failure::class.simpleName ?: "unknown error")
            }
            connecting = false
        }
    }

    /** The bookmark auto-connect and a session link fall back to. */
    fun lastConnectedServer(): ConnectionConfig? {
        val id = settings.lastConnectedServerId.value
        return servers.firstOrNull { it.id.toString() == id }
    }

    /**
     * Routes a launch request — the initial argv, a forwarded second launch, or
     * a notification click — into the running UI.
     */
    fun handleLaunch(launch: LaunchArgs) {
        when (val link = launch.link) {
            is DeepLink.Session -> pendingSessionId = link.id
            is DeepLink.Pair -> {
                pendingPairing = link.url
                if (session != null) showServers = true
            }
            DeepLink.Unhandled -> Unit
        }
        if (launch.newSession) pendingNewSession = true
        // A session link or a new-session request with nothing connected: open
        // the last server, which is the one the link almost certainly refers to.
        if (session == null && !connecting && (pendingSessionId != null || pendingNewSession)) {
            lastConnectedServer()?.let(::connectTo)
        }
        raiseWindow()
    }

    /**
     * Attach: fetch the token's attachable sessions, THEN present the sheet, so
     * it opens populated (the order the Android nav graph and iOS both use).
     * Gated so a double click fires one fetch.
     */
    fun fetchAttachable(active: ConnectionSession) {
        if (loadingAttachable) return
        loadingAttachable = true
        active.scope.launch {
            attachableSessions = runCatching { active.coordinator.fetchAttachableSessions() }
                .getOrDefault(emptyList())
            loadingAttachable = false
        }
    }

    fun disconnect() {
        environment.notifier.reset()
        session?.close()
        session = null
        terminalTitle = null
    }

    fun quit() {
        environment.notifier.reset()
        val closing = session
        session = null
        // Bounded, and NOT runBlocking: teardown hops to the relay-net dispatcher
        // and resumes on the AWT thread, so blocking that thread here would
        // deadlock until the timeout on every quit. Wait as a coroutine instead.
        uiScope.launch {
            closing?.let { withTimeoutOrNull(1_500) { it.close().join() } }
            instance.release()
            environment.close()
            exitApplication()
        }
    }

    /** Window-level accelerators; see [AppShortcut] for the Ctrl+Shift/Ctrl+Alt rule. */
    fun handleShortcut(event: KeyEvent): Boolean {
        if (event.type != KeyEventType.KeyDown) return false
        val active = session
        AppShortcut.sessionIndex(event)?.let { index ->
            val target = active?.coordinator?.activeSessions?.value?.getOrNull(index) ?: return true
            active.scope.launch { active.coordinator.switchToSession(target.id) }
            return true
        }
        val shortcut = AppShortcut.resolve(event) ?: return false
        when (shortcut) {
            AppShortcut.OPEN_SETTINGS -> showSettings = true
            AppShortcut.ZOOM_IN -> settings.setTerminalFontSize((currentFontPoints(fontSizeIsSet, fontSize) + 1).coerceIn(FONT_MIN, FONT_MAX))
            AppShortcut.ZOOM_OUT -> settings.setTerminalFontSize((currentFontPoints(fontSizeIsSet, fontSize) - 1).coerceIn(FONT_MIN, FONT_MAX))
            AppShortcut.ZOOM_RESET -> settings.clearTerminalFontSize()
            AppShortcut.TOGGLE_SIDEBAR -> sidebarToggles.tryEmit(Unit)
            AppShortcut.NEW_SESSION -> active?.let { s -> s.scope.launch { s.coordinator.createNewSession() } }
            AppShortcut.DETACH_CURRENT -> active?.let { s -> s.scope.launch { s.coordinator.detachActiveSession() } }
            AppShortcut.TERMINATE_CURRENT -> active?.let { s ->
                val id = s.coordinator.activeSessionId.value ?: return@let
                s.scope.launch { s.coordinator.terminateSession(id) }
            }
            AppShortcut.NEXT_SESSION, AppShortcut.PREVIOUS_SESSION -> active?.let { s ->
                val list = s.coordinator.activeSessions.value
                if (list.isEmpty()) return@let
                val current = list.indexOfFirst { it.id == s.coordinator.activeSessionId.value }
                val step = if (shortcut == AppShortcut.NEXT_SESSION) 1 else -1
                val next = if (current < 0) 0 else Math.floorMod(current + step, list.size)
                s.scope.launch { s.coordinator.switchToSession(list[next].id) }
            }
            AppShortcut.COPY -> if (active?.coordinator?.activeSessionId?.value != null) copyRequest++ else return false
            AppShortcut.PASTE -> if (active?.coordinator?.activeSessionId?.value != null) pasteRequest++ else return false
        }
        return true
    }

    // ---- Effects that outlive any one connection --------------------------

    // Forwarded launches from a second process (see SingleInstance).
    LaunchedEffect(instanceServer) {
        val server = instanceServer ?: return@LaunchedEffect
        val thread = Thread({
            while (server.isOpen) {
                val accepted = runCatching { server.accept() }.getOrNull()
                if (accepted == null) {
                    // EMFILE or a transient error: never spin the thread hot.
                    Thread.sleep(200)
                    continue
                }
                // readLaunch closes the channel and is deadline-bounded, so one
                // peer that never finishes cannot hold the accept loop.
                val args = runCatching { SingleInstance.readLaunch(accepted) }.getOrDefault(emptyList())
                // An empty launch is a bare relaunch: just raise the window.
                environment.forwarded.tryEmit(LaunchArgs.parse(args))
            }
        }, "coderelay-instance").apply { isDaemon = true }
        thread.start()
    }
    LaunchedEffect(Unit) {
        environment.forwarded.collect { launch -> handleLaunch(launch) }
    }

    // A notification click lands on the notifier's thread; hop to the UI.
    SideEffect {
        environment.onNotificationTap = { id ->
            uiScope.launch { handleLaunch(LaunchArgs(link = DeepLink.Session(id))) }
        }
        environment.focusedSession = {
            if (windowVisible && windowFocused) session?.coordinator?.activeSessionId?.value else null
        }
    }

    // Auto-connect on launch (RelayNavGraph's autoConnectConfig), once the
    // bookmark list has loaded. Fires at most once; a session link in argv also
    // connects, regardless of the toggle — the user asked for that session.
    var autoConnectTried by remember { mutableStateOf(false) }
    LaunchedEffect(servers) {
        if (autoConnectTried || session != null || servers.isEmpty()) return@LaunchedEffect
        autoConnectTried = true
        val wantsConnection = settings.autoConnectEnabled.value || pendingSessionId != null || pendingNewSession
        if (wantsConnection) lastConnectedServer()?.let(::connectTo)
    }

    // Close-to-tray, mirroring the macOS client's menu-bar persistence: a relay
    // client is a thing you leave running, and quitting on window-close would
    // drop every session's connection.
    val palette by environment.themeWatcher.palette.collectAsState()
    val trayModel = rememberTrayModel(session)
    Tray(
        icon = remember(palette) {
            TrayIconPainter(palette?.let { Color(it.foreground) } ?: Color.White)
        },
        tooltip = trayModel.tooltip(session?.config?.name),
        onAction = { raiseWindow() },
        menu = {
            Item(if (windowVisible) "Hide window" else "Show window") {
                if (windowVisible) windowVisible = false else raiseWindow()
            }
            val active = session
            if (active != null) {
                Separator()
                if (trayModel.sessions.isEmpty()) {
                    Item("No active sessions", enabled = false) {}
                } else {
                    trayModel.sessions.forEach { row ->
                        Item(row.label) {
                            raiseWindow()
                            active.scope.launch { active.coordinator.switchToSession(row.id) }
                        }
                    }
                }
                Separator()
                Item("New session") {
                    raiseWindow()
                    active.scope.launch { active.coordinator.createNewSession() }
                }
                Item("Attach session…") {
                    raiseWindow()
                    fetchAttachable(active)
                }
                Item("Servers…") { raiseWindow(); showServers = true }
                Item("Disconnect") { disconnect() }
            }
            Separator()
            Item("Settings…") { raiseWindow(); showSettings = true }
            Item("Quit $DISPLAY_NAME") { quit() }
        },
    )

    val title = buildString {
        append(DISPLAY_NAME)
        session?.let { append(" — ").append(it.config.name) }
        terminalTitle?.takeIf { it.isNotBlank() }?.let { append(" — ").append(it) }
    }

    Window(
        visible = windowVisible,
        onCloseRequest = {
            // Hide rather than exit; Quit in the tray menu is the real exit.
            windowVisible = false
        },
        state = windowState,
        title = title,
        onPreviewKeyEvent = ::handleShortcut,
    ) {
        val focused = LocalWindowInfo.current.isWindowFocused
        SideEffect {
            composeWindow = window
            windowFocused = focused
        }
        // Remember the window size across launches (a floating-window setup;
        // under a tiling WM the compositor decides and this is harmless).
        LaunchedEffect(windowState.size) {
            settings.setWindowSize(windowState.size.width.value.toInt(), windowState.size.height.value.toInt())
        }

        val hooks = remember(scrollbackLines, fontSizeIsSet, fontSize, pasteRequest, copyRequest) {
            TerminalHooks(
                // Active session only: this host exists only for the active
                // pane, so a background session's copy cannot reach here — the
                // same rule the server applies to clipboard_update.
                // Fired on the relay-net thread from feedOutput: the clipboard
                // spawns wl-copy (IO), and the title is Compose state (UI).
                onClipboardCopy = { text -> environment.scope.launch { environment.clipboard.setText(text) } },
                onTitleChange = { title -> uiScope.launch { terminalTitle = title } },
                onBell = { runCatching { java.awt.Toolkit.getDefaultToolkit().beep() } },
                sendPasteImage = { png ->
                    val s = session ?: return@TerminalHooks
                    s.scope.launch {
                        runCatching { s.connection.sendPasteImage(java.util.Base64.getEncoder().encodeToString(png)) }
                    }
                },
                scrollbackLines = scrollbackLines,
                fontPointsOverride = if (fontSizeIsSet) fontSize.toFloat() else null,
                pasteRequest = pasteRequest,
                copyRequest = copyRequest,
                onSelectionCopied = { text -> environment.scope.launch { environment.clipboard.setText(text) } },
                clipboard = environment.clipboard,
            )
        }

        RelayTheme(palette) {
            CompositionLocalProvider(LocalTerminalHooks provides hooks) {
                Surface(modifier = Modifier.fillMaxSize()) {
                    val active = session
                    if (active == null) {
                        ServerList(
                            viewModel = serversViewModel,
                            connecting = connecting,
                            pendingPairing = pendingPairing,
                            clearPendingPairing = { pendingPairing = null },
                            onConnect = ::connectTo,
                            onOpenSettings = { showSettings = true },
                            onScanPair = { showPasteLink = true },
                            onBack = null,
                        )
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
                        LaunchedEffect(active, pendingNewSession) {
                            if (!pendingNewSession) return@LaunchedEffect
                            pendingNewSession = false
                            runCatching { active.coordinator.createNewSession() }
                        }
                        // The OSC title belongs to one session; a switch or detach
                        // must not leave the previous session's title in the frame.
                        LaunchedEffect(active) {
                            active.coordinator.activeSessionId.collect { terminalTitle = null }
                        }
                        // Desktop notifications from the activity stream the
                        // coordinator already receives (AD-4: no push provider).
                        LaunchedEffect(active) {
                            active.coordinator.agentStates.collect { states ->
                                environment.notifier.onAgentStates(states) { id ->
                                    active.coordinator.sessionNames.value[id]
                                }
                            }
                        }
                        // The workspace stays composed underneath the servers
                        // overlay: un-composing it disposed the live emulator (a
                        // blank pane on return, no replay) and cancelled the
                        // notification and recovery effects while it was open.
                        WorkspaceScreen(
                            vm = active.workspaceViewModel,
                            onDisconnect = ::disconnect,
                            // Attach: fetch the token's attachable sessions, THEN
                            // present the sheet, so it opens populated (the order
                            // the Android nav graph and iOS both use). Gated on
                            // `loadingAttachable` so a double click fires one fetch.
                            onAttach = { fetchAttachable(active) },
                            onShareQr = { id -> shareSessionId = id },
                            // Haptics are a no-op on desktop; passed for API parity.
                            hapticsEnabled = false,
                            sidebarToggleRequests = sidebarToggles,
                        )

                        if (showServers) {
                            ServerList(
                                viewModel = serversViewModel,
                                connecting = connecting,
                                pendingPairing = pendingPairing,
                                clearPendingPairing = { pendingPairing = null },
                                onConnect = ::connectTo,
                                onOpenSettings = { showSettings = true },
                                onScanPair = { showPasteLink = true },
                                onBack = { showServers = false },
                            )
                        }

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
                    if (showSettings) {
                        SettingsScreen(
                            settings = settings,
                            appVersion = BuildInfo.VERSION,
                            buildNumber = BuildInfo.BUILD,
                            onDone = { showSettings = false },
                            modifier = Modifier.fillMaxSize(),
                            // No speech engine and no recording shortcut on this
                            // platform; their toggles would persist values nothing
                            // reads. Haptics likewise.
                            visibleSections = setOf(
                                SettingsSection.CONNECTION,
                                SettingsSection.GENERAL,
                                SettingsSection.ABOUT,
                            ),
                            hapticFeedbackAvailable = false,
                        )
                    }

                    if (showPasteLink) {
                        PastePairingLinkDialog(
                            onParsed = { url ->
                                showPasteLink = false
                                pendingPairing = url
                            },
                            onDismiss = { showPasteLink = false },
                        )
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
}

/** The effective font size in points for the zoom keys. */
private fun currentFontPoints(isSet: Boolean, setting: Double): Double =
    if (isSet) setting else relay.terminal.linux.DesktopTerminalFont.load().points.toDouble()

/**
 * The server list plus the desktop chrome around it: the Settings gear the
 * Android nav graph overlays, the connecting scrim, and — when opened from a
 * live workspace — a way back.
 */
@Composable
private fun ServerList(
    viewModel: ServersViewModel,
    connecting: Boolean,
    pendingPairing: PairingURL?,
    clearPendingPairing: () -> Unit,
    onConnect: (ConnectionConfig) -> Unit,
    onOpenSettings: () -> Unit,
    onScanPair: () -> Unit,
    onBack: (() -> Unit)?,
) {
    Box(modifier = Modifier.fillMaxSize()) {
        ServersScreen(
            viewModel = viewModel,
            onConnect = onConnect,
            modifier = Modifier.fillMaxSize(),
            pendingPairingUrl = pendingPairing,
            clearPendingPairing = clearPendingPairing,
            onScanPair = onScanPair,
        )
        androidx.compose.foundation.layout.Row(
            modifier = Modifier.align(Alignment.TopEnd).padding(4.dp),
        ) {
            if (onBack != null) {
                TextButton(onClick = onBack) { Text("Back to workspace") }
            }
            IconButton(onClick = onOpenSettings) {
                Icon(
                    Icons.Filled.Settings,
                    contentDescription = "Settings",
                    tint = MaterialTheme.colorScheme.onSurface,
                )
            }
        }
        if (connecting) {
            // The handshake owns the window until it settles, so a second click
            // cannot start a competing connection.
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.4f)),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator()
            }
        }
    }
}

/**
 * The Linux platform bindings, constructed once at startup.
 *
 * Deliberately a plain object graph rather than a DI framework: there are a
 * handful of dependencies and one construction site, so a container would add
 * indirection without removing any wiring.
 */
class AppEnvironment private constructor(
    val scope: CoroutineScope,
    val connections: SavedConnectionStore,
    val tokens: TokenStore,
    val ownership: SessionOwnershipStore,
    val deviceId: String,
    val connectivity: LinuxConnectivitySource,
    val notifier: ActivityNotifier,
    val themeWatcher: OmarchyThemeWatcher,
    val settings: AppSettings,
    val clipboard: DesktopClipboard,
) {
    /** Forwarded launches from a second process; the UI collects these. */
    val forwarded = MutableSharedFlow<LaunchArgs>(extraBufferCapacity = 8)

    /** Set by the UI: the session the user is looking at (null when the window is away). */
    @Volatile
    var focusedSession: () -> UUID? = { null }

    /** Set by the UI: what a notification click should do. */
    @Volatile
    var onNotificationTap: (UUID) -> Unit = {}

    /** Stops background work. Called on quit. */
    fun close() {
        runCatching { connectivity.stop() }
        runCatching { themeWatcher.stop() }
        runCatching { scope.cancel() }
    }

    companion object {
        fun create(): AppEnvironment {
            // SupervisorJob so one failing collector cannot cancel the others —
            // a notification failure must not take down the connectivity watch.
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val deviceId = DeviceIdentifier.get()
            val tokens = TokenStore()

            lateinit var environment: AppEnvironment
            environment = AppEnvironment(
                scope = scope,
                connections = SavedConnectionStore(),
                tokens = tokens,
                ownership = SessionOwnershipStore(deviceId = deviceId),
                deviceId = deviceId,
                connectivity = LinuxConnectivitySource(scope),
                notifier = ActivityNotifier(
                    sender = DesktopNotifier(onActivated = { id -> environment.onNotificationTap(id) }),
                    focusedSession = { environment.focusedSession() },
                ),
                // Absent on a non-Omarchy desktop; the terminal then keeps
                // TerminalPalette's built-in colours.
                themeWatcher = OmarchyThemeWatcher(scope),
                settings = AppSettings(
                    prefs = PreferenceStore(scope = scope),
                    tokenStore = tokens,
                    scope = scope,
                ),
                clipboard = DesktopClipboard(),
            )
            return environment
        }
    }
}

/**
 * Applies the Omarchy palette to the app chrome, falling back to a dark scheme.
 *
 * The terminal grid gets its colours separately, straight from the same palette
 * via `LinuxTerminalEmulator.applyPalette` — the two must not drift, which is
 * why both read the watcher's palette rather than each deriving their own.
 */
@Composable
private fun RelayTheme(palette: OmarchyTheme.Palette?, content: @Composable () -> Unit) {
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
    // palette — so publish it alongside, from the SAME palette the chrome above
    // is built from. Without this the grid fell back to its built-in
    // white-on-black while every other window on the desktop wore the Omarchy
    // palette, which is what made the relayed terminal read as a different
    // application rather than another terminal.
    val terminalTheme = remember(palette) {
        val (fg, bg) = terminalDefaultsFor(palette)
        TerminalTheme(
            ansi = palette?.ansi ?: TerminalPalette.colors,
            foreground = fg,
            background = bg,
            selection = palette?.selection,
        )
    }

    CompositionLocalProvider(LocalTerminalTheme provides terminalTheme) {
        MaterialTheme(colorScheme = colors, content = content)
    }
}

/** Default terminal foreground/background: Omarchy's if present, else built-in. */
private fun terminalDefaultsFor(palette: OmarchyTheme.Palette?): Pair<Int, Int> =
    palette?.let { it.foreground to it.background }
        ?: (TerminalPalette.foreground to TerminalPalette.background)
