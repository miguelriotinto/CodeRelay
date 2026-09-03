package relay.terminal.linux

import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import kotlin.math.floor
import kotlin.math.max
import androidx.compose.foundation.Canvas
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.runtime.collectAsState

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
    /**
     * Inset between the window frame and the first cell, matching the `pad` the
     * desktop's own terminals leave. Applied INSIDE the background so the fill
     * still reaches the frame — the gap has to be terminal-coloured, not a strip
     * of whatever is behind the window.
     */
    padding: Dp = 0.dp,
    onShortcut: (androidx.compose.ui.input.key.KeyEvent) -> Boolean = { false },
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

    BoxWithConstraints(
        modifier = modifier
            .background(background)
            .padding(padding)
            .focusRequester(focusRequester)
            .focusable()
            .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                // Application accelerators are all Ctrl+Shift / Ctrl+Alt, so a
                // bare Ctrl+C still reaches the agent.
                if (KeyMapping.isApplicationShortcut(event) && onShortcut(event)) return@onKeyEvent true
                when (val action = KeyMapping.map(event)) {
                    is KeyMapping.Action.SpecialKey -> {
                        emulator.dispatchKey(action.key, action.modifiers); true
                    }
                    is KeyMapping.Action.Character -> {
                        emulator.dispatchCharacter(action.codepoint, action.modifiers); true
                    }
                    KeyMapping.Action.Unhandled -> false
                }
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

        Canvas(
            Modifier
                .fillMaxSize()
                // Wheel → the running program, but ONLY while it has asked for
                // mouse reporting. In a plain shell mouseMode is 0, libvterm
                // emits nothing, and the event falls through to whatever local
                // scrolling exists — so this cannot corrupt a shell prompt.
                .onPointerEvent(PointerEventType.Scroll) { event ->
                    val change = event.changes.firstOrNull() ?: return@onPointerEvent
                    val delta = change.scrollDelta.y
                    if (delta == 0f) return@onPointerEvent
                    val pos = change.position
                    // libvterm takes 1-based cells.
                    val col = (pos.x / cell.width).toInt().coerceIn(0, cols - 1) + 1
                    val row = (pos.y / cell.height).toInt().coerceIn(0, rows - 1) + 1
                    // One notch per event; a high-resolution trackpad sends many
                    // small deltas, and banking them is a refinement for later.
                    emulator.dispatchWheel(down = delta > 0, row = row, col = col)
                },
        ) {
            drawGrid(
                grid = grid,
                cell = cell,
                measurer = measurer,
                baseStyle = baseStyle,
                defaultBackground = background,
                defaultForeground = foreground,
            )
        }
    }

    LaunchedEffect(Unit) { focusRequester.requestFocus() }
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
 * selected run does not get overpainted by the next span's glyphs.
 */
@OptIn(ExperimentalTextApi::class)
private fun DrawScope.drawGrid(
    grid: TerminalGrid,
    cell: CellMetrics,
    measurer: TextMeasurer,
    baseStyle: TextStyle,
    defaultBackground: Color,
    defaultForeground: Color,
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
    }

    if (grid.cursor.visible) {
        val cx = grid.cursor.col * cell.width
        val cy = grid.cursor.row * cell.height
        drawRect(
            color = defaultForeground.copy(alpha = 0.65f),
            topLeft = Offset(cx, cy),
            size = Size(cell.width, cell.height),
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
