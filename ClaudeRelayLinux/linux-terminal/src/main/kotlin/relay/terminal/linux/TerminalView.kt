package relay.terminal.linux

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.PointerButton
import androidx.compose.ui.input.pointer.PointerEvent
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.isAltPressed as pointerAltPressed
import androidx.compose.ui.input.pointer.isCtrlPressed as pointerCtrlPressed
import androidx.compose.ui.input.pointer.isPrimaryPressed
import androidx.compose.ui.input.pointer.isSecondaryPressed
import androidx.compose.ui.input.pointer.isShiftPressed as pointerShiftPressed
import androidx.compose.ui.input.pointer.isTertiaryPressed
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max

/**
 * The Compose Desktop terminal renderer.
 *
 * Replaces termlib's `Terminal.kt` (2,506 lines), which is unusable here: it
 * carries Android IME, accessibility, and Android key/pointer handling. What it
 * does NOT replace is the render data model beneath it — `CellRun`,
 * `ColorCache`, and the run-batched `nativeGetCellRun` fetch are reused as-is,
 * because those are the parts that make rendering fast and they are already
 * platform-free.
 *
 * ### The host measures, the emulator follows
 *
 * Android inverted this: termlib's composable measures itself and resizes the
 * emulator, so the Android adapter's `resize` had to be a no-op to avoid a
 * feedback loop. Here the host is authoritative — we measure the viewport,
 * divide by the cell size, and drive [LinuxTerminalEngine.resize]. That matches
 * how a tiling WM actually behaves: Hyprland resizes the window without asking,
 * and the terminal must follow.
 *
 * ### Mouse: the program's or ours
 *
 * Every pointer event is either a report to the running program or a local
 * gesture, decided by one rule from xterm: **the program gets the mouse while
 * it has asked for it (`mouseMode != 0`), unless Shift is held.** So a click in
 * vim moves vim's cursor, a drag in tmux resizes a pane, the wheel in Claude
 * Code scrolls its transcript — and Shift+drag still selects text locally in
 * all three. In a plain shell, where nothing asked, the same events select,
 * paste (middle click) and scroll the local scrollback.
 *
 * ### Font metrics
 *
 * Cell size is measured from a single glyph in the chosen monospace face. This
 * is the detail most likely to look subtly wrong: a face that is not truly
 * monospace, or fractional advance widths under DPI scaling, produce a grid that
 * drifts across a line. We therefore measure once, round the *cell* to whole
 * pixels, and position every span at `col * cellWidth` rather than letting the
 * text layout advance naturally.
 */
