package relay.feature.workspace.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallSplit
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import relay.protocol.ActivityState
import relay.protocol.SessionInfo
import java.util.UUID

/**
 * Workspace sidebar, ported from `SessionSidebarView.swift`.
 *
 *  - "New Session" / "Attach Session" buttons at the top (the iOS first List
 *    section).
 *  - a [LazyColumn] of session rows, each showing an [ActivityDot], the display
 *    name, the short id, a state badge ([WorkspaceLogic.badgeBucket]).
 *  - rename via an [AlertDialog] with a [TextField] (Swift's `.alert` +
 *    `TextField`).
 *  - trailing swipe-to-delete (Swift `swipeActions` "Kill"), no full-swipe.
 *  - a long-press context menu ([DropdownMenu]: Rename / Share QR), Swift's
 *    `.contextMenu`. Share QR is a stub callback wired in Task 9.
 *  - pull-to-refresh → [onRefresh] (Swift `.refreshable` → `fetchSessions`).
 *
 * State is hoisted: the screen passes the session list, the active id, the
 * name/agent/activity lookups, and the callbacks. The only local state is the
 * rename dialog target and the per-row context-menu expansion.
 *
 * @param onShareQr stubbed in M2; the QR sheet is wired in Task 9.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun SessionSidebar(
    sessions: List<SessionInfo>,
    activeSessionId: UUID?,
    nameForSession: (UUID) -> String,
    agentForSession: (UUID) -> String?,
    activityForSession: (UUID) -> ActivityState,
    agentStateForSession: (UUID) -> relay.protocol.AgentDetectedState? = { null },
    seenForSession: (UUID) -> Boolean = { true },
    rollupsForSessions: (List<SessionInfo>) -> List<relay.protocol.WorkspaceRollup> =
        { list -> listOf(relay.protocol.WorkspaceRollup("~", "Sessions", list.map { it.id },
            relay.protocol.RollupState.SEEN, 0)) },
    isRefreshing: Boolean,
    onRefresh: () -> Unit,
    onNewSession: () -> Unit,
    onAttach: () -> Unit,
    onSelect: (UUID) -> Unit,
    onRename: (UUID, String) -> Unit,
    onTerminate: (UUID) -> Unit,
    onShareQr: (UUID) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Rename dialog target (null = closed). Carries the id + the current name to
    // prefill the field.
    var renameTarget by remember { mutableStateOf<RenameTarget?>(null) }

    Column(
        modifier = modifier
            .fillMaxSize()
            // Dark panel surface (distinct from the pure-black terminal so the pane
            // reads as a layer ABOVE it), inset into the safe area so the actions
            // row clears the status bar and the list clears the nav bar.
            .background(MaterialTheme.colorScheme.surface)
            .windowInsetsPadding(WindowInsets.safeDrawing),
    ) {
        // Top actions.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedButton(onClick = onNewSession, modifier = Modifier.weight(1f)) {
                Icon(Icons.Filled.Add, contentDescription = null)
                Text("New", modifier = Modifier.padding(start = 6.dp))
            }
            OutlinedButton(onClick = onAttach, modifier = Modifier.weight(1f)) {
                Icon(Icons.AutoMirrored.Filled.CallSplit, contentDescription = null)
                Text("Attach", modifier = Modifier.padding(start = 6.dp))
            }
        }

        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = onRefresh,
            modifier = Modifier.fillMaxSize(),
        ) {
            if (sessions.isEmpty()) {
                EmptySessionsState(modifier = Modifier.fillMaxSize())
            } else {
                val byId = sessions.associateBy { it.id }
                val groups = rollupsForSessions(sessions)
                val collapsed = remember { mutableStateListOf<String>() }
                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    groups.forEach { group ->
                        item(key = "hdr-${group.id}") {
                            RollupHeader(
                                group = group,
                                collapsed = collapsed.contains(group.id),
                                onToggle = {
                                    if (collapsed.contains(group.id)) collapsed.remove(group.id)
                                    else collapsed.add(group.id)
                                },
                            )
                        }
                        if (!collapsed.contains(group.id)) {
                            items(group.sessionIds.mapNotNull { byId[it] }, key = { it.id }) { session ->
                                SwipeableSessionRow(
                                    session = session,
                                    name = nameForSession(session.id),
                                    isActive = session.id == activeSessionId,
                                    activity = activityForSession(session.id),
                                    agentId = agentForSession(session.id),
                                    agentState = agentStateForSession(session.id),
                                    seen = seenForSession(session.id),
                                    onSelect = { onSelect(session.id) },
                                    onTerminate = { onTerminate(session.id) },
                                    onRenameRequest = {
                                        renameTarget = RenameTarget(session.id, nameForSession(session.id))
                                    },
                                    onShareQr = { onShareQr(session.id) },
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    renameTarget?.let { target ->
        RenameDialog(
            initialName = target.name,
            onConfirm = { newName ->
                val trimmed = newName.trim()
                if (trimmed.isNotEmpty()) onRename(target.id, trimmed)
                renameTarget = null
            },
            onDismiss = { renameTarget = null },
        )
    }
}

private data class RenameTarget(val id: UUID, val name: String)

/**
 * A session row wrapped in a trailing swipe-to-delete (Swift "Kill" swipe
 * action). Like the servers screen, the swipe is consumed (returns false from
 * `confirmValueChange`) so the row settles back after firing — the list mutation
 * is the real effect. A long-press opens the row context menu.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun SwipeableSessionRow(
    session: SessionInfo,
    name: String,
    isActive: Boolean,
    activity: ActivityState,
    agentId: String?,
    agentState: relay.protocol.AgentDetectedState?,
    seen: Boolean,
    onSelect: () -> Unit,
    onTerminate: () -> Unit,
    onRenameRequest: () -> Unit,
    onShareQr: () -> Unit,
) {
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) {
                onTerminate(); false
            } else {
                false
            }
        },
    )

    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.error)
                    .padding(horizontal = 20.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Icon(Icons.Filled.Delete, contentDescription = "Kill", tint = Color.White)
            }
        },
    ) {
        SessionRow(
            session = session,
            name = name,
            isActive = isActive,
            activity = activity,
            agentId = agentId,
            agentState = agentState,
            seen = seen,
            onSelect = onSelect,
            onRenameRequest = onRenameRequest,
            onShareQr = onShareQr,
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionRow(
    session: SessionInfo,
    name: String,
    isActive: Boolean,
    activity: ActivityState,
    agentId: String?,
    agentState: relay.protocol.AgentDetectedState?,
    seen: Boolean,
    onSelect: () -> Unit,
    onRenameRequest: () -> Unit,
    onShareQr: () -> Unit,
) {
    var menuExpanded by remember { mutableStateOf(false) }

    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(
                    if (isActive) {
                        MaterialTheme.colorScheme.surfaceVariant
                    } else {
                        MaterialTheme.colorScheme.surface
                    },
                )
                .combinedClickable(
                    onClick = onSelect,
                    onLongClick = { menuExpanded = true },
                )
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            val dotColor = sessionStatusDotColor(session.state)
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(dotColor ?: Color.Transparent),
            )

            Text(
                text = name,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )

            // Trailing agent cluster: sparkle micro-icon + friendly name + state
            // pill. Parity with iOS/macOS `SessionRow`. The terminal window title
            // (`titleForSession`) is intentionally NOT shown as a subtitle — for a
            // coding-agent session it just duplicates the friendly name here.
            val friendly = friendlyAgentName(agentId)
            if (friendly != null && agentState != null) {
                AgentSparkleIcon(agentId = agentId, agentState = agentState)
                Text(
                    text = friendly,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
                AgentStatePill(agentState = agentState, agentId = agentId, seen = seen)
            }
        }

        DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
            DropdownMenuItem(
                text = { Text("Rename") },
                leadingIcon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                onClick = { menuExpanded = false; onRenameRequest() },
            )
            DropdownMenuItem(
                text = { Text("Share QR Code") },
                leadingIcon = { Icon(Icons.Filled.QrCode, contentDescription = null) },
                onClick = { menuExpanded = false; onShareQr() },
            )
        }
    }
}

@Composable
private fun RenameDialog(
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
        confirmButton = {
            TextButton(onClick = { onConfirm(text) }) { Text("Rename") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun EmptySessionsState(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.padding(32.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Filled.Terminal,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text("No Sessions", style = MaterialTheme.typography.titleMedium)
        Text(
            "Create a new session to get started.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Badge/dot color for a workspace group's aggregate rollup state. Mirrors the
 * iOS RollupState.badgeColor + the per-session ActivityDot palette. */
