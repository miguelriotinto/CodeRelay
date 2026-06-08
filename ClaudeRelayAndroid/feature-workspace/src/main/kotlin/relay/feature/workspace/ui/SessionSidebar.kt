package relay.feature.workspace.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallSplit
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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

    Column(modifier = modifier.fillMaxSize()) {
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
                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(sessions, key = { it.id }) { session ->
                        SwipeableSessionRow(
                            session = session,
                            name = nameForSession(session.id),
                            isActive = session.id == activeSessionId,
                            activity = activityForSession(session.id),
                            agentId = agentForSession(session.id),
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
    onSelect: () -> Unit,
    onRenameRequest: () -> Unit,
    onShareQr: () -> Unit,
) {
    var menuExpanded by remember { mutableStateOf(false) }
    val shortId = session.id.toString().take(8)

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
            ActivityDot(activity = activity, agentId = agentId)

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Text(
                    text = name,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                )
                Text(
                    text = shortId,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            StateBadge(state = session.state)
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

/** State badge capsule colored by [WorkspaceLogic.badgeBucket]. */
@Composable
private fun StateBadge(state: relay.protocol.SessionState) {
    val color = when (WorkspaceLogic.badgeBucket(state)) {
        WorkspaceLogic.BadgeBucket.GREEN -> QualityGreen
        WorkspaceLogic.BadgeBucket.YELLOW -> QualityYellow
        WorkspaceLogic.BadgeBucket.RED -> QualityRed
    }
    Text(
        text = state.raw,
        style = MaterialTheme.typography.labelSmall,
        color = color,
        modifier = Modifier
            .background(
                color = color.copy(alpha = 0.15f),
                shape = androidx.compose.foundation.shape.RoundedCornerShape(50),
            )
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
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
