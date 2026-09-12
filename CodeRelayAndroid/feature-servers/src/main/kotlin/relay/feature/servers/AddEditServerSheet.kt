package relay.feature.servers

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import relay.protocol.ConnectionConfig
import java.util.UUID

/**
 * Add/Edit mode for the server form, ported from
 * `AddEditServerViewModel.Mode`.
 */
sealed interface ServerSheetMode {
    data object Add : ServerSheetMode
    data class Edit(val config: ConnectionConfig) : ServerSheetMode
}

/**
 * Modal form for adding or editing a server bookmark. Configuration only — no
 * connection happens here (matches `AddEditServerView.swift`).
 *
 * State is hoisted into local `remember`ed fields so the sheet is self-contained;
 * the host caller supplies the mode (prefill source), an [initialToken] for edit
 * mode, and the [onSave] / [onDelete] / [onDismiss] callbacks. Save is disabled
 * while the host is blank, mirroring `AddEditServerViewModel.isValid`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddEditServerSheet(
    mode: ServerSheetMode,
    initialToken: String,
    onSave: (ConnectionConfig, String) -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
) {
    val existing = (mode as? ServerSheetMode.Edit)?.config
    val isEditing = existing != null

    var name by remember { mutableStateOf(existing?.name ?: "") }
    var host by remember { mutableStateOf(existing?.host ?: "") }
    var port by remember { mutableStateOf(existing?.port?.toString() ?: "9200") }
    var token by remember { mutableStateOf(initialToken) }
    var useTLS by remember { mutableStateOf(existing?.useTLS ?: false) }
    var tokenVisible by remember { mutableStateOf(false) }
    var showDeleteConfirm by remember { mutableStateOf(false) }

    val hostValid = ServerFormLogic.isHostValid(host)
    val portValid = ServerFormLogic.parsePort(port) != null
    val isValid = hostValid && portValid

    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = if (isEditing) "Edit Server" else "Add Server",
                style = MaterialTheme.typography.titleLarge,
            )

            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Server Name") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            OutlinedTextField(
                value = host,
                onValueChange = { host = it },
                label = { Text("Host") },
                singleLine = true,
                isError = host.isNotEmpty() && !hostValid,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )

            OutlinedTextField(
                value = port,
                onValueChange = { new -> port = new.filter { it.isDigit() } },
                label = { Text("Port") },
                singleLine = true,
                isError = port.isNotEmpty() && !portValid,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
            )

            OutlinedTextField(
                value = token,
                onValueChange = { token = it },
                label = { Text("Auth Token") },
                singleLine = true,
                visualTransformation = if (tokenVisible) {
                    VisualTransformation.None
                } else {
                    PasswordVisualTransformation()
                },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                trailingIcon = {
                    IconButton(onClick = { tokenVisible = !tokenVisible }) {
                        Icon(
                            imageVector = if (tokenVisible) {
                                Icons.Filled.VisibilityOff
                            } else {
                                Icons.Filled.Visibility
                            },
                            contentDescription = if (tokenVisible) "Hide token" else "Show token",
                        )
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Use TLS", style = MaterialTheme.typography.bodyLarge)
                Switch(
                    checked = useTLS,
                    onCheckedChange = { enabled ->
                        useTLS = enabled
                        port = ServerFormLogic.portForTLSChange(port, enabled)
                    },
                )
            }

            Button(
                onClick = {
                    val config = ServerFormLogic.buildConfig(
                        existingId = existing?.id ?: UUID.randomUUID(),
                        name = name,
                        host = host,
                        port = port,
                        useTLS = useTLS,
                    )
                    if (config != null) {
                        onSave(config, token)
                        onDismiss()
                    }
                },
                enabled = isValid,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Save")
            }

            if (isEditing) {
                OutlinedButton(
                    onClick = { showDeleteConfirm = true },
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = MaterialTheme.colorScheme.error,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Delete Server")
                }
            }
        }
    }

    if (showDeleteConfirm && existing != null) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            title = { Text("Delete Server") },
            text = {
                Text("Are you sure you want to delete \"${existing.name}\"? This cannot be undone.")
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showDeleteConfirm = false
                        onDelete()
                        onDismiss()
                    },
                ) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = false }) { Text("Cancel") }
            },
        )
    }
}