private fun relay.protocol.RollupState.badgeColor(): Color = when (this) {
    relay.protocol.RollupState.BLOCKED -> QualityRed
    relay.protocol.RollupState.FINISHED_UNSEEN -> IdleYellow
    relay.protocol.RollupState.WORKING -> Color(red = 84 / 255f, green = 132 / 255f, blue = 137 / 255f)
    relay.protocol.RollupState.UNKNOWN -> UnknownGray
    relay.protocol.RollupState.SEEN -> QualityGreen
}

/** Collapsible workspace-group header: chevron + rollup dot + title + count. */
@Composable
private fun RollupHeader(
    group: relay.protocol.WorkspaceRollup,
    collapsed: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .clickable(onClick = onToggle)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = if (collapsed) Icons.AutoMirrored.Filled.KeyboardArrowRight
                          else Icons.Filled.KeyboardArrowDown,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.width(4.dp))
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(group.state.badgeColor()),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = group.title,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.weight(1f))
        if (group.attentionCount > 0) {
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(QualityRed.copy(alpha = 0.85f))
                    .padding(horizontal = 6.dp, vertical = 1.dp),
            ) {
                Text(
                    text = group.attentionCount.toString(),
                    style = MaterialTheme.typography.labelSmall,
                    color = Color.White,
                )
            }
        }
    }
}