@OptIn(ExperimentalTextApi::class, ExperimentalComposeUiApi::class)
@Composable
fun TerminalView(
    emulator: LinuxTerminalEmulator,
    engine: LinuxTerminalEngine,
    modifier: Modifier = Modifier,
    fontSize: TextUnit = 13.sp,
    fontFamily: FontFamily = FontFamily.Monospace,
    background: Color = Color.Black,
    foreground: Color = Color.White,
    /** Selection highlight; drawn translucent over the cells. */
    selectionColor: Color = foreground.copy(alpha = 0.3f),
    /**
     * Inset between the window frame and the first cell, matching the `pad` the
     * desktop's own terminals leave. Applied INSIDE the background so the fill
     * still reaches the frame — the gap has to be terminal-coloured, not a strip
     * of whatever is behind the window.
     */
    padding: Dp = 0.dp,
    onShortcut: (androidx.compose.ui.input.key.KeyEvent) -> Boolean = { false },
    /** Bumped by the app's copy accelerator; the current selection is handed to [onCopy]. */
    copyRequest: Int = 0,
    onCopy: (String) -> Unit = {},
    /** Fired when a selection completes, with its text — the PRIMARY selection. */
    onPrimarySelection: (String) -> Unit = {},
    /** Middle click in a plain shell. */
    onPastePrimary: () -> Unit = {},
    /**
     * Fired when the measured grid changes. The host forwards this to the relay
     * so the server's PTY window size follows the window — under a tiling WM
     * like Hyprland the compositor resizes without asking, so this is the normal
     * path, not an edge case.
     */
    onSizeChanged: (cols: Int, rows: Int) -> Unit = { _, _ -> },
) {
    val measurer = rememberTextMeasurer()
    val focusRequester = remember { FocusRequester() }

    val rawStyle = remember(fontSize, fontFamily) {
        TextStyle(fontFamily = fontFamily, fontSize = fontSize)
    }

    // One measurement of a representative glyph gives the cell box. Measuring a
    // wide-ish character rather than a space avoids a zero-advance surprise in
    // faces that collapse whitespace.
    val cell = rememberCellMetrics(measurer, rawStyle)

    // Snap the run's own advance to the integer cell. Spans are drawn as whole
    // strings at `col * cell.width`, so any difference between the font's
    // advance and the cell width accumulates INSIDE a span: JetBrainsMono at
    // 24 px advances 14.4 px, so against a 15 px cell a 30-character run ended
    // 18 px — more than a full column — out of step with the background rects
    // and the cursor, which are drawn on the grid. Letter spacing of
    // `cell.width - advance` makes the drawn advance exactly one cell, which is
    // the same integer-cell grid Foot and Alacritty rasterise onto.
    val baseStyle = remember(rawStyle, cell) {
        rawStyle.copy(letterSpacing = cell.letterSpacing)
    }

    val grid by emulator.grid.collectAsState()
    val mouseMode by emulator.mouseMode.collectAsState()
    val windowFocused = LocalWindowInfo.current.isWindowFocused

    // Selection, in VIEW coordinates (rows of what is drawn). Anchored to the
    // screen rather than the content: scrolling or new output under a
    // selection leaves the highlight where it is, which is what foot does.
    val selection = remember(emulator) { SelectionState() }
    var selectionVersion by remember { mutableStateOf(0) }
    val keys = remember(emulator) { KeyState() }
    val currentOnCopy by rememberUpdatedState(onCopy)
    val currentOnPrimary by rememberUpdatedState(onPrimarySelection)
    val currentOnPastePrimary by rememberUpdatedState(onPastePrimary)

    // Cursor blink phase, only ticking while the program asked for a blink.
    var blinkOn by remember { mutableStateOf(true) }
    LaunchedEffect(grid.cursor.blink) {
        blinkOn = true
        if (!grid.cursor.blink) return@LaunchedEffect
        while (true) {
            kotlinx.coroutines.delay(BLINK_MS)
            blinkOn = !blinkOn
        }
    }

    // Copy accelerator: hand the selection over, if there is one.
    LaunchedEffect(copyRequest) {
        if (copyRequest == 0) return@LaunchedEffect
        selection.text(emulator)?.let { currentOnCopy(it) }
    }

    BoxWithConstraints(
        modifier = modifier
            .background(background)
            .padding(padding)
            .focusRequester(focusRequester)
            .focusable()
            .onKeyEvent { event ->
                // A typed character (dead key / Compose sequence) arrives as an
                // Unknown-type event after a KeyDown that mapped to nothing.
                if (event.type == KeyEventType.Unknown) {
                    val typed = KeyMapping.typed(event, keys.lastKeyDownHandled)
                    if (typed is KeyMapping.Action.Character) {
                        if (selection.clear()) selectionVersion++
                        emulator.dispatchCharacter(typed.codepoint, typed.modifiers)
                        return@onKeyEvent true
                    }
                    return@onKeyEvent false
                }
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                // Application accelerators are all Ctrl+Shift / Ctrl+Alt, so a
                // bare Ctrl+C still reaches the agent.
                if (KeyMapping.isApplicationShortcut(event) && onShortcut(event)) {
                    keys.lastKeyDownHandled = true
                    return@onKeyEvent true
                }
                // Shift+PageUp/PageDown page the local scrollback, as every
                // terminal does; the program never sees them.
                if (event.isShiftPressed && (event.key == Key.PageUp || event.key == Key.PageDown)) {
                    val page = max(1, grid.rows - 1)
                    emulator.scrollViewport(if (event.key == Key.PageUp) page else -page)
                    keys.lastKeyDownHandled = true
                    return@onKeyEvent true
                }
                val handled = when (val action = KeyMapping.map(event)) {
                    is KeyMapping.Action.SpecialKey -> {
                        if (selection.clear()) selectionVersion++
                        emulator.dispatchKey(action.key, action.modifiers); true
                    }
                    is KeyMapping.Action.Character -> {
                        if (selection.clear()) selectionVersion++
                        emulator.dispatchCharacter(action.codepoint, action.modifiers); true
                    }
                    KeyMapping.Action.Unhandled -> false
                }
                keys.lastKeyDownHandled = handled
                handled
            },
    ) {
        val density = LocalDensityValue()
        val widthPx = with(density) { maxWidth.toPx() }
        val heightPx = with(density) { maxHeight.toPx() }

        val cols = max(1, floor(widthPx / cell.width).toInt())
        val rows = max(1, floor(heightPx / cell.height).toInt())

        // Drive the emulator (and, through the shared controller, the server's
        // PTY window size) from the measured viewport.
        //
        // **Keyed on the engine, not just the size.** Switching to another
        // session swaps in a new engine, view model and controller while the
        // window — and therefore `cols`/`rows` — stays exactly the same. Keyed on
        // the size alone this effect would not re-run, so the new controller
        // never got its first `reportSize`, and it is that first report which
        // calls `TerminalSessionVm.terminalReady()` to drain the output buffered
        // while the view was laying out. The freshly created session's login
        // banner and prompt sat in `pendingOutput` and the pane showed nothing
        // but a cursor — until a reattach replayed the ring buffer and made it
        // appear. The FIRST session after connecting always worked, because that
        // composition was new and the effect ran anyway.
        LaunchedEffect(engine, cols, rows) {
            engine.resize(cols, rows)
            onSizeChanged(cols, rows)
        }

        // Pull a fresh grid whenever the emulator marked itself dirty. Tied to
        // Compose's frame clock rather than a Choreographer, which is what
        // Android needed and desktop does not have.
        LaunchedEffect(emulator) {
            while (true) {
                androidx.compose.runtime.withFrameNanos { }
                emulator.refreshIfDirty()
            }
        }

        // Wheel travel banked into whole notches: a high-resolution trackpad
        // sends many fractional deltas per finger movement, and forwarding each
        // as a notch over-scrolled by an order of magnitude.
        val wheel = remember(emulator) { WheelBank() }
        // The pointer gesture in progress: a local selection drag, or a button
        // the program is tracking.
        val pointer = remember(emulator) { PointerState() }

        fun cellAt(position: Offset): Pair<Int, Int> {
            val col = (position.x / cell.width).toInt().coerceIn(0, cols - 1)
            val row = (position.y / cell.height).toInt().coerceIn(0, rows - 1)
            return row to col
        }

        Canvas(
            Modifier
                .fillMaxSize()
                // Wheel → the running program while it has asked for mouse
                // reporting (and Shift is up); otherwise the local scrollback.
                // libvterm emits nothing for a program that has not enabled
                // reporting, so a plain shell prompt cannot be corrupted.
                .onPointerEvent(PointerEventType.Scroll) { event ->
                    val change = event.changes.firstOrNull() ?: return@onPointerEvent
                    val notches = wheel.bank(change.scrollDelta.y)
                    if (notches == 0) return@onPointerEvent
                    val (row, col) = cellAt(change.position)
                    val toProgram = mouseMode != 0 && !event.keyboardModifiers.pointerShiftPressed
                    if (toProgram) {
                        repeat(abs(notches)) {
                            // libvterm takes 1-based cells.
                            emulator.dispatchWheel(down = notches > 0, row = row + 1, col = col + 1)
                        }
                    } else {
                        emulator.scrollViewport(-notches * WHEEL_LINES_PER_NOTCH)
                    }
                }
                .onPointerEvent(PointerEventType.Press) { event ->
                    focusRequester.requestFocus()
                    val change = event.changes.firstOrNull() ?: return@onPointerEvent
                    val (row, col) = cellAt(change.position)
                    val shift = event.keyboardModifiers.pointerShiftPressed
                    val button = buttonOf(event)
                    if (mouseMode != 0 && !shift) {
                        pointer.reportedButton = button
                        emulator.dispatchMouseMove(row + 1, col + 1, modifiersOf(event))
                        emulator.dispatchMouseButton(button, true, modifiersOf(event))
                        return@onPointerEvent
                    }
                    when (button) {
                        BUTTON_MIDDLE -> currentOnPastePrimary()
                        BUTTON_LEFT -> {
                            val clicks = pointer.registerClick(change.uptimeMillis, row, col)
                            when (clicks) {
                                1 -> selection.begin(row, col)
                                2 -> selection.selectWord(emulator, row, col)
                                else -> selection.selectLine(row, cols)
                            }
                            pointer.selecting = clicks == 1
                            selectionVersion++
                        }
                    }
                }
                .onPointerEvent(PointerEventType.Move) { event ->
                    val change = event.changes.firstOrNull() ?: return@onPointerEvent
                    val (row, col) = cellAt(change.position)
                    val reported = pointer.reportedButton
                    if (reported != null) {
                        // Drag reports (button-event tracking, mode 1002) —
                        // libvterm only emits them when the program asked.
                        emulator.dispatchMouseMove(row + 1, col + 1, modifiersOf(event))
                        return@onPointerEvent
                    }
                    if (pointer.selecting && event.buttons.isPrimaryPressed) {
                        if (selection.extend(row, col)) selectionVersion++
                    }
                }
                .onPointerEvent(PointerEventType.Release) { event ->
                    val change = event.changes.firstOrNull() ?: return@onPointerEvent
                    val (row, col) = cellAt(change.position)
                    pointer.reportedButton?.let { button ->
                        pointer.reportedButton = null
                        emulator.dispatchMouseMove(row + 1, col + 1, modifiersOf(event))
                        emulator.dispatchMouseButton(button, false, modifiersOf(event))
                        return@onPointerEvent
                    }
                    if (pointer.selecting) {
                        pointer.selecting = false
                        if (selection.extend(row, col)) selectionVersion++
                        if (selection.isPoint()) {
                            selection.clear()
                            selectionVersion++
                        }
                    }
                    selection.text(emulator)?.let { currentOnPrimary(it) }
                },
        ) {
            // Read so the canvas redraws when the selection changes.
            @Suppress("UNUSED_VARIABLE") val version = selectionVersion
            drawGrid(
                grid = grid,
                cell = cell,
                measurer = measurer,
                baseStyle = baseStyle,
                defaultBackground = background,
                defaultForeground = foreground,
                selection = selection.normalized(),
                selectionColor = selectionColor,
                cursorFocused = windowFocused,
                blinkOn = blinkOn,
            )
        }
    }

    LaunchedEffect(Unit) { focusRequester.requestFocus() }
}

