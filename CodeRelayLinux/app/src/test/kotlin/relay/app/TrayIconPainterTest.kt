package relay.app

import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** The tray paints the app icon's CR glyph; its path is parsed at class init. */
class TrayIconPainterTest {

    @Test
    fun `paints the CR glyph centred, in the palette colour, inside the square`() {
        val n = 64
        val image = ImageBitmap(n, n)
        CanvasDrawScope().draw(Density(1f), LayoutDirection.Ltr, Canvas(image), Size(n.toFloat(), n.toFloat())) {
            with(TrayIconPainter(Color.White)) { draw(size) }
        }
        val px = image.toPixelMap()
        var lit = 0; var minX = n; var maxX = -1; var minY = n; var maxY = -1
        for (y in 0 until n) for (x in 0 until n) {
            if (px[x, y].alpha > 0.5f) {
                lit++
                minX = minOf(minX, x); maxX = maxOf(maxX, x); minY = minOf(minY, y); maxY = maxOf(maxY, y)
            }
        }
        // A stroked glyph covers a fair share of its box, not a dot or a filled square.
        assertTrue(lit in (n * n / 10)..(n * n / 2), "lit=$lit")
        // 84% of the height, aspect 0.872, centred — so nothing is clipped.
        assertTrue(maxY - minY in 50..55, "height ${maxY - minY}")
        assertTrue(maxX - minX in 43..49, "width ${maxX - minX}")
        assertTrue(minX > 0 && maxX < n - 1 && minY > 0 && maxY < n - 1, "clipped")
    }
}
