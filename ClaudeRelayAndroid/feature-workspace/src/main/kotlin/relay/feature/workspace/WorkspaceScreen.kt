package relay.feature.workspace

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DismissibleDrawerSheet
import androidx.compose.material3.DismissibleNavigationDrawer
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.rememberDrawerState
import androidx.compose.material3.DrawerValue
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch
import relay.feature.workspace.ui.ConnectionQualityDot
import relay.feature.workspace.ui.SessionSidebar
import relay.feature.workspace.ui.SessionTabs
import relay.feature.workspace.ui.TerminalHost
import relay.feature.workspace.ui.WorkspaceLogic
import relay.session.RecoveryPhase
import relay.session.SessionHandshake
import relay.terminal.KeyboardAccessory
import java.util.UUID

/** Material3 "expanded" width breakpoint — width ≥ this gets the two-pane layout. */
private val EXPANDED_WIDTH_BREAKPOINT = 840.dp

// Per-event leftward drag (px) on the two-pane sidebar that triggers a hide. Small
// so a deliberate swipe-left closes the pane promptly, but above stray jitter.
private const val SWIPE_CLOSE_THRESHOLD_PX = 8f

// Top-toolbar controls share the SessionTab "1" chip footprint so they're uniform
// with the tab: 26x22dp min, 6dp corners, ~14dp icon. (The default IconButton 48dp
// was far larger than the tab.)
private val TOOLBAR_CHIP_MIN_WIDTH = 26.dp
private val TOOLBAR_CHIP_MIN_HEIGHT = 22.dp
private val TOOLBAR_ICON = 14.dp
private val TOOLBAR_CHIP_SHAPE = RoundedCornerShape(6.dp)

