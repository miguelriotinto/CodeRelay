package relay.feature.workspace.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import relay.terminal.RelayTerminalController
import relay.terminal.TerminalSessionVm
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
    palette: IntArray? = null,
    background: Color = Color.Black,
    foreground: Color = Color.White,
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
    val controller = remember(engine, vm, onInput, onResize) {
        RelayTerminalController(engine, vm, onInput, onResize)
    }

    // Constructing the controller is what wires engine ↔ view model; keeping the
    // reference alive for the composition's lifetime is the whole point.
    DisposableEffect(controller) { onDispose { } }

    DisposableEffect(emulator) {
        onDispose {
            // Frees the native VTerm. Without this every closed tab leaks a
            // libvterm allocation for the life of the process.
            emulator.close()
        }
    }

    // Relay → emulator. TerminalSessionVm buffers output while replaying and
    // flushes it in one batch on endReplay(), so the grid shows the final state
    // instead of animating history past the user.
    DisposableEffect(vm, engine) {
        vm.onTerminalOutput = { bytes -> engine.feedOutput(bytes) }
        onDispose { vm.onTerminalOutput = null }
    }

    // A redraw token change means the user asked for a reload; ask the server
    // for a repaint rather than clearing locally, so the grid is rebuilt from
    // the authoritative screen instead of going briefly blank.
    LaunchedEffect(redrawToken) {
        if (redrawToken > 0) vm.beginServerReload()
    }

    // Re-theme live when the palette changes (Omarchy theme switch).
    LaunchedEffect(palette, background, foreground) {
        palette?.let { emulator.applyPalette(it, foreground.toArgbInt(), background.toArgbInt()) }
    }

    Box(modifier.fillMaxSize()) {
        TerminalView(
            emulator = emulator,
            engine = engine,
            modifier = Modifier.fillMaxSize(),
            background = background,
            foreground = foreground,
            onSizeChanged = onResize,
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
