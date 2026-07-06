package relay.feature.workspace.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
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
 * @param redrawToken bump this to force a full terminal repaint; the workspace
 *   increments it when the user taps the session-name badge to clear rare glyph
 *   overlap. A change drives [TermlibTerminalEngine.redraw] (a full-grid damage +
 *   snapshot re-emit) — NOT a view rebuild — so it repaints every cell without
 *   grabbing focus or raising the soft keyboard, and with no server round-trip.
 * @param modifier outer modifier
 */
@Composable
fun TerminalHost(
    vm: TerminalSessionVm,
    onInput: (ByteArray) -> Unit,
    onResize: (cols: Int, rows: Int) -> Unit,
    redrawToken: Int = 0,
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

    // Session-name tap → force a full-grid repaint to clear rare glyph overlap.
    // We drive it through the engine's damage-based redraw (which re-emits a fresh
    // snapshot the renderer repaints from) rather than re-keying the termlib view:
    // re-keying rebuilds termlib's ImeInputView, which grabs focus and raises the
    // soft keyboard — exactly the unwanted behaviour. skip == first composition
    // (LaunchedEffect always runs once) is harmless: a redundant redraw of the
    // just-built grid is a no-op to the eye and never touches focus/IME.
    LaunchedEffect(redrawToken) {
        engine.redraw()
    }

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
    //
    // CRITICAL — `key(vm)`: this forces Compose to DISPOSE the old termlib subtree and
    // BUILD a fresh one on every session change, instead of reusing this call site's
    // node with a new `terminalEmulator` argument. It is load-bearing for the soft
    // keyboard, NOT a micro-optimization:
    //
    //   termlib hosts its soft-keyboard `InputConnection` inside an `ImeInputView`
    //   that it creates in an `AndroidView` *factory* lambda. Compose runs an
    //   AndroidView factory EXACTLY ONCE per node — never on recomposition. termlib's
    //   `ImeInputView` holds its `KeyboardHandler` (and the handler its
    //   `TerminalEmulator`) as `final` fields, bound at construction. So when a session
    //   switch feeds this stable node a NEW `engine.emulator`, termlib rebuilds its
    //   `KeyboardHandler` (that part IS keyed on the emulator) but the
    //   AndroidView-hosted `ImeInputView` is NOT recreated — it stays welded to the
    //   PREVIOUS session's handler/emulator. Android's `InputMethodManager` serves a
    //   single view process-wide, so it keeps serving that stale view: every
    //   soft-keyboard commit routes to a detached `InputConnection` and silently
    //   vanishes — for this session AND every session opened afterwards. (The
    //   KeyboardAccessory special-key bar feeds `onInput` directly, bypassing the IME,
    //   so it keeps working — which is exactly the observed "special keys type, soft
    //   keyboard doesn't" symptom.)
    //
    //   Re-keying on `vm` makes a session switch tear the old `ImeInputView` out of the
    //   window (its `onDetachedFromWindow` releases the IMM) and construct a brand-new
    //   one bound to the new session's emulator, so the keyboard works on every session.
    //   The per-session `TerminalSessionVm` lives in the coordinator's terminalCache
    //   (outside composition), so keying here costs only a termlib view rebuild — the
    //   same rebuild that already happens for `engine`/`controller` (both `remember(vm)`).
    //
    //   NOTE: keyed on `vm` ONLY — deliberately NOT on `redrawToken`. Re-keying grabs
    //   focus and raises the soft keyboard (termlib requests focus on a fresh
    //   composition), so the tap-to-redraw path goes through `engine.redraw()` above
    //   instead, which repaints without rebuilding this subtree.
    key(vm) {
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
}
