package relay.terminal

/**
 * The minimal surface [RelayTerminalController] needs from any VT100/xterm
 * terminal engine (Termux's `TerminalEmulator`/`TerminalView`, or a fake in
 * tests). Defining this as a pure-Kotlin contract lets the wiring logic that
 * connects an engine to a [TerminalSessionVm] be implemented and unit-tested
 * here, while the concrete engine binding (Termux) is an isolated adapter that
 * needs a device for manual verification.
 *
 * Behaviour mirrors the iOS `RelayTerminalView` / `IOSTerminalCoordinator` pair
 * (`ClaudeRelayApp/Views/Components/RelayTerminalView.swift`):
 *
 *  - **Byte fidelity.** Output bytes flow from the relay through
 *    [TerminalSessionVm.onTerminalOutput] into [feedOutput] verbatim — NO
 *    `String` decoding anywhere on the path. The iOS side calls
 *    `view.feed(byteArray:)` with the raw `[UInt8]`; UTF-8 multi-byte runes and
 *    partial escape sequences split across frames must survive untouched.
 *  - **Ready-on-size.** The engine reports its laid-out size once it knows its
 *    geometry; the controller turns the first such report into a single
 *    `TerminalSessionVm.terminalReady()` (which drains buffered scrollback).
 *    iOS does this in `sizeChanged(...)`.
 *  - **Resize.** Size changes are forwarded to [resize] (so the engine
 *    re-wraps) and out to the relay so the server PTY's window size matches.
 *  - **Input.** Keystrokes the engine produces (typed characters, the keyboard
 *    accessory's special-key bytes that the host feeds into the engine, paste,
 *    etc.) are delivered through [onInput] for the relay to send upstream. This
 *    is the engine's `send(source:data:)` on iOS.
 */
interface TerminalEngine {

    /**
     * Feeds raw terminal output bytes into the engine for parsing/rendering.
     * Must be byte-faithful: the bytes are passed through with no `String`
     * round-trip. Empty arrays are permitted and are no-ops.
     */
    fun feedOutput(bytes: ByteArray)

    /**
     * Tells the engine its visible grid is now [cols] x [rows] cells. Called
     * when the view is (re)laid out. The engine re-wraps its buffer to match.
     */
    fun resize(cols: Int, rows: Int)

    /** Current visible column count, or 0 before the engine has been sized. */
    val cols: Int

    /** Current visible row count, or 0 before the engine has been sized. */
    val rows: Int

    /**
     * Engine → relay keystroke sink. The engine invokes this with the raw bytes
     * a user produces (typing, paste, accessory keys routed through the engine).
     * The controller installs this; the host must not also consume it.
     */
    var onInput: ((ByteArray) -> Unit)?
}