/** Milliseconds per blink phase. */
private const val BLINK_MS = 530L

/** Lines the local viewport moves per wheel notch, matching foot's default. */
private const val WHEEL_LINES_PER_NOTCH = 3

/** X11 button numbers libvterm expects. */
internal const val BUTTON_LEFT = 1
internal const val BUTTON_MIDDLE = 2
internal const val BUTTON_RIGHT = 3

@OptIn(ExperimentalComposeUiApi::class)
private fun buttonOf(event: PointerEvent): Int = when (event.button) {
    PointerButton.Secondary -> BUTTON_RIGHT
    PointerButton.Tertiary -> BUTTON_MIDDLE
    else -> when {
        event.buttons.isSecondaryPressed -> BUTTON_RIGHT
        event.buttons.isTertiaryPressed -> BUTTON_MIDDLE
        else -> BUTTON_LEFT
    }
}

private fun modifiersOf(event: PointerEvent): Int {
    var mods = VTermMod.NONE
    val k = event.keyboardModifiers
    if (k.pointerShiftPressed) mods = mods or VTermMod.SHIFT
    if (k.pointerAltPressed) mods = mods or VTermMod.ALT
    if (k.pointerCtrlPressed) mods = mods or VTermMod.CTRL
    return mods
}

/**
 * Accumulates fractional wheel travel and releases whole notches.
 *
 * Compose Desktop reports a classic wheel click as ±1.0 and a trackpad as a
 * stream of small fractions; both end up as an integer notch count here. The
 * remainder is carried, and reset when the direction reverses so a change of
 * mind does not have to pay off the old bank first.
 */
