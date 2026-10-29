package relay.feature.servers

import relay.session.hub.removeServer
import relay.session.hub.ServerSlot
import relay.session.hub.ServerSectionStatus
import relay.session.hub.ServerSection
import relay.session.hub.ServerHub
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.TextButton
import androidx.compose.material3.Switch
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch
import relay.net.CleartextPolicy
import relay.protocol.ConnectionConfig
import relay.session.ServerStatus

/**
 * Server management (multi-server spec §8.1, §11), ported from the Apple
 * `ServerListView` / `ServerListWindow`:
 *  - every bookmark, with an **Enabled** switch — enabled servers are live in
 *    the workspace; there is no Connect;
 *  - the status of an enabled server is its live hub section; a disabled one is
 *    probed by the status poller ("disabled · reachable / offline");
 *  - tap or swipe right → edit, swipe left → delete (detaches, unregisters push,
 *    forgets the token);
 *  - "+" FABs add a server or pair with a host; the footer counts enabled
 *    servers against the cap of 8 and shows the hub's notice.
 *
 * Enabling a plaintext `ws://` bookmark on a non-private host is refused with a
 * snackbar first — a friendly early message; the authoritative gate is the
 * connect chokepoint (`RelayConnection.connect` → `CleartextPolicy.requireAllowed`).
 *
 * @param onDone leave management (shown once a server is enabled).
 * @param pendingPairingUrl when non-null, opens the pairing sheet prefilled from
 * the URL (a `coderelay://pair` deep link or a QR scanned via [onScanPair]); the
 * caller clears it via [clearPendingPairing] after consumption.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun <S : ServerSlot> ServersScreen(
    viewModel: ServersViewModel,
    hub: ServerHub<S>,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
    pendingPairingUrl: relay.protocol.PairingURL? = null,
    clearPendingPairing: () -> Unit = {},
    onScanPair: () -> Unit = {},
) {
    val sections by hub.sections.collectAsStateWithLifecycle()
    val aggregate by hub.aggregate.collectAsStateWithLifecycle()
    val notice by hub.notice.collectAsStateWithLifecycle()
    val statuses by viewModel.statuses.collectAsStateWithLifecycle()

    val snackbarHostState = remember { SnackbarHostState() }
    val coroutineScope = rememberCoroutineScope()

    // Sheet state: null = closed, Add or Edit(config) = open.
    var sheetMode by remember { mutableStateOf<ServerSheetMode?>(null) }
    var isRefreshing by remember { mutableStateOf(false) }

    fun setEnabled(config: ConnectionConfig, on: Boolean) {
        if (on && !config.useTLS && !CleartextPolicy.isPrivateNetworkHost(config.host)) {
            coroutineScope.launch {
                snackbarHostState.showMessage(
                    "TLS required: ${config.host} is not a private-network host. Enable TLS to connect.",
                )
            }
            return
        }
        coroutineScope.launch {
            // A refusal (cap of 8) leaves the hub's notice for the footer.
            hub.setEnabled(config.id, on)
            viewModel.refresh()
        }
    }

    // Pairing mode: null = closed, Manual = manual sheet, or prefilled from deep link
    var pairingMode by remember { mutableStateOf<PairingMode?>(null) }

    LaunchedEffect(pendingPairingUrl) {
        val url = pendingPairingUrl ?: return@LaunchedEffect
        pairingMode = PairingMode.Prefilled(url)
        clearPendingPairing()
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Servers") },
                actions = {
                    if (aggregate.enabledServers > 0) TextButton(onClick = onDone) { Text("Done") }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
        floatingActionButton = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloatingActionButton(onClick = onScanPair) {
                    Icon(Icons.Filled.QrCodeScanner, contentDescription = "Scan pairing QR code")
                }
                FloatingActionButton(onClick = { pairingMode = PairingMode.Manual }) {
                    Icon(Icons.Filled.Add, contentDescription = "Pair with Host")
                }
                FloatingActionButton(onClick = { sheetMode = ServerSheetMode.Add }) {
                    Icon(Icons.Filled.Storage, contentDescription = "Add Server")
                }
            }
        },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                if (sections.isEmpty()) {
                    EmptyServersState(
                        onAdd = { sheetMode = ServerSheetMode.Add },
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    PullToRefreshBox(
                        isRefreshing = isRefreshing,
                        onRefresh = {
                            viewModel.refresh()
                            hub.handleForegroundTransition()
                            isRefreshing = false
                        },
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        LazyColumn(modifier = Modifier.fillMaxSize()) {
                            itemsIndexed(sections, key = { _, s -> s.id }) { index, section ->
                                SwipeableServerRow(
                                    section = section,
                                    probe = statuses[section.id],
                                    onToggle = { on -> setEnabled(section.config, on) },
                                    onEdit = { sheetMode = ServerSheetMode.Edit(section.config) },
                                    onDelete = {
                                        coroutineScope.launch {
                                            hub.removeServer(section.id)
                                            viewModel.refresh()
                                        }
                                    },
                                )
                                if (index < sections.lastIndex) {
                                    HorizontalDivider(
                                        modifier = Modifier.padding(start = 16.dp),
                                        color = MaterialTheme.colorScheme.outlineVariant,
                                    )
                                }
                            }
                        }
                    }
                }
            }
            notice?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = Color(0xFFFF9500),
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
            }
            if (sections.isNotEmpty()) {
                Text(
                    "${aggregate.enabledServers} of ${aggregate.totalServers} enabled · up to ${ServerHub.MAX_ENABLED} at once",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 12.dp),
                )
            }
        }
    }

    sheetMode?.let { mode ->
        val initialToken = when (mode) {
            is ServerSheetMode.Edit -> viewModel.tokenFor(mode.config).orEmpty()
            ServerSheetMode.Add -> ""
        }
        AddEditServerSheet(
            mode = mode,
            initialToken = initialToken,
            onSave = { edited, token ->
                val refused = mode is ServerSheetMode.Add && !ServerPolling.addsEnabled(edited)
                val config = if (refused) edited.copy(enabled = false) else edited
                coroutineScope.launch {
                    if (refused) {
                        snackbarHostState.showMessage(
                            "Added disabled — TLS required: ${config.host} is not a private-network host.",
                        )
                    }
                }
                coroutineScope.launch {
                    viewModel.addOrUpdateInternal(config, token)
                    hub.reloadBookmarks()
                    // The hub cannot see the token store: a pasted token reaches
                    // the relay only through a fresh coordinator.
                    if (mode is ServerSheetMode.Edit) {
                        val section = hub.sections.value.firstOrNull { it.id == config.id }
                        if (section != null && ServerPolling.shouldRebuild(section)) hub.rebuildSlot(config.id)
                    }
                }
            },
            onDelete = {
                (mode as? ServerSheetMode.Edit)?.let { edit ->
                    coroutineScope.launch {
                        hub.removeServer(edit.config.id)
                        viewModel.refresh()
                    }
                }
            },
            onDismiss = { sheetMode = null },
        )
    }

    pairingMode?.let { mode ->
        val pairingVm = remember(mode) {
            PairingViewModel(
                controllerFactory = { PairingViewModel.createController(viewModel) },
            ).apply {
                if (mode is PairingMode.Prefilled) {
                    host = mode.url.host
                    port = mode.url.port.toString()
                    useTLS = mode.url.useTLS
                    code = mode.url.code
                }
            }
        }
        PairWithHostSheet(
            viewModel = pairingVm,
            onPaired = { _ ->
                pairingMode = null
                // Paired bookmarks are saved enabled; reloading builds the
                // coordinator (and enforces the cap with a notice).
                coroutineScope.launch {
                    hub.reloadBookmarks()
                    viewModel.refresh()
                }
            },
            onDismiss = { pairingMode = null },
        )
    }
}

/** Pairing sheet mode: manual entry or prefilled from deep link. */
private sealed interface PairingMode {
    data object Manual : PairingMode
    data class Prefilled(val url: relay.protocol.PairingURL) : PairingMode
}

