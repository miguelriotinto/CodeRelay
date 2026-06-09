package relay.feature.workspace.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import relay.protocol.SessionInfo
import java.util.UUID

/**
 * The attach-session modal, ported from `SessionSidebarView.swift`'s
 * `AttachSessionSheet`. Presented when the user taps **Attach**.
 *
 * Mirrors the iOS hierarchy exactly:
 *  - a list of attachable sessions — sessions running on OTHER devices (the
 *    `coordinator.fetchAttachableSessions()` result, already filtered to
 *    non-terminal sessions this device does not own), each row showing the name,
 *    short id, and a state badge; tapping one dismisses the sheet and calls
 *    [onAttachSession] (→ `coordinator.attachRemoteSession`);
 *  - an empty state when there are none (iOS `ContentUnavailableView`);
 *  - a divider, then a **Scan QR Code** row that opens the camera scanner
 *    ([QrScannerSheet] below) NESTED over this sheet (iOS `.sheet(showScanner)`).
 *
 * Dismissal: swipe-down or tapping outside (the `ModalBottomSheet` scrim) — the
 * iOS Cancel toolbar button analog. The nested scanner has its own Cancel.
 *
 * @param sessions attachable remote sessions (already fetched by the caller)
 * @param nameFor display-name lookup (falls back to short id), Swift `coordinator.name(for:)`
 * @param onAttachSession tap a session → attach to it `(id, name)`
 * @param onScannedSession a QR scan resolved to a session id → attach to it
 * @param onDismiss close the whole attach flow
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AttachSessionSheet(
    sessions: List<SessionInfo>,
    nameFor: (UUID) -> String,
    onAttachSession: (UUID, String?) -> Unit,
    onScannedSession: (UUID) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    // Whether the nested camera scanner is showing over this sheet.
    var showScanner by remember { mutableStateOf(false) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp),
        ) {
            Text(
                text = "Attach Session",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
            )

            if (sessions.isEmpty()) {
                EmptyAttachState()
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        // Cap so a long list doesn't push the Scan QR row off-screen;
                        // the list scrolls within the sheet (iOS List inside the sheet).
                        .heightIn(max = 360.dp),
                ) {
                    items(sessions, key = { it.id }) { session ->
                        AttachSessionRow(
                            session = session,
                            name = session.name ?: nameFor(session.id),
                            onClick = {
                                onAttachSession(session.id, session.name)
                            },
                        )
                    }
                }
            }

            HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))

            // "Scan QR Code" row (iOS Label + qrcode.viewfinder).
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { showScanner = true }
                    .padding(horizontal = 20.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
            ) {
                Icon(
                    Icons.Filled.QrCodeScanner,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                )
                Text(
                    text = "Scan QR Code",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(start = 10.dp),
                )
            }
        }
    }

    if (showScanner) {
        QrScannerSheet(
            onScanned = { id ->
                showScanner = false
                onScannedSession(id)
            },
            onCancel = { showScanner = false },
        )
    }
}

/**
 * Full-screen camera QR scanner with a dismiss affordance, ported from iOS
 * `QRScannerSheet` (`NavigationStack` + Cancel toolbar over a full-bleed camera).
 *
 * Presented as a [ModalBottomSheet] at full height so it covers the attach sheet;
 * the camera preview ([QrScannerScreen]) fills it, and a top bar with a **Cancel**
 * button overlays the live camera so the user can always back out (the reported
 * "no way to dismiss the camera" bug — the bare [QrScannerScreen] only had a
 * Cancel in its permission-denied state, never over the active preview).
 *
 * @param onScanned a QR resolved to a session id (caller attaches + dismisses)
 * @param onCancel leave the scanner without scanning
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun QrScannerSheet(
    onScanned: (UUID) -> Unit,
    onCancel: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onCancel,
        sheetState = sheetState,
        // Edge-to-edge so the camera can fill; the drag handle + our Cancel row
        // sit above the preview.
        dragHandle = null,
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 480.dp),
        ) {
            relay.feature.workspace.QrScannerScreen(
                onSessionScanned = onScanned,
                onCancel = onCancel,
                modifier = Modifier.matchParentSize(),
            )

            // Cancel overlay — always available over the live camera (top-trailing,
            // iOS toolbar Cancel). Sits on top of the preview via Box z-order.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(12.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                androidx.compose.material3.FilledTonalButton(onClick = onCancel) {
                    Text("Cancel")
                }
            }
        }
    }
}

@Composable
private fun AttachSessionRow(
    session: SessionInfo,
    name: String,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
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
                text = session.id.toString().take(8),
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        Spacer(modifier = Modifier.weight(0.001f))

        AttachStateBadge(state = session.state)
    }
}

/** State badge capsule, colored by [WorkspaceLogic.badgeBucket] (shared with the sidebar). */
@Composable
private fun AttachStateBadge(state: relay.protocol.SessionState) {
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
                shape = RoundedCornerShape(50),
            )
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

@Composable
private fun EmptyAttachState() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 32.dp, vertical = 28.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Filled.Terminal,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = "No Sessions Available",
            style = MaterialTheme.typography.titleSmall,
        )
        Text(
            text = "There are no other sessions running on the server.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