/**
 * The workspace screen — the adaptive split host, ported from `WorkspaceView.swift`.
 *
 * ## Adaptive layout ([BoxWithConstraints] width vs the 840 dp breakpoint)
 * The width class is derived from the available `maxWidth` against the standard
 * Material3 "expanded" breakpoint (840 dp). We compute it ourselves rather than
 * pull `androidx.window`'s `WindowSizeClass` — the `WindowSizeClass.compute`
 * core-layout class is NOT in `androidx.window:window:1.3.0` (it lives in the
 * separate `window-core` artifact), and `material3.adaptive`'s
 * `currentWindowAdaptiveInfo()` couples the adaptive version to the Compose BOM.
 * A `BoxWithConstraints` breakpoint resolves cleanly with ZERO extra dependency
 * and matches the iOS `horizontalSizeClass` split point.
 *  - **Expanded** (tablet/foldable, width ≥ 840 dp): a two-pane [Row] —
 *    [SessionSidebar] fixed at 320 dp on the left, the terminal column on the
 *    right ([SessionTabs] + [TerminalHost] + the status bar). Mirrors the Swift
 *    `NavigationSplitView` branch.
 *  - **Compact/Medium** (phone): the terminal column full-screen with the sidebar
 *    behind a [ModalNavigationDrawer] toggled from the status bar. Mirrors the
 *    Swift `sizeClass == .compact` sheet branch.
 *
 * ## Recovery overlay
 * When [SessionCoordinator.isRecovering] is true a full-screen scrim with a
 * [CircularProgressIndicator], the phase label ([phaseLabel]), and a Cancel
 * button is shown over everything (Swift `RecoveryOverlay` sheet with
 * `interactiveDismissDisabled`). A [BackHandler] swallows the system back press
 * while recovering — the Compose analog of `interactiveDismissDisabled()`.
 * Separately, [SessionCoordinator.connectionTimedOut] surfaces a "Connection
 * Lost" [AlertDialog] with a Retry (re-trigger recovery) and a Disconnect.
 *
 * All session/recovery/activity state is collected via
 * [collectAsStateWithLifecycle]; session ops are launched on a screen
 * [rememberCoroutineScope] (the coordinator's ops are suspend funcs).
 *
 * @param vm the [WorkspaceViewModel] wrapping the coordinator + quality/uptime flows
 * @param onDisconnect leave the workspace (Swift `dismiss()`) — wired by the nav host
 * @param onAttach open the attach-session flow (the Swift `AttachSessionSheet` +
 *   QR scanner) — stubbed in M2, wired in Task 9
 * @param onShareQr stubbed in M2; the QR sheet is wired in Task 9
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun WorkspaceScreen(
    vm: WorkspaceViewModel,
    onDisconnect: () -> Unit,
    onAttach: () -> Unit = {},
    onShareQr: (UUID) -> Unit = {},
    /**
     * Speech mic-button slot, placed in the terminal status row. `:app` supplies
     * the real [MicButton] (constructing the device-deferred PTT / continuous
     * engines + the model store) and wires `onUtteranceReady → vm.sendInput(text)`.
     * Defaults to empty so the screen renders without speech (e.g. in previews /
     * before the engines are wired).
     */
    micButton: @Composable () -> Unit = {},
    /**
     * `AppSettings.hapticFeedbackEnabled` — gates the `.light`-impact tap haptics
     * the iOS status bar / session tabs / key bar fire (`ActiveTerminalView.swift`
     * + `KeyboardAccessory.swift`). Defaults to false so previews stay silent.
     */
    hapticsEnabled: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val coordinator = vm.coordinator
    val scope = rememberCoroutineScope()
    val haptics = rememberHaptics(hapticsEnabled)

    // The tab bar and sidebar render the FILTERED + SORTED active-session list
    // (non-terminal sessions this device owns, sorted by createdAt), matching the
    // iOS `coordinator.activeSessions` the SwiftUI sidebar/tabs consume — NOT the
    // raw `coordinator.sessions`.
    val sessions by coordinator.activeSessions.collectAsStateWithLifecycle()
    val activeSessionId by coordinator.activeSessionId.collectAsStateWithLifecycle()
    val sessionNames by coordinator.sessionNames.collectAsStateWithLifecycle()
    val agentSessions by coordinator.agentSessions.collectAsStateWithLifecycle()
    val awaitingInput by coordinator.sessionsAwaitingInput.collectAsStateWithLifecycle()
    val isLoading by coordinator.isLoading.collectAsStateWithLifecycle()
    // The launch/wake handshake owns its own auth + list RPC, so it does NOT go
    // through `isLoading`. Folded into the refresh indicator below so the sidebar
    // shows a spinner while it runs instead of a bare "no sessions" empty state.
    val isHandshaking by coordinator.isPerformingHandshake.collectAsStateWithLifecycle()

    val isRecovering by coordinator.isRecovering.collectAsStateWithLifecycle()
    val recoveryPhase by coordinator.recoveryPhase.collectAsStateWithLifecycle()
    val connectionTimedOut by coordinator.connectionTimedOut.collectAsStateWithLifecycle()
    // "Cannot Open Session" alert — raised on an app-level restore failure (the
    // connection is fine but the session couldn't be resumed; iOS
    // WorkspaceView.swift:161-167). Without surfacing this, a failed recovery
    // restore leaves a blank terminal with zero explanation.
    val sessionAttachFailed by coordinator.sessionAttachFailed.collectAsStateWithLifecycle()
    // "Session Moved" alert — raised when the active session is attached away by
    // another device (iOS WorkspaceView.swift:168-181). Without surfacing this the
    // session just vanishes to "No Active Session" with no explanation.
    val stolenAlert by coordinator.stolenAlert.collectAsStateWithLifecycle()

    val quality by vm.connectionQuality.collectAsStateWithLifecycle()
    val uptimeSeconds by vm.uptimeSeconds.collectAsStateWithLifecycle()

    val agentStates by coordinator.agentStates.collectAsStateWithLifecycle()
    val unseenSessions by coordinator.unseenSessions.collectAsStateWithLifecycle()

    fun nameFor(id: UUID): String = sessionNames[id] ?: id.toString().take(8)
    fun agentFor(id: UUID): String? = agentSessions[id]
    fun activityFor(id: UUID): relay.protocol.ActivityState =
        coordinator.activityCoordinator.activityState(id)
    fun agentStateFor(id: UUID): relay.protocol.AgentDetectedState? = agentStates[id]
    fun seenFor(id: UUID): Boolean = id !in unseenSessions

    var showKeyBar by remember { mutableStateOf(true) }
    var renameActive by remember { mutableStateOf(false) }
    // Bumped when the user taps the session-name badge. Threaded into
    // [TerminalHost], which drives a local full-grid damage repaint. The primary
    // fix for glyph overlap is the server-side refresh sent alongside it
    // (SIGWINCH → the running app re-emits its screen); this local repaint is
    // belt-and-suspenders for renderer-only staleness.
    var redrawToken by remember { mutableStateOf(0) }

    val drawerState = rememberDrawerState(DrawerValue.Closed)
    // Two-pane (fold-open / tablet) drawer. DismissibleNavigationDrawer renders the
    // sidebar inline (persistent pane look) but, unlike the bespoke Row +
    // AnimatedVisibility it replaces, ships built-in swipe-to-close/open gesture
    // handling — so the user can swipe the pane away on a fold-open screen just like
    // the ModalNavigationDrawer allows in the compact branch. Starts open.
    val twoPaneDrawerState = rememberDrawerState(DrawerValue.Open)

    val sidebar: @Composable () -> Unit = {
        SessionSidebar(
            sessions = sessions,
            activeSessionId = activeSessionId,
            nameForSession = ::nameFor,
            agentForSession = ::agentFor,
            activityForSession = ::activityFor,
            agentStateForSession = ::agentStateFor,
            seenForSession = ::seenFor,
            // Build rollups from the collected agentStates/unseenSessions so the
            // grouping recomposes when live state changes (parity with iOS).
            rollupsForSessions = { list ->
                relay.protocol.WorkspaceRollup.group(
                    sessions = list,
                    agentStates = agentStates,
                    unseen = unseenSessions,
                    groupKey = { it.workingDir ?: "~" },
                    title = { if (it == "~") "Other" else it.substringAfterLast('/') },
                )
            },
            isRefreshing = isLoading || isHandshaking,
            // Pull-to-refresh is an entry into a live workspace like any other, so
            // it runs the WHOLE contract — reconnect if needed, authenticate, then
            // ask for the sessions we own — rather than a bare list fetch that
            // silently no-ops on a socket that died in the background. WAKE, so a
            // session taken elsewhere meanwhile is reported.
            onRefresh = { scope.launch { coordinator.performHandshake(SessionHandshake.Reason.WAKE) } },
            onNewSession = { scope.launch { coordinator.createNewSession() } },
            onAttach = onAttach,
            onSelect = { id ->
                scope.launch {
                    coordinator.switchToSession(id)
                    drawerState.close()
                }
            },
            onRename = { id, name -> scope.launch { coordinator.renameSession(id, name) } },
            onTerminate = { id -> scope.launch { coordinator.terminateSession(id) } },
            onShareQr = onShareQr,
            modifier = Modifier.background(MaterialTheme.colorScheme.surface),
        )
    }

    val terminalColumn: @Composable (onToggleSidebar: () -> Unit, twoPane: Boolean) -> Unit =
        { onToggleSidebar, twoPane ->
            TerminalColumn(
                vm = vm,
                sessions = sessions,
                activeSessionId = activeSessionId,
                agentFor = ::agentFor,
                agentStateFor = ::agentStateFor,
                awaitingInput = awaitingInput,
                quality = quality,
                uptimeSeconds = uptimeSeconds,
                showKeyBar = showKeyBar,
                showSidebarToggle = !twoPane,
                // Each of these fires the iOS `.light` impact haptic (ActiveTerminalView's
                // ToolbarIconButton / keyboard toggle / tab button) before its action.
                onToggleSidebar = { haptics.lightTap(); onToggleSidebar() },
                onToggleKeyBar = { haptics.lightTap(); showKeyBar = !showKeyBar },
                onDisconnect = { haptics.lightTap(); onDisconnect() },
                onSelectTab = { id -> haptics.lightTap(); scope.launch { coordinator.switchToSession(id) } },
                onInput = { bytes -> vm.sendInput(bytes) },
                onResize = { cols, rows -> vm.sendResize(cols, rows) },
                onShareQr = { id -> haptics.lightTap(); onShareQr(id) },
                // Tap → server-side refresh (SIGWINCH → the running app re-emits
                // its screen — the same replay the keyboard toggle triggers via
                // resize) plus a local damage repaint as belt-and-suspenders.
                onNameTap = { haptics.lightTap(); vm.sendRefresh(); redrawToken++ },
                onNameLongPress = { renameActive = true },
                onKeyHaptic = { haptics.lightTap() },
                nameFor = ::nameFor,
                micButton = micButton,
                redrawToken = redrawToken,
            )
        }

    Box(modifier = modifier.fillMaxSize()) {
        BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
            // Material3 "expanded" breakpoint: width ≥ 840 dp gets the two-pane
            // layout (same split point the iOS horizontalSizeClass uses).
            val expanded = maxWidth >= EXPANDED_WIDTH_BREAKPOINT

            if (expanded) {
                // Fold-open / tablet: an inline, persistent-looking sidebar pane that
                // is ALSO swipe-dismissible (DismissibleNavigationDrawer's built-in
                // gesture). The menu-button toggle flips the same drawerState, so both
                // swipe and tap hide/show the pane — matching the compact branch's
                // ModalNavigationDrawer behaviour the user expects.
                DismissibleNavigationDrawer(
                    drawerState = twoPaneDrawerState,
                    gesturesEnabled = true,
                    drawerContent = {
                        DismissibleDrawerSheet(
                            drawerContainerColor = MaterialTheme.colorScheme.surface,
                        ) {
                            // Explicit left-swipe-to-close on the pane itself.
                            // DismissibleNavigationDrawer's built-in drag region is
                            // unreliable here (the terminal pane swallows horizontal
                            // drags and the open pane has no scrim to grab), so a
                            // leftward drag on the sidebar reliably hides it — matching
                            // the compact ModalNavigationDrawer swipe the user expects.
                            Box(
                                modifier = Modifier
                                    .width(320.dp)
                                    .fillMaxHeight()
                                    .pointerInput(Unit) {
                                        detectHorizontalDragGestures { _, dragAmount ->
                                            if (dragAmount < -SWIPE_CLOSE_THRESHOLD_PX) {
                                                scope.launch { twoPaneDrawerState.close() }
                                            }
                                        }
                                    },
                            ) { sidebar() }
                        }
                    },
                ) {
                    Box(modifier = Modifier.fillMaxSize()) {
                        terminalColumn(
                            {
                                scope.launch {
                                    if (twoPaneDrawerState.isOpen) twoPaneDrawerState.close()
                                    else twoPaneDrawerState.open()
                                }
                            },
                            false,
                        )
                    }
                }
            } else {
                ModalNavigationDrawer(
                    drawerState = drawerState,
                    drawerContent = {
                        Box(modifier = Modifier.width(320.dp).fillMaxHeight()) { sidebar() }
                    },
                ) {
                    terminalColumn({ scope.launch { drawerState.open() } }, false)
                }
            }
        }

        // Recovery overlay — modal scrim over everything while recovering.
        if (isRecovering) {
            BackHandler(enabled = true) { /* suppress back-dismiss during recovery */ }
            RecoveryOverlay(
                phase = recoveryPhase,
                onCancel = { coordinator.cancelRecovery() },
            )
        }
    }

    // Auto-open the drawer on first load when there is no active session, so the
    // user lands on the session list (Swift opens the sidebar when
    // activeSessionId == nil).
    LaunchedEffect(activeSessionId, isLoading) {
        if (activeSessionId == null && !isLoading && sessions.isNotEmpty()) {
            // Only relevant in the compact branch; opening a closed drawer in the
            // expanded branch is a no-op (the sidebar is always visible there).
            drawerState.open()
        }
    }

    if (connectionTimedOut) {
        AlertDialog(
            onDismissRequest = { coordinator.clearRecoveryFlags() },
            title = { Text("Connection Lost") },
            text = { Text("The connection timed out. Retry, or disconnect to leave the workspace.") },
            confirmButton = {
                TextButton(onClick = {
                    coordinator.clearRecoveryFlags()
                    coordinator.triggerUserRecovery()
                }) { Text("Retry") }
            },
            dismissButton = {
                TextButton(onClick = {
                    coordinator.clearRecoveryFlags()
                    onDisconnect()
                }) { Text("Disconnect") }
            },
        )
    }

    // "Cannot Open Session" alert (iOS WorkspaceView.swift:161-167). App-level
    // restore failure: the coordinator already evicted the stale terminal and
    // cleared the active session; the user picks a session from the sidebar (or
    // creates a new one) to continue — same UX as iOS.
    if (sessionAttachFailed) {
        AlertDialog(
            onDismissRequest = { coordinator.clearRecoveryFlags() },
            title = { Text("Cannot Open Session") },
            text = { Text("Unable to attach to this session.") },
            confirmButton = {
                TextButton(onClick = { coordinator.clearRecoveryFlags() }) { Text("OK") }
            },
        )
    }

    // "Session Moved" alert (iOS WorkspaceView.swift:168-181). Matches the iOS
    // copy exactly: title "Session Moved", message "{name} ({shortId}) was attached
    // from another device.", single OK button.
    stolenAlert?.let { alert ->
        AlertDialog(
            onDismissRequest = { coordinator.activityCoordinator.clearStolen(alert.sessionId) },
            title = { Text("Session Moved") },
            text = { Text("${alert.sessionName} (${alert.shortId}) was attached from another device.") },
            confirmButton = {
                TextButton(onClick = {
                    coordinator.activityCoordinator.clearStolen(alert.sessionId)
                }) { Text("OK") }
            },
        )
    }

    if (renameActive) {
        val id = activeSessionId
        if (id != null) {
            WorkspaceRenameDialog(
                initialName = nameFor(id),
                onConfirm = { newName ->
                    val trimmed = newName.trim()
                    if (trimmed.isNotEmpty()) scope.launch { coordinator.renameSession(id, trimmed) }
                    renameActive = false
                },
                onDismiss = { renameActive = false },
            )
        } else {
            renameActive = false
        }
    }
}

