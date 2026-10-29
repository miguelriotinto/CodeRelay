package relay.feature.workspace

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import relay.feature.workspace.hub.HubSidebar
import relay.feature.workspace.hub.HubTabs
import relay.feature.workspace.hub.HubWorkspaceLogic
import relay.feature.workspace.hub.WorkspaceSlot
import relay.feature.workspace.ui.SessionLoadingSheetHost
import relay.protocol.SessionRef
import relay.session.SessionLoadingSheetModel
import relay.session.hub.ServerHub

/** How long a hub notice stays up before it clears itself (Apple-app parity). */
private const val NOTICE_MS = 4_000L

/**
 * The workspace across every enabled relay (multi-server spec §8.1, §8.4,
 * §8.5): a sidebar grouped by server, tabs numbered across servers, one
 * attached session, and ONE loading sheet that survives a cross-server switch.
 *
 * The terminal pane follows the hub's active slot (else its focus slot) and is
 * re-keyed per slot, so a cross-server switch swaps the whole host. The loading
 * sheet model lives HERE, above that key — hosting it inside the re-keyed pane
 * dismissed and re-presented it mid-load on the Apple apps.
 *
 * With no server enabled (an upgrade that disabled every bookmark, or a fresh
 * install) it asks the host to present management via [onOpenServers].
 */
@Composable
fun <S : WorkspaceSlot> WorkspaceScreen(
    hub: ServerHub<S>,
    onOpenServers: () -> Unit,
    onAttach: (S) -> Unit,
    onShareQr: (SessionRef) -> Unit,
    shareScreen: Boolean = true,
    hapticsEnabled: Boolean = false,
    sidebarToggleRequests: Flow<Unit> = emptyFlow(),
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val loading = remember { SessionLoadingSheetModel(scope) }
    val focus by hub.focusSlot.collectAsState()
    val active by hub.activeSlot.collectAsState()
    val sections by hub.sections.collectAsState()
    val aggregate by hub.aggregate.collectAsState()
    val notice by hub.notice.collectAsState()
    val hasStarted by hub.hasStarted.collectAsState()
    val slot = active ?: focus

    LaunchedEffect(hasStarted, aggregate.enabledServers) {
        if (hasStarted && HubWorkspaceLogic.shouldPresentManagement(aggregate)) onOpenServers()
    }

    Box(modifier.fillMaxSize().background(Color.Black)) {
        if (slot == null) {
            if (sections.any { it.config.enabled }) {
                // Nothing selectable yet, but the servers' headers (status,
                // Retry, cached rows) are exactly what the user needs to see.
                HubSidebar(hub, onOpenServers, onAttach, onShareQr, onSelected = {})
            } else {
                HubEmptyState(hasStarted = hasStarted, onOpenServers = onOpenServers)
            }
        } else {
            key(slot) {
                WorkspacePane(
                    vm = slot.workspaceViewModel,
                    onDisconnect = onOpenServers,
                    onAttach = { onAttach(slot) },
                    onShareQr = { id -> onShareQr(SessionRef(slot.config.id, id)) },
                    shareScreen = shareScreen,
                    hapticsEnabled = hapticsEnabled,
                    sidebarToggleRequests = sidebarToggleRequests,
                    serverName = sections.takeIf { s -> s.count { it.config.enabled } > 1 }
                        ?.firstOrNull { it.id == slot.config.id }?.title,
                    sidebarContent = { close -> HubSidebar(hub, onOpenServers, onAttach, onShareQr, onSelected = close) },
                    tabsContent = { HubTabs(hub) },
                    externalLoading = loading,
                )
            }
        }

        AnimatedVisibility(
            visible = notice != null,
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier.align(Alignment.TopCenter).windowInsetsPadding(WindowInsets.safeDrawing),
        ) {
            Text(
                notice.orEmpty(),
                color = Color.White,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier
                    .padding(top = 8.dp)
                    .background(Color(0xFF2C2C2E), RoundedCornerShape(50))
                    .clickable { hub.setNotice(null) }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            )
        }
    }

    LaunchedEffect(notice) {
        val shown = notice ?: return@LaunchedEffect
        delay(NOTICE_MS)
        if (hub.notice.value == shown) hub.setNotice(null)
    }

    SessionLoadingSheetHost(loading, onCancel = { (active ?: focus)?.coordinator?.cancelRecovery() })
}

@Composable
private fun HubEmptyState(hasStarted: Boolean, onOpenServers: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        if (!hasStarted) {
            CircularProgressIndicator()
            Text("Connecting to servers…", color = Color.White.copy(alpha = 0.7f))
        } else {
            Text("No servers enabled", color = Color.White.copy(alpha = 0.7f))
            Button(onClick = onOpenServers) { Text("Servers") }
        }
    }
}
