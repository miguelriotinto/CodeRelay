@file:JvmName("CodeRelay")

package relay.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import relay.session.hub.selectPrevious
import relay.session.hub.selectNext
import relay.session.hub.select
import relay.session.hub.orderedRefs
import relay.session.hub.handleDeepLink
import relay.session.hub.createSession
import relay.session.hub.attachRemote
import relay.protocol.SessionRef
import relay.protocol.SessionDeepLink
import kotlinx.coroutines.flow.combine
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

    // Every enabled server is live in one workspace (multi-server spec §8.5):
    // one hub per process, a coordinator per enabled bookmark.
    val hub = remember(environment) { createLinuxHub(environment) }
    val activeSlot by hub.activeSlot.collectAsState()
    val focusSlot by hub.focusSlot.collectAsState()
    val sections by hub.sections.collectAsState()
    val aggregate by hub.aggregate.collectAsState()
    val hasStarted by hub.hasStarted.collectAsState()
    val current = activeSlot ?: focusSlot

    var windowVisible by remember { mutableStateOf(true) }
    var windowFocused by remember { mutableStateOf(true) }
    var composeWindow by remember { mutableStateOf<java.awt.Window?>(null) }

    // Overlays: settings, server management, the pairing-link paste dialog,
    // the attach sheet, the QR share sheet.
    var showSettings by remember { mutableStateOf(false) }
    var showServers by remember { mutableStateOf(false) }
    var showPasteLink by remember { mutableStateOf(false) }
    var attachable by remember { mutableStateOf<Pair<LinuxServerSlot, List<SessionInfo>>?>(null) }
    var loadingAttachable by remember { mutableStateOf(false) }
    var shareRef by remember { mutableStateOf<SessionRef?>(null) }

    // A pairing link prefills the sheet on the management screen; a
    // new-session request waits for the hub's first start.
    var pendingPairing by remember { mutableStateOf((initialLaunch.link as? DeepLink.Pair)?.url) }
    var pendingNewSession by remember { mutableStateOf(initialLaunch.newSession) }

    // Terminal-side state the hooks feed back: the OSC title of the active
    // session, and the copy/paste request counters the accelerators bump.
    var terminalTitle by remember { mutableStateOf<String?>(null) }
    var pasteRequest by remember { mutableStateOf(0) }
    var copyRequest by remember { mutableStateOf(0) }
    val sidebarToggles = remember { MutableSharedFlow<Unit>(extraBufferCapacity = 4) }

    // The offline→online edge feeding recovery, from the link-state poll.
    val network = remember(environment) { NetworkObserver(environment.connectivity) }

    val serversViewModel = remember {
        ServersViewModel.create(
            store = environment.connections,
            tokenStore = environment.tokens,
            scope = environment.scope,
        )
    }
    val settings = environment.settings
    val fontSizeIsSet by settings.terminalFontSizeIsSet.collectAsState()
    val fontSize by settings.terminalFontSize.collectAsState()
    val scrollbackLines by settings.terminalScrollbackLines.collectAsState()
    val shareScreen by settings.shareScreenWithOptimizer.collectAsState()

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
     * Routes a launch request — the initial argv, a forwarded second launch, or
     * a notification click — into the running UI. A session link goes to the
     * hub, which waits for its first start and routes by the `?server=` hint.
     */
    fun handleLaunch(launch: LaunchArgs) {
        when (val link = launch.link) {
            is DeepLink.Session -> uiScope.launch { hub.handleDeepLink(link.link) }
            is DeepLink.Pair -> {
                pendingPairing = link.url
                showServers = true
            }
            DeepLink.Unhandled -> Unit
        }
        if (launch.newSession) pendingNewSession = true
        raiseWindow()
    }

    /**
     * Attach: fetch the server's attachable sessions, THEN present the sheet,
     * so it opens populated. Gated so a double click fires one fetch.
     */
    fun fetchAttachable(slot: LinuxServerSlot) {
        if (loadingAttachable) return
        loadingAttachable = true
        uiScope.launch {
            attachable = slot to runCatching { slot.coordinator.fetchAttachableSessions() }.getOrDefault(emptyList())
            loadingAttachable = false
        }
    }

    fun quit() {
        environment.notifier.reset()
        // Bounded, and NOT runBlocking: teardown hops to the relay-net dispatcher
        // and resumes on the AWT thread, so blocking that thread here would
        // deadlock until the timeout on every quit. Wait as a coroutine instead.
        uiScope.launch {
            withTimeoutOrNull(1_500) { hub.shutdown() }
            instance.release()
            environment.close()
            exitApplication()
        }
    }

    /** Window-level accelerators; see [AppShortcut] for the Ctrl+Shift/Ctrl+Alt rule. */
    fun handleShortcut(event: KeyEvent): Boolean {
        if (event.type != KeyEventType.KeyDown) return false
        val active = current
        AppShortcut.sessionIndex(event)?.let { index ->
            // Ctrl+Alt+N numbers sessions across servers, like the tabs.
            val target = hub.orderedRefs.getOrNull(index) ?: return true
            uiScope.launch { hub.select(target) }
            return true
        }
        val shortcut = AppShortcut.resolve(event) ?: return false
        when (shortcut) {
            AppShortcut.OPEN_SETTINGS -> showSettings = true
            AppShortcut.ZOOM_IN -> settings.setTerminalFontSize((currentFontPoints(fontSizeIsSet, fontSize) + 1).coerceIn(FONT_MIN, FONT_MAX))
            AppShortcut.ZOOM_OUT -> settings.setTerminalFontSize((currentFontPoints(fontSizeIsSet, fontSize) - 1).coerceIn(FONT_MIN, FONT_MAX))
            AppShortcut.ZOOM_RESET -> settings.clearTerminalFontSize()
            AppShortcut.TOGGLE_SIDEBAR -> sidebarToggles.tryEmit(Unit)
            AppShortcut.NEW_SESSION -> hub.focusServerId.value?.let { id -> uiScope.launch { hub.createSession(id) } }
            AppShortcut.DETACH_CURRENT -> activeSlot?.let { s -> uiScope.launch { s.coordinator.detachActiveSession() } }
            AppShortcut.TERMINATE_CURRENT -> activeSlot?.let { s ->
                val id = s.coordinator.activeSessionId.value ?: return@let
                uiScope.launch { s.coordinator.terminateSession(id) }
            }
            AppShortcut.NEXT_SESSION -> uiScope.launch { hub.selectNext() }
            AppShortcut.PREVIOUS_SESSION -> uiScope.launch { hub.selectPrevious() }
            AppShortcut.COPY -> if (activeSlot?.coordinator?.activeSessionId?.value != null) copyRequest++ else return false
            AppShortcut.PASTE -> if (activeSlot?.coordinator?.activeSessionId?.value != null) pasteRequest++ else return false
            // The wand's accelerator (spec §7.4) — the same entry point as a tap
            // on the WandButton, on purpose. PromptOptimizerController owns the
            // gate and shows the "update / enable the relay" hint itself, so the
            // chord and the tap cannot drift apart.
            AppShortcut.OPTIMIZE_PROMPT -> {
                // Optimize rewrites text the user is composing and its feedback
                // lives on the workspace, so it must not fire while that is
                // covered. Swallowed rather than forwarded — an unhandled
                // Ctrl+Shift+O reaches the terminal as Ctrl+O (zsh accept-line).
                if (showSettings || showServers) return true
                active?.let { s ->
                    uiScope.launch { s.coordinator.optimizePrompt(shareScreen) }
                } ?: return false
            }
        }
        return true
    }

    // ---- Effects that outlive any one connection --------------------------

    LaunchedEffect(hub) { hub.start() }

    // A new-session request (the desktop entry's action) once there is a server.
    LaunchedEffect(pendingNewSession, hasStarted) {
        if (!pendingNewSession || !hasStarted) return@LaunchedEffect
        val id = hub.focusServerId.value ?: return@LaunchedEffect
        pendingNewSession = false
        hub.createSession(id)
    }

    // Network restored → every server, staggered (D10).
    LaunchedEffect(network) {
        network.connectivityRestored.collect { hub.handleForegroundTransition() }
    }

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
    LaunchedEffect(Unit) {
        // Initial argv: a session link is routed by the hub once it has started.
        (initialLaunch.link as? DeepLink.Session)?.let { hub.handleDeepLink(it.link) }
    }

    // A notification click lands on the notifier's thread; hop to the UI. The
    // session id is looked up across servers to find its server.
    SideEffect {
        environment.onNotificationTap = { id ->
            uiScope.launch {
                raiseWindow()
                val serverId = hub.sections.value.firstOrNull { s -> s.sessions.any { it.id == id } }?.id
                if (serverId != null) hub.select(SessionRef(serverId, id)) else hub.handleDeepLink(SessionDeepLink(id))
            }
        }
        environment.focusedSession = {
            if (windowVisible && windowFocused) activeSlot?.coordinator?.activeSessionId?.value else null
        }
    }

    // Desktop notifications from every live server's activity stream (AD-4: no
    // push provider). The notifier diffs one map, so the servers' maps are
    // merged; with several servers each title is prefixed with the server.
    val liveSlots = sections.filter { it.config.enabled }.mapNotNull { section -> hub.slot(section.id)?.let { section to it } }
    LaunchedEffect(liveSlots.map { it.second }) {
        if (liveSlots.isEmpty()) return@LaunchedEffect
        val prefixed = liveSlots.size > 1
        combine(liveSlots.map { (_, slot) -> slot.coordinator.agentStates }) { maps ->
            maps.fold(emptyMap<UUID, relay.protocol.AgentDetectedState>()) { acc, m -> acc + m }
        }.collect { merged ->
            environment.notifier.onAgentStates(merged) { id ->
                val (section, slot) = liveSlots.firstOrNull { (_, sl) -> sl.coordinator.sessionNames.value.containsKey(id) }
                    ?: return@onAgentStates null
                val name = slot.coordinator.sessionNames.value[id] ?: return@onAgentStates null
                if (prefixed) "${section.title} · $name" else name
            }
        }
    }

    // The OSC title belongs to one session; a switch or detach must not leave
    // the previous session's title in the frame.
    LaunchedEffect(current) {
        current?.coordinator?.activeSessionId?.collect { terminalTitle = null } ?: run { terminalTitle = null }
    }

    // Close-to-tray, mirroring the macOS client's menu-bar persistence: a relay
    // client is a thing you leave running, and quitting on window-close would
    // drop every session's connection.
    val palette by environment.themeWatcher.palette.collectAsState()
    val trayModel = rememberTrayModel(hub)
    val focusTitle = sections.firstOrNull { it.id == current?.config?.id }?.title
    Tray(
        icon = remember(palette) {
            TrayIconPainter(palette?.let { Color(it.foreground) } ?: Color.White)
        },
        tooltip = trayModel.tooltip(if (aggregate.enabledServers > 1) null else focusTitle),
        onAction = { raiseWindow() },
        menu = {
            Item(if (windowVisible) "Hide window" else "Show window") {
                if (windowVisible) windowVisible = false else raiseWindow()
            }
            if (aggregate.enabledServers > 0) {
                Separator()
                if (trayModel.sessions.isEmpty()) {
                    Item("No active sessions", enabled = false) {}
                } else {
                    trayModel.sessions.forEach { row ->
                        Item(row.label) {
                            raiseWindow()
                            val serverId = row.serverId ?: return@Item
                            uiScope.launch { hub.select(SessionRef(serverId, row.id)) }
                        }
                    }
                }
                Separator()
                hub.focusServerId.value?.let { id ->
                    Item("New session") {
                        raiseWindow()
                        uiScope.launch { hub.createSession(id) }
                    }
                }
                current?.let { slot ->
                    Item("Attach session…") {
                        raiseWindow()
                        fetchAttachable(slot)
                    }
                }
            }
            Item("Servers…") { raiseWindow(); showServers = true }
            Separator()
            Item("Settings…") { raiseWindow(); showSettings = true }
            Item("Quit $DISPLAY_NAME") { quit() }
        },
    )

    val title = buildString {
        append(DISPLAY_NAME)
        focusTitle?.let { append(" — ").append(it) }
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
        // Returning to a focused window is the desktop's foreground transition.
        LaunchedEffect(focused) { if (focused && hasStarted) hub.handleForegroundTransition() }

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
                    val s = hub.activeSlot.value?.session ?: return@TerminalHooks
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
                    // The workspace stays composed underneath the servers
                    // overlay: un-composing it disposed the live emulator (a
                    // blank pane on return, no replay) and cancelled its effects.
                    WorkspaceScreen(
                        hub = hub,
                        onOpenServers = { showServers = true },
                        onAttach = { slot -> fetchAttachable(slot) },
                        onShareQr = { ref -> shareRef = ref },
                        // The device-side gate on sending the last 40 screen lines
                        // with optimize_prompt (spec §7.1); the relay has its own.
                        shareScreen = shareScreen,
                        // Haptics are a no-op on desktop; passed for API parity.
                        hapticsEnabled = false,
                        sidebarToggleRequests = sidebarToggles,
                    )

                    if (showServers) {
                        ServerList(
                            viewModel = serversViewModel,
                            hub = hub,
                            pendingPairing = pendingPairing,
                            clearPendingPairing = { pendingPairing = null },
                            onOpenSettings = { showSettings = true },
                            onScanPair = { showPasteLink = true },
                            onBack = { showServers = false },
                        )
                    }

                    shareRef?.let { ref ->
                        QrShareSheet(
                            sessionId = ref.sessionId,
                            sessionName = hub.slot(ref.serverId)?.coordinator?.name(ref.sessionId),
                            serverInstanceId = sections.firstOrNull { it.id == ref.serverId }?.config?.instanceId,
                            onDismiss = { shareRef = null },
                        )
                    }

                    attachable?.let { (slot, list) ->
                        AttachSessionSheet(
                            sessions = list,
                            nameFor = { id -> slot.coordinator.name(id) },
                            onAttachSession = { id, name ->
                                attachable = null
                                uiScope.launch { hub.attachRemote(slot.config.id, id, name) }
                            },
                            // The QR scanner is CameraX + ML Kit, excluded from
                            // this build; the sheet's list is the only path in.
                            onScannedSession = {},
                            onDismiss = { attachable = null },
                        )
                    }

                    if (showSettings) {
                        SettingsScreen(
                            settings = settings,
                            appVersion = BuildInfo.VERSION,
                            buildNumber = BuildInfo.BUILD,
                            onDone = { showSettings = false },
                            modifier = Modifier.fillMaxSize(),
                            // No hardware-shortcut capture on this platform; its
                            // toggle would persist a value nothing reads. Haptics
                            // likewise. The optimizer section stays: the desktop
                            // renders the same magic-wand button.
                            visibleSections = setOf(
                                SettingsSection.PROMPT_OPTIMIZER,
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
                                showServers = true
                            },
                            onDismiss = { showPasteLink = false },
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
 * Server management plus the desktop chrome around it: the Settings gear the
 * Android nav graph overlays, and a way back to the workspace once a server is
 * enabled (with none enabled, management IS the workspace).
 */
@Composable
private fun ServerList(
    viewModel: ServersViewModel,
    hub: relay.session.hub.ServerHub<LinuxServerSlot>,
    pendingPairing: PairingURL?,
    clearPendingPairing: () -> Unit,
    onOpenSettings: () -> Unit,
    onScanPair: () -> Unit,
    onBack: () -> Unit,
) {
    Box(modifier = Modifier.fillMaxSize()) {
        ServersScreen(
            viewModel = viewModel,
            hub = hub,
            onDone = onBack,
            modifier = Modifier.fillMaxSize(),
            pendingPairingUrl = pendingPairing,
            clearPendingPairing = clearPendingPairing,
            onScanPair = onScanPair,
        )
        IconButton(
            onClick = onOpenSettings,
            modifier = Modifier.align(Alignment.TopEnd).padding(top = 4.dp, end = 72.dp),
        ) {
            Icon(
                Icons.Filled.Settings,
                contentDescription = "Settings",
                tint = MaterialTheme.colorScheme.onSurface,
            )
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
            // Builds before 2026-09 kept an AWS Bedrock key for the on-device
            // prompt enhancer under TokenStore.BEDROCK_ACCOUNT. The optimizer is
            // a relay feature now, so the secret is deleted on every launch —
            // idempotent, no completion flag, the same rule as Android's speech
            // scrub. Dispatchers.IO because the runner bounds secret-tool at
            // 30 s wall clock, and the coordinators run on Main.immediate.
            scope.launch(Dispatchers.IO) { tokens.deleteBedrockToken() }

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
                settings = AppSettings(prefs = PreferenceStore(scope = scope)),
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
