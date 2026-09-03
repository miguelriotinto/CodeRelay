package relay.feature.workspace.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import relay.terminal.RelayTerminalController
import relay.terminal.TerminalSessionVm
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import relay.terminal.linux.DesktopTerminalFont
import relay.terminal.linux.LocalTerminalTheme
import relay.terminal.linux.LinuxTerminalEmulator
import relay.terminal.linux.LinuxTerminalEngine
import relay.terminal.linux.TerminalView

/**
 * Hosts the live terminal for one session.
 *
 * Linux counterpart of the Android `TerminalHost`. Same signature, so the shared
 * `WorkspaceScreen` composes it unchanged. Two things differ:
 *
 *  1. **The engine.** Android binds termlib's Android renderer; we bind
 *     [LinuxTerminalEmulator] (libvterm through the same JNI bridge, built for
 *     x86_64) and draw the grid with the Compose Desktop [TerminalView].
 *  2. **No soft-keyboard plumbing.** Android's version reaches for
 *     `LocalView` + `WindowInsetsCompat` to raise the IME. A desktop has a
 *     physical keyboard, so that whole path disappears rather than being stubbed.
 *
 * ### Why the engine is remembered per session
 *
 * Each session owns an emulator with its own libvterm state — scrollback,
 * cursor, alternate-buffer flag, the lot. Keying [remember] on the view model
 * means switching tabs preserves each terminal's screen instead of replaying it
 * from scratch, and closing a session disposes its native allocation.
 */
@Composable
fun TerminalHost(
    vm: TerminalSessionVm,
    onInput: (ByteArray) -> Unit,
    onResize: (cols: Int, rows: Int) -> Unit,
    redrawToken: Int = 0,
    modifier: Modifier = Modifier,
    // Defaults come from the ambient terminal theme, which `:app` fills from the
    // live Omarchy palette. They used to be null/black/white, so the grid rendered
    // pure white on pure black next to Foot windows in the desktop's own colours —
    // the theme was loaded, mapped and tested, and then never reached the terminal.
    palette: IntArray? = LocalTerminalTheme.current.ansi,
    background: Color = Color(LocalTerminalTheme.current.background),
    foreground: Color = Color(LocalTerminalTheme.current.foreground),
) {
    // One emulator + engine per session, disposed with it.
    val emulator = remember(vm) {
        LinuxTerminalEmulator(
            initialRows = 24,
            initialCols = 80,
            palette = palette,
            defaultForeground = foreground.toArgbInt(),
            defaultBackground = background.toArgbInt(),
        )
    }
    val engine = remember(emulator) { LinuxTerminalEngine(emulator) }

    // The controller wires engine ↔ view model: it installs the engine's input
    // sink, forwards size reports, and turns the first size report into
    // `terminalReady()`, which drains buffered scrollback. This is shared,
    // pure-Kotlin code — the same object that drives Android and iOS.
    //
    // **Keyed on (engine, vm) only, with the callbacks read through
    // `rememberUpdatedState`.** Keying on the lambdas too rebuilt the controller
    // whenever a caller passed a fresh lambda identity — on the SAME engine. The
    // outgoing instance's `detach()` then ran against the live engine and view
    // model and tore down the incoming one's wiring: `engine.onInput = null`
    // stopped every keystroke reaching the shell, and the released ownership
    // stopped output reaching the pane, so a reload cleared the screen and
    // nothing came back. One controller per engine+vm, callbacks always current.
    val currentOnInput by rememberUpdatedState(onInput)
    val currentOnResize by rememberUpdatedState(onResize)
    val controller = remember(engine, vm) {
        RelayTerminalController(
            engine = engine,
            vm = vm,
            onInput = { bytes -> currentOnInput(bytes) },
            onResize = { cols, rows -> currentOnResize(cols, rows) },
        )
    }

    // `detach()` on dispose matches Android: it clears the engine's input sink
    // unconditionally, and the view model's only if this controller is still its
    // owner — so switching sessions cannot have the outgoing pane's teardown
    // unwire the incoming one, which binds first.
    DisposableEffect(controller) { onDispose { controller.detach() } }

    DisposableEffect(emulator) {
        onDispose {
            // Frees the native VTerm. Without this every closed tab leaks a
            // libvterm allocation for the life of the process.
            emulator.close()
        }
    }

    // Relay → emulator is the CONTROLLER's job (`vm.onTerminalOutput →
    // engine.feedOutput`), installed in its constructor and released through the
    // ownership token. This host deliberately does not also set that handler:
    // the duplicate wiring it used to carry nulled `onTerminalOutput`
    // unconditionally on dispose, which is exactly what the ownership check
    // exists to prevent.

    // [redrawToken] is deliberately NOT acted on here.
    //
    // On Android it drives `engine.redraw()`, a purely local repaint that pokes
    // termlib's renderer. Ours has nothing to poke: the grid is re-read from the
    // emulator every frame, so a local repaint is a no-op by construction.
    //
    // This host used to call `vm.beginServerReload()` on the token instead, and
    // that actively BROKE the name-tap reload. `beginServerReload` is the
    // coordinator's to call: `reloadTerminalFromServer` starts with
    // `if (vm.isReloadingFromServer.value) return` — a guard against a re-tap
    // landing on a replay still in flight. Calling it here first tripped that
    // guard, so the coordinator dropped the reload and never sent the resume.
    // The pane cleared to the RIS, no replay ever arrived, and five seconds
    // later the vm's backstop flushed an empty buffer: black, a long pause, then
    // an empty terminal. The reload is driven entirely by `WorkspaceScreen`
    // (`vm.reloadTerminal()` → coordinator → begin + resume), with the fade
    // cover held until `isReloadingFromServer` clears.

    // Re-theme live when the palette changes (Omarchy theme switch).
    LaunchedEffect(palette, background, foreground) {
        palette?.let { emulator.applyPalette(it, foreground.toArgbInt(), background.toArgbInt()) }
    }

    // Match the size and face the user's other terminals are rendering at —
    // read once per host, from the same Foot/Alacritty config those windows use.
    val font = remember { DesktopTerminalFont.load() }
    val fontFamily = remember(font.family) { DesktopTerminalFont.resolveFamily(font.family) }

    Box(modifier.fillMaxSize()) {
        TerminalView(
            emulator = emulator,
            engine = engine,
            modifier = Modifier.fillMaxSize(),
            background = background,
            foreground = foreground,
            fontSize = font.sizeDp.sp,
            fontFamily = fontFamily,
            padding = font.padDp.dp,
            // MUST go through the controller, not straight to `onResize`.
            // `reportSize` does three things: resizes the engine, forwards the
            // geometry to the relay, and — on the FIRST report — calls
            // `vm.terminalReady()`, which is what drains the output the vm
            // buffers until the view has a size. Wiring `onResize` directly
            // skipped all three: libvterm stayed at its initial 24x80 whatever
            // the window did, and every byte the shell produced went into
            // `pendingOutput` and stayed there — a terminal showing nothing but
            // a cursor on a session that was otherwise healthy.
            onSizeChanged = controller::reportSize,
        )
    }
}

/** Compose [Color] → the packed opaque ARGB int libvterm's palette API takes. */
private fun Color.toArgbInt(): Int {
    val a = (alpha * 255f + 0.5f).toInt().coerceIn(0, 255)
    val r = (red * 255f + 0.5f).toInt().coerceIn(0, 255)
    val g = (green * 255f + 0.5f).toInt().coerceIn(0, 255)
    val b = (blue * 255f + 0.5f).toInt().coerceIn(0, 255)
    return (a shl 24) or (r shl 16) or (g shl 8) or b
}
