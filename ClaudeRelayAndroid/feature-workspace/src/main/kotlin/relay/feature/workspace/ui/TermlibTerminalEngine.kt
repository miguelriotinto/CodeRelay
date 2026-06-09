package relay.feature.workspace.ui

import androidx.compose.ui.graphics.Color
import org.connectbot.terminal.TerminalDimensions
import org.connectbot.terminal.TerminalEmulator
import org.connectbot.terminal.TerminalEmulatorFactory
import relay.terminal.TerminalEngine
import relay.terminal.TerminalPalette

/**
 * The real VT100/xterm [TerminalEngine], backed by ConnectBot's `termlib`
 * (`org.connectbot:termlib`) — a libvterm emulator (JNI) plus a Jetpack Compose
 * renderer. This replaces the M2/M3 `TextFallbackTerminalEngine`, which rendered
 * raw ANSI control codes (`[1m`, `[7m`, `[?2004h`, …) as literal glyphs because it
 * did no escape-sequence parsing.
 *
 * This is the Android analog of iOS's SwiftTerm binding (`RelayTerminalView` +
 * `IOSTerminalCoordinator`). It satisfies the same [TerminalEngine] seam so the
 * pure-Kotlin [relay.terminal.RelayTerminalController] drives it unchanged over
 * the real byte path.
 *
 * ## The three edges (and the one inversion vs. the seam's original assumption)
 *
 *  - **Output (relay → grid):** [feedOutput] forwards bytes verbatim to
 *    [TerminalEmulator.writeInput] — no `String` round-trip, so UTF-8 runes and
 *    escape sequences split across frames survive (mirrors iOS `feed(byteArray:)`).
 *  - **Input (grid → relay):** the factory's `onKeyboardInput` callback (typed
 *    chars + the emulator's generated escape sequences, posted to the main looper)
 *    is forwarded to [onInput] (mirrors iOS `send(source:data:)`).
 *  - **Size:** **termlib's `Terminal` composable owns sizing.** It measures its
 *    own pixel geometry against the monospace font and calls
 *    [TerminalEmulator.resize] itself, which then posts the factory's [onResize].
 *    The host bridges that single callback to
 *    [relay.terminal.RelayTerminalController.reportSize]. Therefore [resize] here
 *    is a **record-only no-op**: calling `emulator.resize()` from it would re-fire
 *    `onResize` and loop. This inverts the seam's original "engine drives sizing"
 *    expectation (written for a hypothetical Termux binding) — here the renderer is
 *    authoritative, and the engine merely records the last reported grid for
 *    [cols]/[rows].
 *
 * ## Sizing sentinel
 *
 * The emulator is created at a 1×1 sentinel grid (not 80×24). termlib only fires
 * `onResize` when the freshly-measured grid *differs* from the emulator's current
 * dimensions (`Terminal.kt`'s resize `LaunchedEffect`). Starting at 1×1 guarantees
 * the first real layout always differs, so `onResize` — and thus the one-shot
 * [relay.terminal.RelayTerminalController.reportSize] →
 * [relay.terminal.TerminalSessionVm.terminalReady] that flushes buffered
 * scrollback — always fires, even on a screen that happened to measure exactly
 * 80×24.
 *
 * ## Palette
 *
 * The canonical 16-color [TerminalPalette] + default fg/bg are installed once via
 * [TerminalEmulator.applyColorScheme], matching iOS's
 * `RelayTerminalView.nativeForegroundColor/​Background` + palette install.
 *
 * Not thread-safe: like the iOS `@MainActor` original, all calls are expected on
 * the single UI thread. (`onKeyboardInput`/`onResize` are already posted to the
 * main looper by termlib before they reach [onInput]/[reportSize].)
 *
 * @param onResize bridges termlib's measured grid to the controller. The host
 *   passes `controller::reportSize`; this engine wires it into the factory so the
 *   composable's own resize drives the relay PTY resize + the one-shot
 *   `terminalReady()`.
 */
class TermlibTerminalEngine(
    onResize: (cols: Int, rows: Int) -> Unit,
) : TerminalEngine {

    /**
     * The libvterm-backed emulator. Created at the 1×1 sentinel (see class doc).
     * The factory's `onKeyboardInput` forwards to [onInput]; `onResize` forwards
     * the measured grid (termlib reports `(rows, columns)`) to the host bridge as
     * `(cols, rows)` — the order [relay.terminal.RelayTerminalController.reportSize]
     * expects.
     */
    val emulator: TerminalEmulator = TerminalEmulatorFactory.create(
        initialRows = 1,
        initialCols = 1,
        defaultForeground = Color(TerminalPalette.foreground),
        defaultBackground = Color(TerminalPalette.background),
        onKeyboardInput = { bytes -> onInput?.invoke(bytes) },
        onResize = { dims: TerminalDimensions ->
            _cols = dims.columns
            _rows = dims.rows
            onResize(dims.columns, dims.rows)
        },
    ).apply {
        // Install the canonical 16-color ANSI palette + default fg/bg in one pass
        // (iOS sets these on the SwiftTerm view). Indices 0–15 in xterm order.
        applyColorScheme(
            ansiColors = TerminalPalette.colors,
            defaultForeground = TerminalPalette.foreground,
            defaultBackground = TerminalPalette.background,
        )
    }

    override fun feedOutput(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        emulator.writeInput(bytes)
    }

    /**
     * Record-only. termlib's `Terminal` composable is the sole resize driver (it
     * calls `emulator.resize()` from layout); invoking it here would re-fire the
     * factory `onResize` and loop. We only stash the dims so [cols]/[rows] reflect
     * the last grid the controller forwarded.
     */
    override fun resize(cols: Int, rows: Int) {
        _cols = cols
        _rows = rows
    }

    private var _cols: Int = 0
    private var _rows: Int = 0
    override val cols: Int get() = _cols
    override val rows: Int get() = _rows

    override var onInput: ((ByteArray) -> Unit)? = null
}