private suspend fun SnackbarHostState.showMessage(message: String) {
    currentSnackbarData?.dismiss()
    showSnackbar(message)
}

/**
 * A row wrapped in a [SwipeToDismissBox] providing edit (start→end, blue) and
 * delete (end→start, red) actions. The swipe is consumed by re-arming the
 * dismiss state so the row settles back after firing.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeableServerRow(
    section: ServerSection,
    probe: ServerStatus?,
    onToggle: (Boolean) -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    // `rememberSwipeToDismissBoxState` keeps the FIRST composition's lambda for the
    // row's life (rows are keyed by id), so read the callbacks through
    // `rememberUpdatedState` or an edit would reopen the pre-edit bookmark.
    val currentOnEdit by rememberUpdatedState(onEdit)
    val currentOnDelete by rememberUpdatedState(onDelete)
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            when (value) {
                SwipeToDismissBoxValue.EndToStart -> { currentOnDelete(); false }
                SwipeToDismissBoxValue.StartToEnd -> { currentOnEdit(); false }
                SwipeToDismissBoxValue.Settled -> false
            }
        },
    )

    SwipeToDismissBox(
        state = dismissState,
        backgroundContent = { SwipeBackground(dismissState.dismissDirection) },
    ) {
        ServerRow(section = section, probe = probe, onToggle = onToggle, onClick = onEdit)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeBackground(direction: SwipeToDismissBoxValue) {
    val (color, icon, alignment, description) = when (direction) {
        SwipeToDismissBoxValue.EndToStart ->
            SwipeStyle(MaterialTheme.colorScheme.error, Icons.Filled.Delete, Alignment.CenterEnd, "Delete")
        SwipeToDismissBoxValue.StartToEnd ->
            SwipeStyle(Color(0xFF2196F3), Icons.Filled.Edit, Alignment.CenterStart, "Edit")
        SwipeToDismissBoxValue.Settled ->
            SwipeStyle(Color.Transparent, null, Alignment.Center, null)
    }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(color)
            .padding(horizontal = 20.dp),
        contentAlignment = alignment,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = description, tint = Color.White)
        }
    }
}

private data class SwipeStyle(
    val color: Color,
    val icon: androidx.compose.ui.graphics.vector.ImageVector?,
    val alignment: Alignment,
    val description: String?,
)

/** The status line under a bookmark: the live section for an enabled one, the poller's probe for a disabled one. */
internal fun statusLine(section: ServerSection, probe: ServerStatus?): Pair<String, StatusTone> {
    if (section.config.enabled) {
        return when (val st = section.status) {
            ServerSectionStatus.Live -> "Live" to StatusTone.GOOD
            ServerSectionStatus.Connecting -> "connecting…" to StatusTone.PENDING
            ServerSectionStatus.Reconnecting -> "reconnecting…" to StatusTone.PENDING
            ServerSectionStatus.Offline -> "offline" to StatusTone.BAD
            is ServerSectionStatus.AuthFailed -> st.message to StatusTone.WARN
            ServerSectionStatus.Disabled -> "disabled" to StatusTone.MUTED
        }
    }
    return when (probe) {
        ServerStatus.LIVE -> "disabled · reachable" to StatusTone.MUTED
        ServerStatus.OFFLINE -> "disabled · offline" to StatusTone.MUTED
        ServerStatus.CHECKING, null -> "disabled" to StatusTone.MUTED
    }
}