internal class WheelBank {
    private var travel = 0f

    fun bank(delta: Float): Int {
        if (delta == 0f) return 0
        if ((delta > 0) != (travel > 0)) travel = 0f
        travel += delta
        val notches = travel.toInt()
        travel -= notches
        return notches
    }
}

/**
 * Whether the most recent KeyDown produced input. A following typed-character
 * event is dispatched only when it did not — see [KeyMapping.typed].
 */
internal class KeyState {
    var lastKeyDownHandled = false
}

/** Click counting and the drag in progress. */
internal class PointerState {
    var selecting = false
    /** The X11 button being reported to the program, while held. */
    var reportedButton: Int? = null

    private var lastClickAt = 0L
    private var lastRow = -1
    private var lastCol = -1
    private var clicks = 0

    /** Returns 1, 2 or 3 for single, double, triple click at the same cell. */
    fun registerClick(atMillis: Long, row: Int, col: Int): Int {
        clicks = if (atMillis - lastClickAt <= MULTI_CLICK_MS && row == lastRow && col == lastCol) {
            (clicks % 3) + 1
        } else {
            1
        }
        lastClickAt = atMillis
        lastRow = row
        lastCol = col
        return clicks
    }

    companion object {
        const val MULTI_CLICK_MS = 400L
    }
}

