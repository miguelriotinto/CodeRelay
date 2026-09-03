package relay.app

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size

/**
 * The tray icon, drawn rather than loaded from a file.
 *
 * A painted icon needs no binary asset in the repo, scales cleanly to whatever
 * size the tray asks for, and — the actual reason — can take its colour from the
 * active Omarchy palette, so it sits correctly in a light or dark bar instead of
 * being a fixed-contrast PNG that disappears in one of them.
 *
 * The mark is a terminal prompt: a chevron and a caret.
 */
class TrayIconPainter(
    private val foreground: Color,
) : Painter() {

    override val intrinsicSize: Size = Size(32f, 32f)

    override fun DrawScope.onDraw() {
        val s = size.minDimension
        val stroke = (s * 0.09f).coerceAtLeast(1f)
        val left = (size.width - s) / 2f
        val top = (size.height - s) / 2f

        // Chevron: ">"
        drawLine(
            color = foreground,
            start = Offset(left + s * 0.22f, top + s * 0.28f),
            end = Offset(left + s * 0.48f, top + s * 0.50f),
            strokeWidth = stroke,
        )
        drawLine(
            color = foreground,
            start = Offset(left + s * 0.48f, top + s * 0.50f),
            end = Offset(left + s * 0.22f, top + s * 0.72f),
            strokeWidth = stroke,
        )
        // Caret: the underscore after the prompt.
        drawLine(
            color = foreground,
            start = Offset(left + s * 0.56f, top + s * 0.72f),
            end = Offset(left + s * 0.80f, top + s * 0.72f),
            strokeWidth = stroke,
        )
    }
}