/**
 * The terminal pane: a top status bar, the [SessionTabs], then the [TerminalHost]
 * with the optional [KeyboardAccessory]. Ported from `ActiveTerminalView.swift`'s
 * detail pane.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TerminalColumn(
    vm: WorkspaceViewModel,
    sessions: List<relay.protocol.SessionInfo>,
    activeSessionId: UUID?,
    agentFor: (UUID) -> String?,
    agentStateFor: (UUID) -> relay.protocol.AgentDetectedState?,
    awaitingInput: Set<UUID>,
    quality: relay.protocol.ConnectionQuality,
    uptimeSeconds: Long,
    showKeyBar: Boolean,
    showSidebarToggle: Boolean,
    onToggleSidebar: () -> Unit,
    onToggleKeyBar: () -> Unit,
    onDisconnect: () -> Unit,
    onSelectTab: (UUID) -> Unit,
    onInput: (ByteArray) -> Unit,
    onResize: (cols: Int, rows: Int) -> Unit,
    onShareQr: (UUID) -> Unit,
    onNameTap: () -> Unit,
    onNameLongPress: () -> Unit,
    onKeyHaptic: () -> Unit,
    nameFor: (UUID) -> String,
    micButton: @Composable () -> Unit,
    redrawToken: Int,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            // Black fills edge-to-edge (incl. behind the status/nav bars), then
            // safeDrawing insets push the actual content — top toolbar, terminal,
            // key bar — into the safe area so the OS clock/home-indicator don't
            // overlap them. The bars themselves read as black (the terminal color).
            .background(Color.Black)
            .windowInsetsPadding(WindowInsets.safeDrawing),
    ) {
        // Status bar (top of the terminal column).
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(Color.Black)
                .padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            // All top-bar controls share the SessionTab "1" chip footprint (26×22dp,
            // 6dp corners) so they're visually uniform with the tab.
            if (showSidebarToggle) {
                ToolbarChip(onClick = onToggleSidebar) {
                    Icon(
                        Icons.Filled.Menu,
                        contentDescription = "Toggle Sidebar",
                        tint = Color.White,
                        modifier = Modifier.size(TOOLBAR_ICON),
                    )
                }
            }
            // Disconnect from the SERVER (iOS `server.rack` icon, ActiveTerminalView).
            // This leaves the server entirely — it is NOT a per-session close (kill a
            // session by swiping it in the sidebar). The earlier [X] looked like a
            // session-close, so it's now the server-rack glyph to match iOS.
            ToolbarChip(onClick = onDisconnect) {
                Icon(
                    Icons.Filled.Dns,
                    contentDescription = "Disconnect from server",
                    tint = Color.White,
                    modifier = Modifier.size(TOOLBAR_ICON),
                )
            }
            // Key-bar toggle — iOS uses the literal "fn" SF Symbol; Material has no
            // "fn" glyph, so we render an "fn" text chip (active = filled white,
            // inactive = dim), matching the iOS ToolbarIconButton(icon: "fn") look.
            FnToggleButton(active = showKeyBar, onClick = onToggleKeyBar)

            ConnectionQualityDot(quality = quality)

            if (activeSessionId != null) {
                Text(
                    text = WorkspaceLogic.formatUptime(uptimeSeconds),
                    color = Color.White.copy(alpha = 0.5f),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 11.sp,
                )
            }

            // Tabs take the remaining width.
            Box(modifier = Modifier.weight(1f)) {
                SessionTabs(
                    sessions = sessions,
                    activeSessionId = activeSessionId,
                    agentForSession = agentFor,
                    awaitingInput = awaitingInput,
                    onSelect = onSelectTab,
                    agentStateForSession = agentStateFor,
                )
            }

            // (The speech mic button is NOT here — iOS floats it bottom-right over
            // the terminal; see the floating Box in the terminal body below.)

            if (activeSessionId != null) {
                ToolbarChip(onClick = { onShareQr(activeSessionId) }) {
                    Icon(
                        Icons.Filled.QrCode,
                        contentDescription = "Share Session",
                        tint = Color.White,
                        modifier = Modifier.size(TOOLBAR_ICON),
                    )
                }
                // Session name badge. Shares the SessionTab "1" chip footprint
                // (defaultMinSize 26×22dp + horizontal-only padding, NO vertical
                // padding) so its height matches every other top-bar control — the
                // earlier vertical padding made it taller than the 22dp chips.
                // Tap forces a terminal redraw (fixes rare glyph overlap); long-press
                // renames (Swift's onLongPressGesture).
                Box(
                    modifier = Modifier
                        .defaultMinSize(
                            minWidth = TOOLBAR_CHIP_MIN_WIDTH,
                            minHeight = TOOLBAR_CHIP_MIN_HEIGHT,
                        )
                        .clip(TOOLBAR_CHIP_SHAPE)
                        .background(Color.White.copy(alpha = 0.12f))
                        .combinedClickable(onClick = onNameTap, onLongClick = onNameLongPress)
                        .padding(horizontal = 8.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = nameFor(activeSessionId),
                        color = Color.White,
                        fontSize = 12.sp,
                        maxLines = 1,
                    )
                }
            }
        }

        // Terminal body.
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            val activeVm = activeSessionId?.let { vm.coordinator.terminalCache.view(it) }

            // Swipe flash (iOS ActiveTerminalView `refreshSweepProgress`
            // parity): a soft white band sweeping top → bottom across the
            // terminal (~1 s) confirming the session-name refresh fired — the
            // motion reads as "the screen is being rewritten". Keyed off
            // redrawToken — the same bump that drives the local repaint — so
            // feedback and refresh can't drift apart. Progress 0 parks the band
            // offscreen above, 1 offscreen below; snapTo(0) first so rapid
            // re-taps restart the sweep instead of reversing mid-flight.
            val sweepProgress = remember { Animatable(0f) }
            LaunchedEffect(redrawToken) {
                if (redrawToken > 0) {
                    sweepProgress.snapTo(0f)
                    sweepProgress.animateTo(1f, tween(1000, easing = FastOutSlowInEasing))
                }
            }
            if (activeSessionId != null && activeVm != null) {
                TerminalHost(
                    vm = activeVm,
                    onInput = onInput,
                    onResize = onResize,
                    redrawToken = redrawToken,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        "No Active Session",
                        color = Color.White.copy(alpha = 0.6f),
                    )
                }
            }

            // Floating mic button, bottom-right over the terminal (iOS
            // ActiveTerminalView floating buttons: 16dp end / 12dp bottom). Always
            // present so the user can enable/disable continuous listening or kick
            // off the model download even with no active session.
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 16.dp, bottom = 12.dp),
            ) {
                micButton()
            }

            // The sweep band itself, drawn only mid-flight (invisible at both
            // endpoints). drawWithContent paints a clear→white→clear gradient
            // band at the current progress — no layout node moves, so there is
            // zero layout shift, and a plain draw overlay never intercepts
            // touches (iOS `.allowsHitTesting(false)`).
            val progress = sweepProgress.value
            if (progress > 0f && progress < 1f) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .drawWithContent {
                            val bandHeight = size.height * 0.45f
                            // 0 → band fully offscreen above, 1 → fully offscreen below.
                            val bandStart = -bandHeight + (size.height + 2f * bandHeight) * progress
                            drawRect(
                                brush = Brush.verticalGradient(
                                    0f to Color.Transparent,
                                    0.5f to Color.White.copy(alpha = 0.30f),
                                    1f to Color.Transparent,
                                    startY = bandStart,
                                    endY = bandStart + bandHeight,
                                ),
                                topLeft = Offset(0f, bandStart),
                                size = Size(size.width, bandHeight),
                            )
                        },
                )
            }
        }

        if (showKeyBar && activeSessionId != null) {
            // Every special-key press fires the iOS `.light` impact haptic
            // (KeyboardAccessory.swift's `haptic()`), routed through the gated
            // helper via onKeyHaptic before the bytes are sent.
            KeyboardAccessory(
                onKey = { bytes -> onKeyHaptic(); onInput(bytes) },
            )
        }
    }
}

/**
 * A top-bar control chip with the SAME footprint as the SessionTab "1" chip
 * (26x22dp min, 6dp corners, translucent-white bg) so all top-bar items are
 * visually uniform. Holds an icon or short text.
 */