/**
 * A stream selection between two cells of the view.
 *
 * Stored as anchor + head so a drag past the anchor flips naturally;
 * [normalized] gives the ordered range the renderer and [text] use.
 */
internal class SelectionState {
    private var anchor: Pair<Int, Int>? = null
    private var head: Pair<Int, Int>? = null

    fun begin(row: Int, col: Int) {
        anchor = row to col
        head = row to col
    }

    /** Moves the head; true if it changed. */
    fun extend(row: Int, col: Int): Boolean {
        if (anchor == null) return false
        val next = row to col
        if (next == head) return false
        head = next
        return true
    }

    fun clear(): Boolean {
        val had = anchor != null
        anchor = null
        head = null
        return had
    }

    fun isPoint(): Boolean = anchor != null && anchor == head

    fun selectLine(row: Int, cols: Int) {
        anchor = row to 0
        head = row to cols
    }

    /** Word = a run of non-separator characters around the cell. */
    fun selectWord(emulator: LinuxTerminalEmulator, row: Int, col: Int) {
        val grid = emulator.grid.value
        val line = grid.lines.getOrNull(row) ?: return
        val chars = LinuxTerminalEmulator.columnsOf(line, grid.cols)
        fun isWord(i: Int): Boolean {
            val s = chars.getOrNull(i) ?: return false
            if (s.isEmpty()) return true // second column of a wide glyph
            val c = s[0]
            return !c.isWhitespace() && c !in WORD_SEPARATORS
        }
        if (!isWord(col)) {
            anchor = row to col
            head = row to col + 1
            return
        }
        var start = col
        while (start > 0 && isWord(start - 1)) start--
        var end = col
        while (end + 1 < chars.size && isWord(end + 1)) end++
        anchor = row to start
        head = row to end + 1
    }

    /** (startRow, startCol, endRow, endCol) with end exclusive, or null. */
    fun normalized(): Range? {
        val a = anchor ?: return null
        val h = head ?: return null
        val (start, end) = if (a.first < h.first || (a.first == h.first && a.second <= h.second)) a to h else h to a
        return Range(start.first, start.second, end.first, end.second)
    }

    fun text(emulator: LinuxTerminalEmulator): String? {
        val r = normalized() ?: return null
        if (r.startRow == r.endRow && r.startCol == r.endCol) return null
        return emulator.textInRange(r.startRow, r.startCol, r.endRow, r.endCol).takeIf { it.isNotEmpty() }
    }

    data class Range(val startRow: Int, val startCol: Int, val endRow: Int, val endCol: Int) {
        /** Columns [from, to) of [row] that are selected, or null. */
        fun columnsOn(row: Int, cols: Int): IntRange? {
            if (row < startRow || row > endRow) return null
            val from = if (row == startRow) startCol else 0
            val to = if (row == endRow) endCol else cols
            return if (to > from) from until to else null
        }
    }

    companion object {
        private val WORD_SEPARATORS = setOf(
            '(', ')', '[', ']', '{', '}', '<', '>', '"', '\'', '`', ',', ';', ':', '|', '&', '=',
        )
    }
}

