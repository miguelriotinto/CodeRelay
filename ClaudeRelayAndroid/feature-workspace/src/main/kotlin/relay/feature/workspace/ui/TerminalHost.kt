package relay.feature.workspace.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import relay.terminal.RelayTerminalController
import relay.terminal.TerminalPalette
import relay.terminal.TerminalSessionVm

/** ARGB int (TerminalPalette) → Compose [Color]. */
private fun Int.toComposeColor(): Color = Color(this)

/**
 * Hosts the active session's terminal.
 *
 * // M2 text-fallback; real Termux TerminalEngine binding is M-future per
 * // terminal/TERMUX_INTEGRATION.md
 *
 * The real Termux VT view is DEFERRED, so this hosts a [TextFallbackTerminalEngine]
 * — but it exercises the FULL real byte path: the engine is driven by the real
 * [RelayTerminalController] bound to the active [TerminalSessionVm]. Output bytes
 * flow `relay → vm.onTerminalOutput → controller → engine.feedOutput → text`;
 * keystrokes flow `engine.onInput → controller → onInput` (the workspace wires
 * `onInput` to the connection's binary send). The [KeyboardAccessory] in the
 * status column feeds its bytes through the same [onInput] callback.
 *
 * Rendering uses [TerminalPalette.background] / [TerminalPalette.foreground] for
 * the bg/fg colors so the placeholder already adopts the canonical palette where
 * a text fallback can (per-cell ANSI coloring arrives with the real engine).
 *
 * A new controller+engine is built per [vm] identity ([remember] keyed on `vm`),
 * so switching sessions rebinds cleanly. The controller is [detach]ed on dispose
 * / when the keyed `vm` changes.
 *
 * @param vm the active session's buffering view-model (from the coordinator cache)
 * @param onInput engine → relay keystroke sink (wired to `connection.sendBinary`)
 * @param modifier outer modifier
 */
@Composable
fun TerminalHost(
    vm: TerminalSessionVm,
    onInput: (ByteArray) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Build the engine + controller for this VM. Keyed on `vm` so a session
    // switch (new VM from the cache) rebuilds the seam.
    val engine = remember(vm) { TextFallbackTerminalEngine() }
    val controller = remember(vm) {
        RelayTerminalController(
            engine = engine,
            vm = vm,
            onInput = onInput,
            // The text fallback has no PTY-size meaning; report a nominal grid so
            // the relay still gets a resize and the controller fires the one-shot
            // terminalReady() that drains buffered scrollback. Real geometry
            // arrives with the Termux view.
            onResize = { _, _ -> },
        )
    }

    // First layout → reportSize once. The real Termux view calls this from its
    // first layout callback; here we synthesize a nominal 80x24 grid so
    // RelayTerminalController.reportSize() turns into vm.terminalReady() and
    // buffered scrollback flushes (the same role M1DemoScreen's direct
    // terminalReady() call played).
    LaunchedEffect(controller) {
        controller.reportSize(cols = 80, rows = 24)
    }

    DisposableEffect(controller) {
        onDispose { controller.detach() }
    }

    var input by remember(vm) { mutableStateOf("") }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(TerminalPalette.background.toComposeColor()),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
        ) {
            val scrollState = rememberScrollState()
            // Auto-scroll to bottom as new output arrives.
            LaunchedEffect(engine.text) {
                scrollState.scrollTo(scrollState.maxValue)
            }
            Text(
                text = engine.text.ifEmpty { "(no terminal output yet)" },
                color = TerminalPalette.foreground.toComposeColor(),
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(scrollState)
                    .padding(8.dp),
            )
        }

        // Typed UTF-8 input row → onInput (engine's onInput sink would normally
        // carry typed chars; the text fallback has no editable grid, so we route
        // typed input straight through the same upstream callback the controller
        // installs for the engine). Pressing the IME Send action sends the line
        // plus a CR — the same bytes a real keystroke stream would emit.
        fun sendLine() {
            val line = input
            if (line.isNotEmpty()) {
                onInput((line + "\r").toByteArray(Charsets.UTF_8))
            }
            input = ""
        }
        OutlinedTextField(
            value = input,
            onValueChange = { input = it },
            singleLine = true,
            label = { Text("Input") },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { sendLine() }),
            modifier = Modifier
                .fillMaxWidth()
                .padding(8.dp),
        )
    }
}
