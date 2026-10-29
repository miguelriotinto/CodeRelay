package relay.feature.workspace.hub

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallSplit
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedIconButton
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import relay.feature.workspace.ui.SessionRenameDialog
import relay.feature.workspace.ui.sessionRows
import relay.protocol.ActivityState
import relay.protocol.AgentDetectedState
import relay.protocol.SessionRef
import relay.protocol.WorkspaceRollup
import relay.session.hub.ServerHub
import relay.session.hub.createSession
import relay.session.hub.select
import java.util.UUID

/** Tighter than Material's 24 dp so "New" and "Attach" fit beside the Servers button in a 320 dp drawer. */
private val CompactButtonPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp)

/** Per-server lookups the rows need, collected from that server's coordinator. */
private class RowSource(
    val names: Map<UUID, String>,
    val agents: Map<UUID, String>,
    val agentStates: Map<UUID, AgentDetectedState>,
    val unseen: Set<UUID>,
    val awaiting: Set<UUID>,
    val activity: (UUID) -> ActivityState,
)

@Composable
private fun rowSourceFor(slot: WorkspaceSlot): RowSource {
    val c = slot.coordinator
    val names by c.sessionNames.collectAsState()
    val agents by c.agentSessions.collectAsState()
    val agentStates by c.agentStates.collectAsState()
    val unseen by c.unseenSessions.collectAsState()
    val awaiting by c.sessionsAwaitingInput.collectAsState()
    return RowSource(names, agents, agentStates, unseen, awaiting) { id -> c.activityCoordinator.activityState(id) }
}

