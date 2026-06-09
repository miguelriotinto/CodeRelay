package relay.feature.workspace

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
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
import relay.terminal.KeyboardAccessory
import java.util.UUID

/** Material3 "expanded" width breakpoint — width ≥ this gets the two-pane layout. */
private val EXPANDED_WIDTH_BREAKPOINT = 840.dp

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

    val isRecovering by coordinator.isRecovering.collectAsStateWithLifecycle()
    val recoveryPhase by coordinator.recoveryPhase.collectAsStateWithLifecycle()
    val connectionTimedOut by coordinator.connectionTimedOut.collectAsStateWithLifecycle()

    val quality by vm.connectionQuality.collectAsStateWithLifecycle()
    val uptimeSeconds by vm.uptimeSeconds.collectAsStateWithLifecycle()

    fun nameFor(id: UUID): String = sessionNames[id] ?: id.toString().take(8)
    fun agentFor(id: UUID): String? = agentSessions[id]
    fun activityFor(id: UUID): relay.protocol.ActivityState =
        coordinator.activityCoordinator.activityState(id)

    var showKeyBar by remember { mutableStateOf(true) }
    var renameActive by remember { mutableStateOf(false) }

    val drawerState = rememberDrawerState(DrawerValue.Closed)

    val sidebar: @Composable () -> Unit = {
        SessionSidebar(
            sessions = sessions,
            activeSessionId = activeSessionId,
            nameForSession = ::nameFor,
            agentForSession = ::agentFor,
            activityForSession = ::activityFor,
            isRefreshing = isLoading,
            onRefresh = { scope.launch { coordinator.fetchSessions() } },
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
                onShareQr = { id -> haptics.lightTap(); onShareQr(id) },
                onNameLongPress = { renameActive = true },
                onKeyHaptic = { haptics.lightTap() },
                nameFor = ::nameFor,
                micButton = micButton,
            )
        }

    Box(modifier = modifier.fillMaxSize()) {
        BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
            // Material3 "expanded" breakpoint: width ≥ 840 dp gets the two-pane
            // layout (same split point the iOS horizontalSizeClass uses).
            val expanded = maxWidth >= EXPANDED_WIDTH_BREAKPOINT

            if (expanded) {
                Row(modifier = Modifier.fillMaxSize()) {
                    Box(modifier = Modifier.width(320.dp).fillMaxHeight()) { sidebar() }
                    Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                        terminalColumn({ /* no toggle in two-pane */ }, true)
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
    onShareQr: (UUID) -> Unit,
    onNameLongPress: () -> Unit,
    onKeyHaptic: () -> Unit,
    nameFor: (UUID) -> String,
    micButton: @Composable () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
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
            if (showSidebarToggle) {
                IconButton(onClick = onToggleSidebar) {
                    Icon(Icons.Filled.Menu, contentDescription = "Toggle Sidebar", tint = Color.White)
                }
            }
            IconButton(onClick = onDisconnect) {
                Icon(Icons.Filled.Close, contentDescription = "Disconnect", tint = Color.White)
            }
            IconButton(onClick = onToggleKeyBar) {
                Icon(
                    Icons.Filled.Keyboard,
                    contentDescription = if (showKeyBar) "Hide Key Bar" else "Show Key Bar",
                    tint = if (showKeyBar) Color.White else Color.White.copy(alpha = 0.5f),
                )
            }

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
                )
            }

            // Speech mic button — always visible so the user can enable/disable
            // continuous listening (or start the model download) even with no
            // active session; PTT/continuous gating is internal to the button.
            micButton()

            if (activeSessionId != null) {
                IconButton(onClick = { onShareQr(activeSessionId) }) {
                    Icon(Icons.Filled.QrCode, contentDescription = "Share Session", tint = Color.White)
                }
                // Session name badge — long-press to rename (Swift's onLongPressGesture).
                Box(
                    modifier = Modifier
                        .background(
                            color = Color.White.copy(alpha = 0.12f),
                            shape = RoundedCornerShape(6.dp),
                        )
                        .combinedClickable(onClick = {}, onLongClick = onNameLongPress)
                        .padding(horizontal = 8.dp, vertical = 4.dp),
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
            if (activeSessionId != null && activeVm != null) {
                TerminalHost(
                    vm = activeVm,
                    onInput = onInput,
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
