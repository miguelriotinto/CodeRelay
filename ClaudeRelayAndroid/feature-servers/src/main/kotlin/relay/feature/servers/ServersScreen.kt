package relay.feature.servers

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
 * Server-list screen, ported from `ServerListView.swift`:
 *  - a [LazyColumn] of bookmarks, each row with name / host:port + a live/offline
 *    /checking status dot;
 *  - pull-to-refresh re-runs the status poll;
 *  - leading swipe → edit (blue), trailing swipe → delete (red);
 *  - an empty-state when no bookmarks exist;
 *  - a "+" FAB opens the add sheet OR the pairing sheet.
 *
 * Tapping a row routes to [onConnect] — but only after a friendly inline
 * cleartext pre-check (`CleartextPolicy.isPrivateNetworkHost`): a non-private host
 * over plain `ws://` is refused with a snackbar here, never connected. This is a
 * nicer early-UX message — it is NOT the only line of defense. The authoritative,
 * unbypassable gate now lives at the connect chokepoint
 * ([RelayConnection.connect] → `CleartextPolicy.requireAllowed`), so auto-connect,
 * deep-link attach, and the status probe are gated too even though they never go
 * through this screen. This replicates the iOS/macOS ATS behaviour explicitly
 * (Android's network-security-config can't express RFC1918 CIDR ranges).
 *
 * @param pendingPairingUrl when non-null, triggers the pairing sheet prefilled from
 * the URL (deep link from `claude-relay setup` QR scan, OR a QR scanned via
 * [onScanPair]). Both entry points converge on this one flow. The caller must
 * clear it via [clearPendingPairing] after consumption.
 * @param onScanPair opens the camera QR scanner. A scanned `coderelay://pair`
 * QR is parsed by the host and delivered back through [pendingPairingUrl], so the
 * scan and deep-link paths share the same prefilled-sheet consumption. The camera
 * lives in the app/workspace module, so the Servers screen only asks for it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ServersScreen(
    viewModel: ServersViewModel,
    onConnect: (ConnectionConfig) -> Unit,
    modifier: Modifier = Modifier,
    pendingPairingUrl: relay.protocol.PairingURL? = null,
    clearPendingPairing: () -> Unit = {},
    onScanPair: () -> Unit = {},
) {
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    val statuses by viewModel.statuses.collectAsStateWithLifecycle()

    val snackbarHostState = remember { SnackbarHostState() }
    val coroutineScope = rememberCoroutineScope()

    // Sheet state: null = closed, Add or Edit(config) = open.
    var sheetMode by remember { mutableStateOf<ServerSheetMode?>(null) }
    var isRefreshing by remember { mutableStateOf(false) }

    fun attemptConnect(config: ConnectionConfig) {
        // Friendly early-UX pre-check. The authoritative enforcement is the connect
        // chokepoint (RelayConnection.connect → CleartextPolicy.requireAllowed);
        // this just surfaces a clearer message before we even try.
        if (!config.useTLS && !CleartextPolicy.isPrivateNetworkHost(config.host)) {
            coroutineScope.launch {
                snackbarHostState.showMessage(
                    "TLS required: ${config.host} is not a private-network host. " +
                        "Enable TLS to connect.",
                )
            }
            return
        }
        onConnect(config)
    }

    // Pairing mode: null = closed, Manual = manual sheet, or prefilled from deep link
    var pairingMode by remember { mutableStateOf<PairingMode?>(null) }

    // Consume pending pairing deep link (Task 7→8 seam replacement)
    LaunchedEffect(pendingPairingUrl) {
        val url = pendingPairingUrl ?: return@LaunchedEffect
        pairingMode = PairingMode.Prefilled(url)
        clearPendingPairing()
    }

    Scaffold(
        modifier = modifier,
        topBar = { TopAppBar(title = { Text("Servers") }) },
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
        Box(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            if (servers.isEmpty()) {
                EmptyServersState(
                    onAdd = { sheetMode = ServerSheetMode.Add },
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                PullToRefreshBox(
                    isRefreshing = isRefreshing,
                    onRefresh = {
                        viewModel.refresh()
                        // The poll is fire-and-forget; clear the indicator promptly.
                        isRefreshing = false
                    },
                    modifier = Modifier.fillMaxSize(),
                ) {
                    LazyColumn(modifier = Modifier.fillMaxSize()) {
                        itemsIndexed(servers, key = { _, server -> server.id }) { index, server ->
                            SwipeableServerRow(
                                server = server,
                                status = statuses[server.id],
                                onConnect = { attemptConnect(server) },
                                onEdit = { sheetMode = ServerSheetMode.Edit(server) },
                                onDelete = { viewModel.delete(server) },
                            )
                            // A separator between rows, matching the inset
                            // dividers iOS gets for free from `List`. Each row is
                            // three unboxed lines of text on the same surface, so
                            // without this two servers read as one entry. Skipped
                            // after the last row: a trailing rule under an
                            // otherwise empty list looks like a cut-off row.
                            if (index < servers.lastIndex) {
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
    }

    sheetMode?.let { mode ->
        val initialToken = when (mode) {
            is ServerSheetMode.Edit -> viewModel.tokenFor(mode.config).orEmpty()
            ServerSheetMode.Add -> ""
        }
        AddEditServerSheet(
            mode = mode,
            initialToken = initialToken,
            onSave = { config, token -> viewModel.addOrUpdate(config, token) },
            onDelete = {
                (mode as? ServerSheetMode.Edit)?.let { viewModel.delete(it.config) }
            },
            onDismiss = { sheetMode = null },
        )
    }

    pairingMode?.let { mode ->
        val pairingVm = remember(mode) {
            PairingViewModel(
                controllerFactory = { PairingViewModel.createController(viewModel) },
            ).apply {
                // Prefill if from deep link
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
            onPaired = { config ->
                pairingMode = null
                // Auto-connect after successful pairing
                coroutineScope.launch { attemptConnect(config) }
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
 * dismiss state so the row settles back after firing — the list mutation (delete)
 * or sheet (edit) is the real effect.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeableServerRow(
    server: ConnectionConfig,
    status: ServerStatus?,
    onConnect: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            when (value) {
                SwipeToDismissBoxValue.EndToStart -> { onDelete(); false }
                SwipeToDismissBoxValue.StartToEnd -> { onEdit(); false }
                SwipeToDismissBoxValue.Settled -> false
            }
        },
    )

    SwipeToDismissBox(
        state = dismissState,
        backgroundContent = { SwipeBackground(dismissState.dismissDirection) },
    ) {
        ServerRow(server = server, status = status, onClick = onConnect)
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

/** One bookmark row: name + host:port + a live/offline/checking dot. */
@Composable
private fun ServerRow(
    server: ConnectionConfig,
    status: ServerStatus?,
    onClick: () -> Unit,
) {
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
            Text(
                text = server.name,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium,
            )
            Text(
                text = "${server.host}:${server.port}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            StatusIndicator(status = status)
        }
    }
}

/**
 * Live/offline/checking dot. Green = LIVE, red = OFFLINE, and a small spinner for
 * CHECKING / not-yet-probed (null) — the Android UI distinguishes "in flight"
 * from "checked, offline" (see `ServerStatusChecker.kt`).
 */
@Composable
private fun StatusIndicator(status: ServerStatus?) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        when (status) {
            ServerStatus.LIVE -> {
                Dot(Color(0xFF4CAF50))
                CaptionText("Live")
            }
            ServerStatus.OFFLINE -> {
                Dot(MaterialTheme.colorScheme.error)
                CaptionText("Offline")
            }
            ServerStatus.CHECKING, null -> {
                CircularProgressIndicator(
                    modifier = Modifier.size(8.dp),
                    strokeWidth = 1.5.dp,
                )
                CaptionText("Checking")
            }
        }
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