/**
 * The multi-server sidebar (spec §8.1): one header per bookmark — status dot,
 * subtitle, Retry, New — over that server's rollup tiles. Offline sections keep
 * their cached rows, greyed; disabled ones keep theirs too but they are inert.
 * Rows of every server live in ONE lazy list, keyed per server, so two relays
 * listing the same session id never collide.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun <S : WorkspaceSlot> HubSidebar(
    hub: ServerHub<S>,
    onOpenServers: () -> Unit,
    onAttach: (S) -> Unit,
    onShareQr: (SessionRef) -> Unit,
    onSelected: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val sections by hub.sections.collectAsState()
    val activeRef by hub.activeRef.collectAsState()
    val focus by hub.focusSlot.collectAsState()
    val focusServerId by hub.focusServerId.collectAsState()
    var renameTarget by remember { mutableStateOf<Triple<UUID, UUID, String>?>(null) }
    // A plain map: its lists are the state; creating one lazily inside the list
    // builder must not be a snapshot write.
    val collapsedGroups = remember { HashMap<UUID, SnapshotStateList<String>>() }

    // Collected per server BEFORE the lazy list (its builder is not composable).
    val sources = mutableMapOf<UUID, RowSource>()
    sections.forEach { section ->
        val slot = hub.slot(section.id) ?: return@forEach
        key(section.id) { sources[section.id] = rowSourceFor(slot) }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surface)
            .windowInsetsPadding(WindowInsets.safeDrawing),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            // Icon-only: three labelled buttons do not fit the 320 dp drawer
            // ("Servers" / "New" / "Attach" truncated to "S" / "N" / "At").
            OutlinedIconButton(onClick = onOpenServers) {
                Icon(Icons.Filled.Dns, contentDescription = "Servers")
            }
            focusServerId?.let { id ->
                OutlinedButton(
                    onClick = { scope.launch { hub.createSession(id); onSelected() } },
                    modifier = Modifier.weight(1f),
                    contentPadding = CompactButtonPadding,
                ) {
                    Icon(Icons.Filled.Add, contentDescription = null)
                    Text("New", modifier = Modifier.padding(start = 6.dp), maxLines = 1)
                }
            }
            focus?.let { slot ->
                OutlinedButton(onClick = { onAttach(slot) }, modifier = Modifier.weight(1f), contentPadding = CompactButtonPadding) {
                    Icon(Icons.AutoMirrored.Filled.CallSplit, contentDescription = null)
                    Text("Attach", modifier = Modifier.padding(start = 6.dp), maxLines = 1)
                }
            }
        }

        PullToRefreshBox(
            isRefreshing = false,
            // An entry into a live workspace for every server, staggered (D10).
            onRefresh = { hub.handleForegroundTransition() },
            modifier = Modifier.fillMaxSize(),
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 8.dp),
            ) {
                sections.forEach { section ->
                    val model = ServerSectionHeaderModel.of(section)
                    item(key = "server-${section.id}") {
                        ServerSectionHeader(
                            model = model,
                            isCollapsed = section.isCollapsed,
                            onToggle = { hub.setCollapsed(section.id, !section.isCollapsed) },
                            onRetry = {
                                when (HubWorkspaceLogic.retryAction(section)) {
                                    RetryAction.OPEN_MANAGEMENT -> onOpenServers()
                                    RetryAction.RECOVER -> hub.triggerUserRecovery(section.id)
                                }
                            },
                            onNew = if (section.status.isLive) {
                                { scope.launch { hub.createSession(section.id); onSelected() } }
                            } else {
                                null
                            },
                        )
                    }
                    if (section.isCollapsed) return@forEach
                    if (section.sessions.isEmpty()) {
                        item(key = "empty-${section.id}") {
                            Text(
                                if (section.status.isLive) "No sessions" else " ",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(start = 26.dp, bottom = 6.dp),
                            )
                        }
                        return@forEach
                    }
                    val source = sources[section.id]
                    val groups = section.rollups.ifEmpty {
                        listOf(WorkspaceRollup("all-${section.id}", "Sessions", section.sessions.map { it.id }, relay.protocol.RollupState.SEEN, 0))
                    }
                    val collapsed = collapsedGroups.getOrPut(section.id) { mutableStateListOf() }
                    val slot = hub.slot(section.id)
                    sessionRows(
                        keyPrefix = "${section.id}-",
                        sessions = section.sessions,
                        groups = groups,
                        collapsed = collapsed,
                        activeSessionId = activeRef?.takeIf { it.serverId == section.id }?.sessionId,
                        nameForSession = { id -> source?.names?.get(id) ?: section.sessions.firstOrNull { it.id == id }?.name ?: id.toString().take(8) },
                        agentForSession = { id -> source?.agents?.get(id) },
                        activityForSession = { id -> source?.activity?.invoke(id) ?: ActivityState.ACTIVE },
                        agentStateForSession = { id -> source?.agentStates?.get(id) },
                        seenForSession = { id -> source?.unseen?.contains(id) != true },
                        onSelect = { id -> scope.launch { hub.select(SessionRef(section.id, id)); onSelected() } },
                        onTerminate = { id -> scope.launch { slot?.coordinator?.terminateSession(id) } },
                        onRenameRequest = { id -> renameTarget = Triple(section.id, id, source?.names?.get(id) ?: "") },
                        onShareQr = { id -> onShareQr(SessionRef(section.id, id)) },
                        dimmed = section.isCached,
                        selectable = section.config.enabled,
                    )
                }
            }
        }
    }

    renameTarget?.let { (serverId, sessionId, current) ->
        SessionRenameDialog(
            initialName = current,
            onConfirm = { name ->
                val trimmed = name.trim()
                if (trimmed.isNotEmpty()) scope.launch { hub.slot(serverId)?.coordinator?.renameSession(sessionId, trimmed) }
                renameTarget = null
            },
            onDismiss = { renameTarget = null },
        )
    }
}

/** The cross-server tab strip: numbered across every enabled server, keyed by [SessionRef]. */
@Composable
fun <S : WorkspaceSlot> HubTabs(hub: ServerHub<S>, onSelected: () -> Unit = {}, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    val sections by hub.sections.collectAsState()
    val activeRef by hub.activeRef.collectAsState()
    val sources = mutableMapOf<UUID, RowSource>()
    sections.forEach { section ->
        val slot = hub.slot(section.id) ?: return@forEach
        key(section.id) { sources[section.id] = rowSourceFor(slot) }
    }
    relay.feature.workspace.ui.TabStrip(
        items = HubWorkspaceLogic.tabs(sections, activeRef).map { tab ->
            val src = sources[tab.ref.serverId]
            relay.feature.workspace.ui.TabStripItem(
                key = tab.ref,
                number = tab.number,
                isSelected = tab.isSelected,
                agentId = src?.agents?.get(tab.ref.sessionId),
                agentState = src?.agentStates?.get(tab.ref.sessionId),
                // Collected (not read), so a waiting session swapping for another
                // still recomposes the tab's attention flash.
                awaitingInput = src?.awaiting?.contains(tab.ref.sessionId) == true,
                contentDescription = tab.serverTitle?.let { "$it, session ${tab.number}" },
            )
        },
        onSelect = { item -> scope.launch { hub.select(item.key as SessionRef); onSelected() } },
        modifier = modifier,
    )
}