internal enum class StatusTone { GOOD, PENDING, WARN, BAD, MUTED }

/** One bookmark row: title, URL, status, instance id, duplicate flag and the Enabled switch. */
@Composable
private fun ServerRow(
    section: ServerSection,
    probe: ServerStatus?,
    onToggle: (Boolean) -> Unit,
    onClick: () -> Unit,
) {
    val config = section.config
    val (caption, tone) = statusLine(section, probe)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(text = config.title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
                if (section.isDuplicateInstance) {
                    Icon(
                        Icons.Filled.Warning,
                        contentDescription = "Another bookmark points at this same relay",
                        tint = Color(0xFFFF9500),
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
            Text(
                text = "${if (config.useTLS) "wss" else "ws"}://${config.host}:${config.port}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Dot(
                    when (tone) {
                        StatusTone.GOOD -> Color(0xFF4CAF50)
                        StatusTone.PENDING, StatusTone.WARN -> Color(0xFFFF9500)
                        StatusTone.BAD -> MaterialTheme.colorScheme.error
                        StatusTone.MUTED -> Color(0xFF8E8E93)
                    },
                )
                CaptionText(caption)
            }
            config.instanceId?.let { CaptionText("instance ${it.toString().take(8)}…") }
        }
        Switch(
            checked = config.enabled,
            onCheckedChange = onToggle,
            modifier = Modifier.semantics {
                contentDescription = if (config.enabled) "Disable ${config.title}" else "Enable ${config.title}"
            },
        )
    }
}

@Composable
private fun Dot(color: Color) {
    Box(
        modifier = Modifier
            .size(8.dp)
            .clip(CircleShape)
            .background(color),
    )
}

@Composable
private fun CaptionText(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/** Shown when no bookmarks exist, ported from the Swift `ContentUnavailableView`. */
@Composable
private fun EmptyServersState(onAdd: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.padding(32.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Filled.Storage,
            contentDescription = null,
            modifier = Modifier.size(48.dp).graphicsLayer(alpha = 0.6f),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text("No Servers", style = MaterialTheme.typography.titleMedium)
        Text(
            "Add a server to get started.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        FloatingActionButton(onClick = onAdd) {
            Row(
                modifier = Modifier.padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Filled.Add, contentDescription = null)
                Text("Add Server")
            }
        }
    }
}
