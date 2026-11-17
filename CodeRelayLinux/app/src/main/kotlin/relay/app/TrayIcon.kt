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
 * The mark is the app icon's pane grid (top-middle pane hollow) without its
 * tile, as one even-odd path — the same mark the macOS menu bar shows (`MenuBarIcon`). Both come
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
        const val GLYPH_WIDTH = 84f
        const val GLYPH_HEIGHT = 50.5f

        /** The pane grid, in an 84 × 50.5 box (shared with MenuBarIcon.svg). */
        const val GLYPH_PATH =
            "M5,0 L19,0 A5,5 0 0 1 24,5 L24,18 A5,5 0 0 1 19,23 L5,23 A5,5 0 0 1 0,18 L0,5 A5,5 0 0 1 5,0 Z M35,0 L49,0 A5,5 0 0 1 54,5 L54,18 A5,5 0 0 1 49,23 L35,23 A5,5 0 0 1 30,18 L30,5 A5,5 0 0 1 35,0 Z M37.25,4.5 L46.75,4.5 A2.75,2.75 0 0 1 49.5,7.25 L49.5,15.75 A2.75,2.75 0 0 1 46.75,18.5 L37.25,18.5 A2.75,2.75 0 0 1 34.5,15.75 L34.5,7.25 A2.75,2.75 0 0 1 37.25,4.5 Z M65,0 L79,0 A5,5 0 0 1 84,5 L84,18 A5,5 0 0 1 79,23 L65,23 A5,5 0 0 1 60,18 L60,5 A5,5 0 0 1 65,0 Z M5,27.5 L19,27.5 A5,5 0 0 1 24,32.5 L24,45.5 A5,5 0 0 1 19,50.5 L5,50.5 A5,5 0 0 1 0,45.5 L0,32.5 A5,5 0 0 1 5,27.5 Z M35,27.5 L49,27.5 A5,5 0 0 1 54,32.5 L54,45.5 A5,5 0 0 1 49,50.5 L35,50.5 A5,5 0 0 1 30,45.5 L30,32.5 A5,5 0 0 1 35,27.5 Z M65,27.5 L79,27.5 A5,5 0 0 1 84,32.5 L84,45.5 A5,5 0 0 1 79,50.5 L65,50.5 A5,5 0 0 1 60,45.5 L60,32.5 A5,5 0 0 1 65,27.5 Z"

        val glyph: Path = PathParser().parsePathString(GLYPH_PATH).toPath()
            .apply { fillType = PathFillType.EvenOdd }
    }
}