@Composable
private fun ToolbarChip(onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(
        modifier = Modifier
            .defaultMinSize(minWidth = TOOLBAR_CHIP_MIN_WIDTH, minHeight = TOOLBAR_CHIP_MIN_HEIGHT)
            .clip(TOOLBAR_CHIP_SHAPE)
            .background(Color.White.copy(alpha = 0.12f))
            .clickable(onClick = onClick)
            .padding(horizontal = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        content()
    }
}

/**
 * The key-bar toggle, rendering an "fn" chip (iOS `ToolbarIconButton(icon: "fn")`).
 * Same footprint as [ToolbarChip] / the "1" tab; filled white when [active] (key
 * bar shown), dim white-on-translucent when inactive.
 */
@Composable
private fun FnToggleButton(active: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .defaultMinSize(minWidth = TOOLBAR_CHIP_MIN_WIDTH, minHeight = TOOLBAR_CHIP_MIN_HEIGHT)
            .clip(TOOLBAR_CHIP_SHAPE)
            .background(if (active) Color.White else Color.White.copy(alpha = 0.12f))
            .clickable(onClick = onClick)
            .padding(horizontal = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = "fn",
            color = if (active) Color.Black else Color.White.copy(alpha = 0.7f),
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            fontFamily = FontFamily.Monospace,
        )
    }
}

