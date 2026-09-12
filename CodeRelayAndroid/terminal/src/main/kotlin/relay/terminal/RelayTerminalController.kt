package relay.terminal

/**
 * Wires a [TerminalEngine] to a [TerminalSessionVm] and the relay I/O callbacks.
 * Pure Kotlin so the full integration logic is unit-testable without a real VT
 * engine or a device.
 *
 * This is the Kotlin counterpart of the iOS `IOSTerminalCoordinator` +
 * `TerminalHostView` wiring (`RelayTerminalView.swift`). It owns three edges:
 *
 *  - **Relay → engine (output):** installs [TerminalSessionVm.onTerminalOutput]
 *    to feed bytes verbatim into [TerminalEngine.feedOutput] (byte fidelity, no
 *    `String` decoding).
 *  - **Engine → relay (input):** installs [TerminalEngine.onInput] to forward
 *    keystrokes out through [onInput].
 *  - **Size:** the engine reports its laid-out geometry via [reportSize], which
 *    resizes the engine, sends the size upstream via [onResize], and — on the
 *    FIRST report — calls [TerminalSessionVm.terminalReady] exactly once so
 *    buffered scrollback drains. Mirrors iOS `sizeChanged(...)`.
 *
 * Not thread-safe: like the iOS `@MainActor` originals, all calls are expected
 * on the single UI/coordinator thread.
 *
 * @param engine the VT engine to drive (Termux adapter in production, a fake in tests)
 * @param vm the buffering view-model for this session
 * @param onInput engine → relay keystroke sink (the WebSocket input path)
 * @param onResize relay resize sink, invoked `(cols, rows)` (the PTY window-size path)
 */
class RelayTerminalController(
    private val engine: TerminalEngine,
    private val vm: TerminalSessionVm,
    private val onInput: (ByteArray) -> Unit,
    private val onResize: (cols: Int, rows: Int) -> Unit
) {
    /**
     * Tracks whether the first size report has been seen. `terminalReady()` is
     * itself idempotent, but this avoids re-dispatching it (and the guard +
     * flush cost) on every subsequent resize — parity with iOS's
     * `readiedSessionId` short-circuit.
     */
    private var didReportSize = false

    /**
     * This controller's claim on [vm] (see [TerminalSessionVm.claimOwnership]).
     * Taken at construction, surrendered in [detach] — and only honoured there
     * if a newer controller hasn't already claimed the vm.
     */
    private val ownerToken: Any = vm.claimOwnership()

    init {
        // Relay → engine: feed output bytes verbatim.
        vm.onTerminalOutput = { bytes -> engine.feedOutput(bytes) }
        // Engine → relay: forward keystrokes upstream.
        engine.onInput = { bytes -> onInput(bytes) }
    }

    /**
     * Called by the engine when its visible grid is laid out or changes size.
     * Forwards the new geometry to the engine and to the relay, and turns the
     * FIRST report into a single [TerminalSessionVm.terminalReady] call so
     * buffered scrollback is flushed. Subsequent reports resize only.
     *
     * Non-positive dimensions are ignored (parity with iOS's
     * `guard newCols > 0, newRows > 0`).
     */
    fun reportSize(cols: Int, rows: Int) {
        if (cols <= 0 || rows <= 0) return
        engine.resize(cols, rows)
        onResize(cols, rows)
        if (!didReportSize) {
            didReportSize = true
            vm.terminalReady()
        }
    }

    /**
     * Detaches this controller from its [TerminalSessionVm] and engine when the
     * session is switched away or this view is disposed.
     *
     * The engine sink is ALWAYS cleared: this controller's engine is going away
     * with its composition either way, and leaving the sink live would let a
     * stale termlib emulator keep typing into the connection.
     *
     * The vm wiring is only cleared if this controller is still the vm's owner
     * (see [TerminalSessionVm.releaseOwnership]). The vm is cached by the
     * coordinator and outlives composition, so on an Android Activity recreation
     * — a fold/unfold — the replacement controller binds BEFORE this dispose
     * runs. Unconditionally clearing here would null the new controller's wiring
     * and leave the terminal permanently black and unable to accept input.
     */
    fun detach() {
        vm.releaseOwnership(ownerToken)
        engine.onInput = null
    }
}
