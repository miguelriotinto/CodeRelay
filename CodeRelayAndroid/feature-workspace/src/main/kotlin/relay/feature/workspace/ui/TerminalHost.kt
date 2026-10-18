package relay.feature.workspace.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.splineBasedDecay
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.util.addPointerInputChange
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.ViewCompat
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import org.connectbot.terminal.Terminal
import relay.terminal.RelayTerminalController
import relay.terminal.TerminalPalette
import relay.terminal.TerminalSessionVm
import relay.terminal.WheelTravelBank
import kotlin.math.abs

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

    DisposableEffect(vm, engine) {
        // Held in a val so the dispose below can compare by IDENTITY. A fresh
        // lambda literal in `onDispose` would be a different object and the
        // check would never match.
        val replayRedraw: () -> Unit = { engine.redraw() }
        vm.onReplayFlushed = replayRedraw
        onDispose {
            // Same superseded-teardown hazard as `controller.detach()` below: on
            // an Activity recreation (fold/unfold) the NEW composition installs
            // its own `onReplayFlushed` before this dispose runs, so nulling
            // unconditionally would leave the new engine without a post-replay
            // repaint. Only clear the slot if it is still OURS.
            if (vm.onReplayFlushed === replayRedraw) vm.onReplayFlushed = null
        }
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
    val showKeyboard: () -> Unit = {
        ViewCompat.getWindowInsetsController(view)?.show(WindowInsetsCompat.Type.ime())
    }

    // Our handle on termlib's IME input focus. termlib's own tap does
    // `focusRequester.requestFocus()` then `onTerminalTap()`; while the wheel
    // overlay below owns touch, its tap has to do the same two things, so the
    // requester is ours to share rather than termlib's private default.
    val terminalFocus = remember(vm) { FocusRequester() }

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
    Box(modifier = modifier.fillMaxSize()) {
        key(vm) {
            Terminal(
                terminalEmulator = engine.emulator,
                keyboardEnabled = true,
                focusRequester = terminalFocus,
                // termlib focuses its ImeInputView on tap; we then force the platform IME
                // up (it stays down on tap after a manual swipe-down otherwise — see above).
                onTerminalTap = showKeyboard,
                backgroundColor = TerminalPalette.background.toComposeColor(),
                foregroundColor = TerminalPalette.foreground.toComposeColor(),
                modifier = Modifier
                    .fillMaxSize()
                    .background(TerminalPalette.background.toComposeColor()),
            )
        }

        // A one-finger swipe is a wheel report while a program tracks the mouse,
        // and termlib's own gesture otherwise — the iOS rule
        // (`RelayTerminalView.mouseModeChanged`), by a different mechanism. See
        // [WheelSwipeOverlay] for why it must be a SIBLING that exists only while
        // tracking is on, rather than a modifier on the terminal.
        if (engine.mouseTracking.value) {
            WheelSwipeOverlay(
                engine = engine,
                onTap = {
                    runCatching { terminalFocus.requestFocus() }
                    showKeyboard()
                },
                modifier = Modifier.matchParentSize(),
            )
        }
    }
}

/**
 * Owns all touch on the terminal while the program is tracking the mouse,
 * turning vertical finger travel into wheel reports via
 * [TermlibTerminalEngine.sendWheel], with a fling, and a plain tap into
 * focus + keyboard exactly as termlib's own tap does.
 *
 * ## Why a sibling overlay and not a modifier
 *
 * Three facts about termlib 0.1.0 force this shape:
 *
 * 1. Claude Code runs in the **alternate screen** (`CSI ?1049h`), which has no
 *    scrollback by definition. termlib's swipe scrolls its *local* scrollback —
 *    the primary screen's history from before the program launched — so in an
 *    agent session a swipe either does nothing or drags stale shell lines over
 *    the agent's UI, and the transcript never moves. What the agent listens for
 *    is a **wheel report** (buttons 4/5, SGR-encoded under `CSI ?1006h`), which
 *    termlib never sends: it has no mouse path at all (libvterm's
 *    `vterm_mouse_button` is not even linked into its `.so`).
 * 2. termlib's gesture starts with `awaitFirstDown(requireUnconsumed = false)`,
 *    so a `pointerInput` modifier layered on the terminal cannot take the
 *    gesture away by consuming it. If termlib sees the moves it scrolls the
 *    local scrollback; if it sees them consumed it stays "undetermined", and
 *    then its 400 ms long-press starts a text selection and its release fires
 *    the tap, which raises the keyboard on every swipe.
 * 3. Compose dispatches a pointer only to the **topmost sibling** that hits.
 *    A sibling drawn above the terminal with its own `pointerInput` therefore
 *    receives the whole gesture and termlib receives nothing — no selection,
 *    no tap, no local scroll. Composed only while `mouseTracking` is true, it
 *    costs a plain shell (where the scrollback really is local) exactly nothing:
 *    termlib keeps every gesture it has today, including local scrolling,
 *    pinch zoom and long-press selection.
 *
 * The trade-off this accepts: while a program tracks the mouse, long-press
 * selection and pinch zoom are not available on the terminal, because the
 * gesture cannot be handed back to termlib mid-flight. Upstream termlib has an
 * open PR (connectbot/termlib#259) that forks the gesture *inside* termlib on
 * `mouseTracking` and keeps long-press local; when that ships, this overlay and
 * the client-side mode tracker should be deleted in favour of it.
 *
 * Reports go to the cell under the **initial** touch, as upstream chose: a
 * program tracking motion (`?1003h`, which Claude Code enables) would otherwise
 * see a motion report for every row the finger crossed. Direction follows iOS
 * and macOS: dragging down pulls earlier lines into view, i.e. wheel UP.
 */
