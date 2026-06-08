package relay.app

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import relay.net.CleartextPolicy
import relay.net.RelayConnection
import relay.net.SessionController
import relay.protocol.ConnectionConfig
import relay.terminal.KeyboardAccessory
import relay.terminal.TerminalSessionVm

/**
 * M1 throwaway demo. Drives the M1 happy path against the REAL stack
 * (:core-protocol → :core-net → :core-storage → :terminal) to prove the byte
 * path end-to-end:
 *
 *   RelayConnection.connect → SessionController.authenticate → createSession →
 *   wire conn.onTerminalOutput → TerminalSessionVm.receiveOutput →
 *   vm.onTerminalOutput → on-screen text; KeyboardAccessory / typed input →
 *   conn.sendBinary.
 *
 * DELIBERATE DEMO SHORTCUTS (replaced by the real nav graph + Termux VT view in M2):
 *  - One file, no architecture, no DI (Hilt deferred to M2).
 *  - The live VT view (Termux `TerminalView`) is DEFERRED per
 *    `terminal/TERMUX_INTEGRATION.md`. Here we render captured bytes as a
 *    scrollable monospace [Text] (UTF-8 lossy decode) — a TEXT FALLBACK that
 *    proves the byte path without a real terminal emulator.
 *  - There is no engine reporting a terminal size, so we call [vm.terminalReady]
 *    directly after wiring the callbacks to flush buffered output. The real app
 *    calls it from the view's first layout callback.
 *  - The auth token is NEVER hardcoded — the user fills the token field.
 */
@Composable
fun M1DemoScreen() {
    val scope = rememberCoroutineScope()

    // 10.0.2.2 is the Android-emulator alias for the host machine's loopback,
    // where a dev relay server typically listens on 9200.
    var host by remember { mutableStateOf("10.0.2.2") }
    var token by remember { mutableStateOf("") }
    var input by remember { mutableStateOf("") }

    var status by remember { mutableStateOf("Idle") }
    var terminalText by remember { mutableStateOf("") }

    // Held across recompositions so the keyboard/input bar can send after Connect.
    val connectionHolder = remember { arrayOfNulls<RelayConnection>(1) }

    val scrollState = rememberScrollState()

    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text("Claude Relay — M1 demo", style = MaterialTheme.typography.titleMedium)

            OutlinedTextField(
                value = host,
                onValueChange = { host = it },
                label = { Text("Host") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            OutlinedTextField(
                value = token,
                onValueChange = { token = it },
                label = { Text("Auth token") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            Button(
                onClick = {
                    scope.launch {
                        runHappyPath(
                            host = host,
                            token = token,
                            connectionHolder = connectionHolder,
                            setStatus = { status = it },
                            appendTerminal = { terminalText += it }
                        )
                    }
                },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Connect")
            }

            Text("Status: $status", style = MaterialTheme.typography.bodyMedium)

            // TEXT FALLBACK for the deferred Termux VT view: captured terminal
            // bytes decoded UTF-8-lossy into a scrollable monospace block.
            Surface(
                color = Color.Black,
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
            ) {
                Text(
                    text = terminalText.ifEmpty { "(no terminal output yet)" },
                    color = Color(0xFFE0E0E0),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(scrollState)
                        .padding(8.dp)
                )
            }

            // Special-keys bar — each key sends raw bytes over the live socket.
            KeyboardAccessory(
                onKey = { bytes ->
                    val conn = connectionHolder[0]
                    if (conn != null) {
                        scope.launch { runCatching { conn.sendBinary(bytes) } }
                    }
                }
            )

            // Typed UTF-8 input → sendBinary.
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { input = it },
                    label = { Text("Input") },
                    singleLine = true,
                    modifier = Modifier.weight(1f)
                )
                Button(
                    onClick = {
                        val conn = connectionHolder[0]
                        val text = input
                        if (conn != null && text.isNotEmpty()) {
                            scope.launch { runCatching { conn.sendBinary(text.toByteArray(Charsets.UTF_8)) } }
                            input = ""
                        }
                    }
                ) {
                    Text("Send")
                }
            }

            Spacer(modifier = Modifier.height(2.dp))
        }
    }
}

/**
 * The M1 happy path against the real stack. Kept as a plain suspend function
 * (not a ViewModel) — this is a throwaway demo.
 */
private suspend fun runHappyPath(
    host: String,
    token: String,
    connectionHolder: Array<RelayConnection?>,
    setStatus: (String) -> Unit,
    appendTerminal: (String) -> Unit,
) {
    // 1) Build the connection config (plain ws://, port 9200).
    val config = ConnectionConfig(name = "dev", host = host, port = 9200u, useTLS = false)

    // 2) Gate cleartext exactly like iOS/macOS: ws:// only to private hosts.
    if (!config.useTLS && !CleartextPolicy.isPrivateNetworkHost(host)) {
        setStatus("TLS required for non-private host \"$host\" — refusing ws://")
        return
    }

    val conn = RelayConnection()
    connectionHolder[0] = conn

    try {
        // 3a) Connect.
        setStatus("Connecting to ${config.wsUrl} …")
        conn.connect(config, token)

        // 3b) Authenticate.
        setStatus("Authenticating …")
        val controller = SessionController(conn)
        controller.authenticate(token)

        // 3c) Create a session.
        setStatus("Creating session …")
        val sessionId = controller.createSession("android-m1")

        // 3d) Wire the byte path: socket → vm → on-screen text.
        val vm = TerminalSessionVm()
        vm.onTerminalOutput = { bytes ->
            appendTerminal(String(bytes, Charsets.UTF_8))
        }
        conn.onTerminalOutput = { bytes -> vm.receiveOutput(bytes) }

        // No engine reports a size in this demo, so flush directly. The real app
        // calls terminalReady() from the Termux view's first layout callback.
        vm.terminalReady()

        setStatus("Authenticated — session $sessionId")
    } catch (e: Exception) {
        setStatus("Error: ${e.message ?: e.toString()}")
    }
}
