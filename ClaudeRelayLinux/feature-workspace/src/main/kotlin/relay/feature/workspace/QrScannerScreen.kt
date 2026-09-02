package relay.feature.workspace

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import java.util.UUID

/**
 * Desktop stand-in for the camera QR scanner.
 *
 * Android scans a `clauderelay://session/<uuid>` code with CameraX + ML Kit.
 * A desktop has no guaranteed camera, and — more to the point — the QR code is
 * being displayed *on another screen the user is already sitting at*, so
 * pasting the link is both simpler and more reliable than pointing a webcam at
 * a monitor.
 *
 * This renders an explanation rather than silently doing nothing, so the
 * affordance is never a dead end. Deep links arriving via the registered
 * `x-scheme-handler/clauderelay` handler reach the same attach path.
 */
@Composable
@Suppress("UNUSED_PARAMETER")
fun QrScannerScreen(
    onSessionScanned: (UUID) -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            "Scanning isn't available on the desktop",
            style = MaterialTheme.typography.titleMedium,
            textAlign = TextAlign.Center,
        )
        Text(
            "Open the clauderelay:// link directly, or attach the session from the list.",
            style = MaterialTheme.typography.bodyMedium,
            textAlign = TextAlign.Center,
        )
        OutlinedButton(onClick = onCancel) { Text("Back") }
    }
}
