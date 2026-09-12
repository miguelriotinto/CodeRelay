package relay.terminal.linux

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.createFontFamilyResolver
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.sp
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import kotlin.math.ceil

/**
 * Pins the terminal's cell box to the one Foot renders for the same font.
 *
 * The grid sits beside the user's other terminals, so "same font size" has to
 * mean the same glyph advance and the same line pitch, not merely the same
 * number in a config. Both numbers below were measured off a live Foot window
 * running Omarchy's stock `font=JetBrainsMono Nerd Font:size=9` on this 2x
 * panel: a column period of 14 px, and a run of text-line gaps that were all
 * exactly 33.0 px.
 *
 * This measures through Compose's real [TextMeasurer] — the same call
 * `rememberCellMetrics` makes — so it fails if the font size, the points→dp
 * conversion, or the ascent/descent rounding drifts. It needs no window.
 *
 * Skipped where JetBrainsMono Nerd Font is not installed (CI, another distro):
 * there is no meaningful assertion to make about a face that isn't there.
 */
class TerminalCellMetricsTest {

    private companion object {
        const val FAMILY = "JetBrainsMono Nerd Font"

        /** Omarchy's stock terminal size. */
        const val POINTS = 9f

        /** This panel's scale, and the density Compose derives from it. */
        const val DENSITY = 2f

        /** Measured from a live Foot window at the same font and scale. */
        const val FOOT_CELL_WIDTH = 14f
        const val FOOT_LINE_PITCH = 33f
    }

    private fun measurerAt(density: Float) = TextMeasurer(
        defaultFontFamilyResolver = createFontFamilyResolver(),
        defaultDensity = Density(density),
        defaultLayoutDirection = LayoutDirection.Ltr,
    )

    private fun styleAt(points: Float) = TextStyle(
        fontFamily = DesktopTerminalFont.resolveFamily(FAMILY),
        fontSize = DesktopTerminalFont.Spec(FAMILY, points).sizeDp.sp,
    )

    /** The renderer's own measurement, not a reimplementation of it. */
    private fun cell(points: Float, density: Float) =
        cellMetricsFor(measurerAt(density), styleAt(points), Density(density))

    private fun fontPresent(): Boolean =
        runCatching {
            org.jetbrains.skia.FontMgr.default
                .matchFamilyStyle(FAMILY, org.jetbrains.skia.FontStyle.NORMAL)
                ?.familyName == FAMILY
        }.getOrDefault(false)

    @Test
    fun `the cell box matches a live Foot window at 9pt on a 2x display`() {
        assumeTrue(fontPresent(), "$FAMILY not installed — skipping")

        val cell = cell(POINTS, DENSITY)

        assertEquals(FOOT_CELL_WIDTH, cell.width, "cell width must match Foot's column pitch")
        assertEquals(FOOT_LINE_PITCH, cell.height, "cell height must match Foot's line pitch")
    }

    /**
     * The correction that keeps a drawn span on the grid. Spans are painted as
     * whole strings at `col * cellWidth`, so the font's natural advance (14.4 px)
     * against a 14 px cell would walk a long run out from under its own
     * background rect and cursor. Letter spacing has to close exactly that gap.
     */
    @Test
    fun `letter spacing closes the gap between the advance and the cell`() {
        assumeTrue(fontPresent(), "$FAMILY not installed — skipping")

        val density = Density(DENSITY)
        val cell = cell(POINTS, DENSITY)
        val spacingPx = with(density) { cell.letterSpacing.toPx() }

        // JetBrainsMono advances 0.6 em: 14.4 px at 24 px, so the cell is 0.4 px short.
        assertEquals(-0.4f, spacingPx, 0.02f, "spacing must absorb the rounding, not ignore it")

        // The whole point: a run of N characters must occupy exactly N cells.
        val runLength = 40
        val style = styleAt(POINTS).copy(letterSpacing = cell.letterSpacing)
        val drawn = measurerAt(DENSITY).measure(AnnotatedString("M".repeat(runLength)), style)
        val expected = cell.width * runLength
        assertEquals(
            expected, drawn.size.width.toFloat(), 1.0f,
            "a $runLength-character span must be $runLength cells wide, not drift out of the grid",
        )
    }

    /**
     * The regression this replaced: a hard-coded 13.sp, which is 26 px rather
     * than 24 px, giving a 16 px advance — 14% wider per column than every other
     * terminal on the desktop.
     */
    @Test
    fun `the old hard-coded size did not match, which is why it is derived now`() {
        assumeTrue(fontPresent(), "$FAMILY not installed — skipping")

        val resolver = createFontFamilyResolver()
        val measurer = TextMeasurer(
            defaultFontFamilyResolver = resolver,
            defaultDensity = Density(DENSITY),
            defaultLayoutDirection = LayoutDirection.Ltr,
        )
        val style = TextStyle(
            fontFamily = DesktopTerminalFont.resolveFamily(FAMILY),
            fontSize = 13.sp,
        )
        val width = ceil(measurer.measure(AnnotatedString("M"), style).size.width.toFloat())

        assertEquals(16f, width, "sanity: the old size really was wider than Foot's 14px")
    }
}
