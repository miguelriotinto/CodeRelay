package relay.terminal.linux

import relay.terminal.TerminalEngine

/**
 * Binds [LinuxTerminalEmulator] to the shared [TerminalEngine] seam, so the
 * pure-Kotlin `RelayTerminalController` and `TerminalSessionVm` drive the
 * desktop terminal with exactly the code that drives Android's and iOS's.
 *
 * This is the Linux analogue of Android's `TermlibTerminalEngine` and iOS's
 * `RelayTerminalView` + `IOSTerminalCoordinator` pair. The seam is five members
 * wide, which is the entire reason swapping emulators is an adapter rather than
 * a rewrite.
 *
 * ### Sizing direction
 *
 * Android inverted the seam's original assumption: termlib's `Terminal`
 * composable measures itself and calls `resize` on the emulator, so the Android
 * adapter's `resize` is a record-only no-op to avoid a feedback loop.
 *
 * **Here the host is authoritative.** Our Compose renderer measures the
 * viewport, converts pixels to a cell grid, and calls [resize] — which forwards
 * to the emulator. There is no loop because the emulator's own `resize`
 * callback only records dimensions; it never calls back into the renderer.
 * Keeping the host authoritative matches how the desktop actually works: the
 * window manager decides the size, and a tiling WM like Hyprland changes it
 * without asking.
 */
class LinuxTerminalEngine(
    private val emulator: LinuxTerminalEmulator,
) : TerminalEngine {

    @Volatile
    private var currentCols: Int = 0

    @Volatile
    private var currentRows: Int = 0

    override val cols: Int get() = currentCols
    override val rows: Int get() = currentRows

    /**
     * Engine → relay. Installed by `RelayTerminalController`; the host must not
     * also consume it, or keystrokes would be sent twice.
     */
    override var onInput: ((ByteArray) -> Unit)? = null

    init {
        // The emulator emits every byte libvterm generates from a key or mouse
        // dispatch — arrow-key sequences, bracketed-paste wrappers, SGR wheel
        // reports — and they all go upstream verbatim.
        emulator.setInputSink { bytes -> onInput?.invoke(bytes) }
    }

    /**
     * Relay → emulator, byte-faithful. No String round-trip anywhere on this
     * path: UTF-8 runes and escape sequences split across WebSocket frames must
     * survive untouched, which a decode/encode cycle would not guarantee.
     */
    override fun feedOutput(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        emulator.feedOutput(bytes)
    }

    /**
     * Note the argument order: the shared seam is (cols, rows) — matching the
     * relay's `resize` message and the iOS coordinator — while libvterm and the
     * emulator are (rows, cols). Getting this backwards produces a terminal that
     * looks plausible and wraps wrongly, so the swap happens here, once.
     */
    override fun resize(cols: Int, rows: Int) {
        if (cols <= 0 || rows <= 0) return
        currentCols = cols
        currentRows = rows
        emulator.resize(newRows = rows, newCols = cols)
    }
}