/** Recovery scrim, ported from the Swift `RecoveryOverlay` sheet. */
@Composable
private fun RecoveryOverlay(
    phase: RecoveryPhase,
    onCancel: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.7f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            CircularProgressIndicator()
            Text("Reconnecting", style = MaterialTheme.typography.titleMedium, color = Color.White)
            Text(
                text = phaseLabel(phase),
                style = MaterialTheme.typography.bodyMedium,
                color = Color.White.copy(alpha = 0.7f),
            )
            TextButton(onClick = onCancel) { Text("Cancel") }
        }
    }
}

/** Phase → user-facing label, ported from the Swift `RecoveryPhase.label`. */
private fun phaseLabel(phase: RecoveryPhase): String = when (phase) {
    RecoveryPhase.RECONNECTING -> "Reconnecting…"
    RecoveryPhase.AUTHENTICATING -> "Authenticating…"
    RecoveryPhase.RESUMING -> "Resuming session…"
}

@Composable
private fun WorkspaceRenameDialog(
    initialName: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var text by remember { mutableStateOf(initialName) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename Session") },
        text = {
            TextField(
                value = text,
                onValueChange = { text = it },
                singleLine = true,
                label = { Text("Name") },
            )
        },
        confirmButton = { TextButton(onClick = { onConfirm(text) }) { Text("Rename") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