/**
 * Whole-pixel cell box, so a fractional advance cannot make the grid drift.
 *
 * [letterSpacing] is the correction that keeps a drawn span on that grid — see
 * [rememberCellMetrics].
 */
data class CellMetrics(
    val width: Float,
    val height: Float,
    val letterSpacing: TextUnit = TextUnit.Unspecified,
)

/**
 * Measures the cell from one glyph, rounding **ascent and descent separately**.
 *
 * That split is not a detail: it is how Foot, Alacritty and kitty size a cell,
 * and it is what makes this grid line up with the terminal windows beside it.
 * JetBrainsMono at 24 px (Omarchy's 9 pt on a 2x panel) has ascent 24.48 and
 * descent 7.20 — rounded separately that is 25 + 8 = 33 px, which is exactly the
 * line pitch measured off a real Foot window. Ceiling the combined line box
 * instead gives ceil(31.68) = 32 px: the same glyphs, but every row 1 px tighter,
 * so a full-height window fits an extra row and the two terminals visibly drift
 * apart down the screen. Rounding both up also keeps the baseline on a whole
 * pixel, which is what keeps the glyphs crisp.
 */
@OptIn(ExperimentalTextApi::class)
@Composable
private fun rememberCellMetrics(measurer: TextMeasurer, style: TextStyle): CellMetrics {
    val density = LocalDensityValue()
    return remember(measurer, style, density) {
        cellMetricsFor(measurer, style, density)
    }
}

/**
 * The measurement itself, split out so it can be exercised without a
 * composition (see `TerminalCellMetricsTest`).
 *
 * The advance is measured over a [SAMPLE_RUN]-character run and divided, not
 * read from a one-character layout: a single measurement comes back as an
 * already-rounded Int, which hides the 0.4 px this whole calculation is about.
 */
internal fun cellMetricsFor(
    measurer: TextMeasurer,
    style: TextStyle,
    density: Density,
): CellMetrics {
    val run = measurer.measure("M".repeat(SAMPLE_RUN), style)
    val advance = run.size.width.toFloat() / SAMPLE_RUN

    val single = measurer.measure("M", style)
    val ascent = single.firstBaseline
    val descent = single.size.height.toFloat() - ascent

    // Round to NEAREST, not up: the cell is the advance, and Foot, Alacritty and
    // kitty all rasterise onto the rounded one (14 px for JetBrainsMono at 24 px,
    // measured off a live Foot window). Ceiling it instead made every column 1 px
    // wider than every other terminal on the desktop. The sub-pixel deficit the
    // rounding leaves is corrected by `letterSpacing` rather than by inflating
    // the cell, so nothing accumulates across a line.
    val width = kotlin.math.round(advance)

    return CellMetrics(
        width = width,
        // Ascent and descent round separately, matching how a terminal sizes a
        // cell and keeping the baseline on a whole pixel.
        height = kotlin.math.ceil(ascent) + kotlin.math.ceil(descent),
        letterSpacing = with(density) { (width - advance).toSp() },
    )
}

/** Long enough that dividing out the layout's integer rounding leaves < 0.01 px of error. */
private const val SAMPLE_RUN = 100

/**
 * Paints one grid snapshot.
 *
 * Backgrounds are filled per span before any text is drawn, so a reversed or
 * selected run does not get overpainted by the next span's glyphs. The
 * selection is a translucent overlay on top of the text, so it reads on any
 * cell colour without recolouring glyphs.
 */
