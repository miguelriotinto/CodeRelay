package relay.terminal.linux

import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
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

    val baseStyle = remember(fontSize, fontFamily) {
        TextStyle(fontFamily = fontFamily, fontSize = fontSize)
    }

    // One measurement of a representative glyph gives the cell box. Measuring a
    // wide-ish character rather than a space avoids a zero-advance surprise in
    // faces that collapse whitespace.
    val cell = rememberCellMetrics(measurer, baseStyle)

    val grid by emulator.grid.collectAsState()

    BoxWithConstraints(
        modifier = modifier
            .background(background)
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
        LaunchedEffect(cols, rows) {
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

/** Whole-pixel cell box, so a fractional advance cannot make the grid drift. */
data class CellMetrics(val width: Float, val height: Float)

@OptIn(ExperimentalTextApi::class)
@Composable
private fun rememberCellMetrics(measurer: TextMeasurer, style: TextStyle): CellMetrics =
    remember(measurer, style) {
        val layout = measurer.measure("M", style)
        CellMetrics(
            // Round up: rounding down would accumulate a sub-pixel deficit
            // across 200 columns and clip the last cell.
            width = kotlin.math.ceil(layout.size.width.toFloat()),
            height = kotlin.math.ceil(layout.size.height.toFloat()),
        )
    }

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
