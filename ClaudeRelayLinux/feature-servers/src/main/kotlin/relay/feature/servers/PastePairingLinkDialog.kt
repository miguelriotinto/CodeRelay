package relay.feature.servers

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import relay.protocol.PairingURL

/**
 * The desktop stand-in for the camera pairing scanner.
 *
 * `claude-relay setup` prints the pairing QR *and* the `coderelay://pair?…`
 * URL it encodes, in a terminal on the Mac. On a desktop the user copies that
 * line and pastes it here; the parsed [PairingURL] then prefills the same
 * `PairWithHostSheet` a scanned QR would, so both entry points converge on one
 * flow — exactly the structure the Android nav graph has for its scanner.
 *
 * Parsing is [PairingURL.parse], the single tested place for hostile pairing
 * input, so this dialog adds no validation of its own.
 */
@Composable
fun PastePairingLinkDialog(
    onParsed: (PairingURL) -> Unit,
    onDismiss: () -> Unit,
) {
    var text by remember { mutableStateOf("") }
    val parsed = remember(text) { parsePairingLink(text) }
    val showError = text.isNotBlank() && parsed == null

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Paste pairing link") },
        text = {
            Column {
                Text(
                    "Run `claude-relay setup` on the host and paste the coderelay://pair link it prints.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    label = { Text("coderelay://pair?…") },
                    singleLine = true,
                    isError = showError,
                    supportingText = if (showError) {
                        { Text("That is not a pairing link.") }
                    } else {
                        null
                    },
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { parsed?.let(onParsed) },
                enabled = parsed != null,
            ) { Text("Pair") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/**
 * Accepts the raw URL, or a whole line pasted from the setup output that
 * contains one. Returns null for anything else.
 */
internal fun parsePairingLink(raw: String): PairingURL? {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) return null
    val candidate = trimmed.split(Regex("\\s+")).firstOrNull { it.startsWith("coderelay://", ignoreCase = true) }
        ?: trimmed
    return runCatching { PairingURL.parse(candidate) }.getOrNull()
}