@OptIn(ExperimentalTextApi::class)
private fun DrawScope.drawGrid(
    grid: TerminalGrid,
    cell: CellMetrics,
    measurer: TextMeasurer,
    baseStyle: TextStyle,
    defaultBackground: Color,
    defaultForeground: Color,
    selection: SelectionState.Range?,
    selectionColor: Color,
    cursorFocused: Boolean,
    blinkOn: Boolean,
) {
    grid.lines.forEachIndexed { rowIndex, line ->
        val y = rowIndex * cell.height
        var col = 0
        for (span in line.spans) {
            val x = col * cell.width
            val spanWidth = span.columns * cell.width

            // Reverse video swaps fg/bg here rather than in the emulator, so the
            // underlying cell colours stay truthful for selection and copy.
            val fg = if (span.reverse) Color(span.bg) else Color(span.fg)
            val bg = if (span.reverse) Color(span.fg) else Color(span.bg)

            if (bg != defaultBackground) {
                drawRect(color = bg, topLeft = Offset(x, y), size = Size(spanWidth, cell.height))
            }

            if (span.text.isNotBlank()) {
                val style = baseStyle.copy(
                    color = fg,
                    fontWeight = if (span.bold) FontWeight.Bold else FontWeight.Normal,
                    fontStyle = if (span.italic) FontStyle.Italic else FontStyle.Normal,
                    textDecoration = when {
                        span.underline > 0 && span.strike ->
                            TextDecoration.combine(listOf(TextDecoration.Underline, TextDecoration.LineThrough))
                        span.underline > 0 -> TextDecoration.Underline
                        span.strike -> TextDecoration.LineThrough
                        else -> null
                    },
                )
                drawText(
                    textMeasurer = measurer,
                    text = span.text,
                    style = style,
                    topLeft = Offset(x, y),
                    // A terminal row NEVER wraps — libvterm already decided what
                    // is on this line. `drawText` soft-wraps by default, and with
                    // no explicit size it lays out against the remaining canvas
                    // width, so a span reaching the right edge (a full-width row
                    // is one span of `cols` characters) spilled its tail onto the
                    // NEXT row's baseline. Nothing erases there, so the leftover
                    // stayed under that row's own text: after a Tab completion the
                    // prompt appeared a second time, offset, drawn through the
                    // completion menu. Clip at the edge instead, like every
                    // terminal does.
                    softWrap = false,
                    maxLines = 1,
                    size = Size(spanWidth, cell.height),
                )
            }
            col += span.columns
        }

        selection?.columnsOn(rowIndex, grid.cols)?.let { range ->
            drawRect(
                color = selectionColor.copy(alpha = selectionColor.alpha.coerceAtMost(0.45f)),
                topLeft = Offset(range.first * cell.width, y),
                size = Size((range.last + 1 - range.first) * cell.width, cell.height),
            )
        }
    }

    val cursor = grid.cursor
    if (cursor.visible && (!cursor.blink || blinkOn)) {
        val cx = cursor.col * cell.width
        val cy = cursor.row * cell.height
        val color = defaultForeground.copy(alpha = 0.75f)
        when {
            // An unfocused window shows a hollow block, so the cursor position
            // stays readable without claiming keyboard focus it does not have.
            !cursorFocused -> drawRect(
                color = color,
                topLeft = Offset(cx + 0.5f, cy + 0.5f),
                size = Size(cell.width - 1f, cell.height - 1f),
                style = Stroke(width = 1f),
            )
            cursor.shape == CursorShape.UNDERLINE -> drawRect(
                color = color,
                topLeft = Offset(cx, cy + cell.height - 2f),
                size = Size(cell.width, 2f),
            )
            cursor.shape == CursorShape.BAR -> drawRect(
                color = color,
                topLeft = Offset(cx, cy),
                size = Size(2f, cell.height),
            )
            else -> drawRect(
                color = color,
                topLeft = Offset(cx, cy),
                size = Size(cell.width, cell.height),
            )
        }
    }

    // A small marker while scrolled into history, so the frozen screen is not
    // mistaken for a hung program.
    if (grid.viewportOffset > 0) {
        val label = "↑ ${grid.viewportOffset}"
        val width = label.length * cell.width
        drawRect(
            color = defaultForeground.copy(alpha = 0.15f),
            topLeft = Offset(size.width - width - cell.width, 0f),
            size = Size(width + cell.width, cell.height),
        )
        drawText(
            textMeasurer = measurer,
            text = label,
            style = baseStyle.copy(color = defaultForeground),
            topLeft = Offset(size.width - width - cell.width / 2f, 0f),
            softWrap = false,
            maxLines = 1,
        )
    }
}

/**
 * `LocalDensity` is accessed through a helper so this file has one import site
 * for it; Compose Desktop and Android expose it under the same name but the
 * import churns between Compose versions.
 */
@Composable
private fun LocalDensityValue(): Density = androidx.compose.ui.platform.LocalDensity.current
