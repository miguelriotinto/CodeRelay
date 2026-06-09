package relay.feature.workspace.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.ViewCompat
import org.connectbot.terminal.Terminal
import relay.terminal.RelayTerminalController
import relay.terminal.TerminalPalette
import relay.terminal.TerminalSessionVm

/** ARGB int (TerminalPalette) → Compose [Color]. */
private fun Int.toComposeColor(): Color = Color(this)

/**
 * Hosts the active session's terminal using the real VT100/xterm engine
 * (ConnectBot `termlib` via [TermlibTerminalEngine]). This replaces the M2/M3
 * `TextFallbackTerminalEngine` that rendered raw ANSI control codes as glyphs.
 *
 * Android analog of iOS's `RelayTerminalView` (`RelayTerminalView.swift`). The
 * full real byte path runs through the pure-Kotlin [RelayTerminalController] bound
 * to the active [TerminalSessionVm]:
 *
 *  - **Output:** `relay → vm.onTerminalOutput → controller → engine.feedOutput →
 *    emulator.writeInput` (byte-faithful — no `String` decode).
 *  - **Input:** termlib's soft keyboard / hardware keys → `emulator.onKeyboardInput
 *    → engine.onInput → controller → onInput` (wired to the connection's binary
 *    send). The [relay.terminal.KeyboardAccessory] special-key bar in the status
 *    column feeds the SAME [onInput] callback directly (a disjoint byte source —
 *    no double-input with termlib's own keyboard).
 *  - **Size:** termlib's `Terminal` composable measures its own geometry and calls
 *    `emulator.resize()`, which posts the factory `onResize`; the engine bridges
 *    that to [RelayTerminalController.reportSize], which (a) forwards the REAL
 *    on-screen grid upstream via [onResize] so the server PTY matches, and (b)
 *    fires the one-shot [TerminalSessionVm.terminalReady] that flushes buffered
 *    scrollback at the correct size. See [TermlibTerminalEngine] for why the grid
 *    starts at a 1×1 sentinel (guarantees that first `onResize`).
 *
 * A new controller + engine (and thus a fresh libvterm emulator) is built per
 * [vm] identity ([remember] keyed on `vm`), so switching sessions rebinds cleanly;
 * the controller is [RelayTerminalController.detach]ed on dispose / `vm` change.
 *
 * @param vm the active session's buffering view-model (from the coordinator cache)
 * @param onInput engine → relay keystroke sink (wired to `connection.sendBinary`)
 * @param onResize relay PTY-resize sink, invoked `(cols, rows)` (wired to
 *   `WorkspaceViewModel.sendResize`)
 * @param modifier outer modifier
 */
@Composable
fun TerminalHost(
    vm: TerminalSessionVm,
    onInput: (ByteArray) -> Unit,
    onResize: (cols: Int, rows: Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Late-bound resize bridge. The engine is built before the controller (the
    // controller needs the engine), but the engine's factory `onResize` must call
    // `controller.reportSize`. A single-slot holder breaks that cycle: the engine
    // forwards into the holder, the controller fills the holder once built. (Plain
    // holder, NOT snapshot state — it is a callback reference, not UI state, and is
    // only invoked from termlib's main-looper-posted resize, never during
    // composition.)
    val reportSizeHolder = remember(vm) { arrayOfNulls<(Int, Int) -> Unit>(1) }

    val engine = remember(vm) {
        TermlibTerminalEngine(
            onResize = { cols, rows -> reportSizeHolder[0]?.invoke(cols, rows) },
        )
    }
    val controller = remember(vm) {
        RelayTerminalController(
            engine = engine,
            vm = vm,
            onInput = onInput,
            // The relay PTY-resize sink. reportSize() calls this with the REAL grid
            // termlib measured, so the server PTY window matches what's on screen.
            onResize = onResize,
        ).also { reportSizeHolder[0] = it::reportSize }
    }

    // Re-show the soft keyboard when the user taps the terminal. termlib types
    // through its OWN raw `ImeInputView` (an Android View with a custom
    // InputConnection), NOT a Compose text field — so `LocalSoftwareKeyboardController`
    // does nothing here (that only drives the Compose IME). termlib's tap handler
    // calls `focusRequester.requestFocus()` (focusing the View that hosts the
    // ImeInputView) but only calls its internal `showIme()` from a
    // `LaunchedEffect(shouldShowIme)`, which does NOT re-fire after a MANUAL
    // swipe-down (shouldShowIme stays true). So we force the platform IME up via
    // the window insets controller from `onTerminalTap`, after termlib has focused
    // its input view. This is the platform-level API that drives the same IME
    // termlib's ImeInputView uses (`InputMethodManager.showSoftInput`).
    val view = LocalView.current

    DisposableEffect(controller) {
        onDispose {
            controller.detach()
            // Null the slot so a resize that termlib already posted to the main
            // looper for THIS engine can't land after dispose and drive a
            // detached controller's reportSize (which would push this session's
            // stale grid into whatever session is active next). The engine's
            // onResize reads `reportSizeHolder[0]?.invoke(...)`, so a null slot
            // makes the late callback a no-op. Belt-and-suspenders with detach().
            reportSizeHolder[0] = null
        }
    }

    // The real VT grid. termlib owns sizing (auto-fits cols×rows to the available
    // space at its monospace font); keyboardEnabled=true gives normal soft-keyboard
    // typing straight into the live grid (the accessory bar handles special keys).
    Terminal(
        terminalEmulator = engine.emulator,
        keyboardEnabled = true,
        // termlib focuses its ImeInputView on tap; we then force the platform IME
        // up (it stays down on tap after a manual swipe-down otherwise — see above).
        onTerminalTap = {
            ViewCompat.getWindowInsetsController(view)?.show(WindowInsetsCompat.Type.ime())
        },
        backgroundColor = TerminalPalette.background.toComposeColor(),
        foregroundColor = TerminalPalette.foreground.toComposeColor(),
        modifier = modifier
            .fillMaxSize()
            .background(TerminalPalette.background.toComposeColor()),
    )
}