@Composable
private fun WheelSwipeOverlay(
    engine: TermlibTerminalEngine,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val currentOnTap by rememberUpdatedState(onTap)
    Box(
        modifier = modifier.pointerInput(engine) {
            val touchSlop = viewConfiguration.touchSlop
            val longPressTimeoutMillis = viewConfiguration.longPressTimeoutMillis
            // Android's ViewConfiguration minimum fling velocity (50 dp/s);
            // Compose's ViewConfiguration does not expose it.
            val minFlingVelocity = 50.dp.toPx()
            val fallbackRowHeight = 16.dp.toPx()
            val decay = splineBasedDecay<Float>(this)
            var flingJob: Job? = null

            coroutineScope {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    // The next touch cancels an in-flight fling, as a scroll view does.
                    flingJob?.cancel()
                    flingJob = null

                    val grid = engine.gridMetrics(size, fallbackRowHeight)
                    val anchorCol = grid.col(down.position.x)
                    val anchorRow = grid.row(down.position.y)
                    val bank = WheelTravelBank()
                    val velocity = VelocityTracker()
                    velocity.addPosition(down.uptimeMillis, down.position)

                    var dragging = false
                    var pending = Offset.Zero
                    var upTime = down.uptimeMillis

                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) {
                            upTime = change.uptimeMillis
                            change.consume()
                            break
                        }
                        velocity.addPointerInputChange(change)
                        val delta = change.positionChange()
                        if (!dragging) {
                            pending += delta
                            if (pending.getDistance() > touchSlop) {
                                dragging = true
                                // Bank the whole pre-slop travel so the first
                                // notch arrives as soon as the drag is recognised.
                                engine.sendWheel(
                                    bank.take(pending.y, grid.rowHeight, MAX_NOTCHES_PER_SAMPLE, carryExcess = false),
                                    anchorCol,
                                    anchorRow,
                                )
                            }
                        } else {
                            engine.sendWheel(
                                bank.take(delta.y, grid.rowHeight, MAX_NOTCHES_PER_SAMPLE, carryExcess = false),
                                anchorCol,
                                anchorRow,
                            )
                        }
                        change.consume()
                    }

                    if (!dragging) {
                        // A tap. A press held past the long-press timeout is not
                        // one — termlib would have started a selection — so it
                        // does nothing rather than raise the keyboard.
                        if (upTime - down.uptimeMillis < longPressTimeoutMillis) currentOnTap()
                        return@awaitEachGesture
                    }

                    val verticalVelocity = velocity.calculateVelocity().y
                    if (abs(verticalVelocity) < minFlingVelocity) return@awaitEachGesture
                    flingJob = launch {
                        var last = 0f
                        Animatable(0f).animateDecay(verticalVelocity, decay) {
                            val step = value - last
                            last = value
                            engine.sendWheel(
                                bank.take(step, grid.rowHeight, MAX_NOTCHES_PER_SAMPLE, carryExcess = true),
                                anchorCol,
                                anchorRow,
                            )
                        }
                        // Drain notches the per-frame cap carried past the end
                        // of the decay, one capped burst per frame.
                        while (bank.hasWholeNotch(grid.rowHeight)) {
                            engine.sendWheel(
                                bank.take(0f, grid.rowHeight, MAX_NOTCHES_PER_SAMPLE, carryExcess = true),
                                anchorCol,
                                anchorRow,
                            )
                            withFrameNanos { }
                        }
                    }
                }
            }
        },
    )
}

/**
 * Most wheel notches sent per pointer sample or animation frame. Programs
 * commonly throttle a flood of wheel reports, so a fast fling that sends every
 * notch can scroll *less* far than one that sends a few; this is the value
 * upstream termlib settled on against Claude Code (connectbot/termlib#259).
 */
private const val MAX_NOTCHES_PER_SAMPLE = 8

/**
 * Pixel geometry of the terminal grid, derived from the overlay's size and the
 * grid termlib reported — the same self-correcting derivation iOS uses for
 * `wheelRowHeight`, so font-size changes and rotation need no extra plumbing.
 * [fallbackRowHeight] only matters before the first resize report.
 */
private class GridMetrics(val cellWidth: Float, val rowHeight: Float, val cols: Int, val rows: Int) {
    fun col(x: Float): Int = if (cellWidth > 0f) (x / cellWidth).toInt().coerceIn(0, maxOf(0, cols - 1)) else 0
    fun row(y: Float): Int = if (rowHeight > 0f) (y / rowHeight).toInt().coerceIn(0, maxOf(0, rows - 1)) else 0
}

private fun TermlibTerminalEngine.gridMetrics(size: IntSize, fallbackRowHeight: Float): GridMetrics {
    val cols = cols
    val rows = rows
    val rowHeight = if (rows > 0 && size.height > 0) size.height.toFloat() / rows else fallbackRowHeight
    val cellWidth = if (cols > 0 && size.width > 0) size.width.toFloat() / cols else 0f
    return GridMetrics(cellWidth, if (rowHeight >= 1f) rowHeight else fallbackRowHeight, cols, rows)
}
