package relay.app

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.PathParser

/**
 * The tray icon, drawn rather than loaded from a file.
 *
 * A painted icon needs no binary asset in the repo, scales cleanly to whatever
 * size the tray asks for, and — the actual reason — can take its colour from the
 * active Omarchy palette, so it sits correctly in a light or dark bar instead of
 * being a fixed-contrast PNG that disappears in one of them.
 *
 * The mark is the app icon's folder stack without its tile, as one even-odd
 * path — the same mark the macOS menu bar shows (`MenuBarIcon`). Both come
 * from `Scripts/icons/make-icons.py`.
 */
class TrayIconPainter(
    private val foreground: Color,
) : Painter() {

    override val intrinsicSize: Size = Size(32f, 32f)

    override fun DrawScope.onDraw() {
        // Fit the glyph's box into the tray square with a little margin, centred.
        val k = minOf(size.width, size.height) * 0.84f / maxOf(GLYPH_WIDTH, GLYPH_HEIGHT)
        val dx = (size.width - GLYPH_WIDTH * k) / 2f
        val dy = (size.height - GLYPH_HEIGHT * k) / 2f
        translate(dx, dy) {
            scale(k, k, pivot = Offset.Zero) {
                drawPath(glyph, foreground)
            }
        }
    }

    private companion object {
        const val GLYPH_WIDTH = 88f
        const val GLYPH_HEIGHT = 84f

        /** The folder stack, in an 88 × 84 box (shared with MenuBarIcon.svg). */
        const val GLYPH_PATH =
            "M0,74 L0,32 A6,6 0 0 1 6,26 L34,26 C38.95,26 38.05,38 43,38 L82,38 A6,6 0 0 1 88,44 L88,74 A10,10 0 0 1 78,84 L10,84 A10,10 0 0 1 0,74 Z M10.25,29.5 L22.75,29.5 A3.25,3.25 0 0 1 22.75,36 L10.25,36 A3.25,3.25 0 0 1 10.25,29.5 Z M6,22 L6,19 A6,6 0 0 1 12,13 L40,13 C44.95,13 44.05,25 49,25 L79,25 A6,6 0 0 1 85,31 L85,34 L43,34 C38.05,34 38.95,22 34,22 Z M12,9 L12,6 A6,6 0 0 1 18,0 L46,0 C50.95,0 50.05,12 55,12 L76,12 A6,6 0 0 1 82,18 L82,21 L49,21 C44.05,21 44.95,9 40,9 Z"

        val glyph: Path = PathParser().parsePathString(GLYPH_PATH).toPath()
            .apply { fillType = PathFillType.EvenOdd }
    }
}
