import AppKit
import SwiftTerm

/// Hosts the cached terminal views and gives the text the SAME margin on the
/// left and the right.
///
/// SwiftTerm fills its frame from the left with `floor(width / cellWidth)`
/// columns, so whatever does not divide evenly — up to a whole cell — piles up
/// on the right, and its scroller reserves a strip there too. Pinning the view
/// to the host's edges (as before, with a 6 pt leading pad) left text nearly
/// touching the left edge and a ragged gap on the right. Here each terminal is
/// sized to a whole number of columns and centred, with its scroller inside
/// the right margin.
final class TerminalHostView: NSView {
    /// The smallest gap between the window's content edge and the text.
    static let minimumMargin: CGFloat = 12

    override func layout() {
        super.layout()
        for case let terminal as TerminalView in subviews {
            let scale = window?.backingScaleFactor ?? 2
            let cell = Self.cellWidth(font: terminal.font, scale: scale)
            let reserved = Self.reservedWidth(of: terminal, cellWidth: cell)
            terminal.frame = Self.terminalFrame(in: bounds, cellWidth: cell, reservedWidth: reserved,
                                                minimumMargin: Self.minimumMargin, scale: scale)
        }
    }

    /// The terminal's frame: whole columns, centred, so the text has equal
    /// margins left and right (each at least `minimumMargin`); `reservedWidth`
    /// (SwiftTerm's scroller strip) extends the frame into the right margin
    /// and is never counted as text. The offset snaps to the pixel grid
    /// (`scale`), so the two margins differ by at most one pixel.
    static func terminalFrame(in bounds: CGRect, cellWidth: CGFloat, reservedWidth: CGFloat,
                              minimumMargin: CGFloat, scale: CGFloat = 2) -> CGRect {
        guard cellWidth > 0, bounds.width > 0 else { return bounds }
        let margin = max(minimumMargin, reservedWidth)
        let columns = max(1, floor((bounds.width - 2 * margin) / cellWidth))
        let textWidth = columns * cellWidth
        let x = (((bounds.width - textWidth) / 2) * scale).rounded(.down) / scale
        return CGRect(x: bounds.minX + x, y: bounds.minY,
                      width: textWidth + reservedWidth, height: bounds.height)
    }

    /// SwiftTerm's own cell width (`computeFontDimensions` on macOS): the "W"
    /// advance, snapped up to the pixel grid.
    static func cellWidth(font: NSFont, scale: CGFloat) -> CGFloat {
        let glyph = font.glyph(withName: "W")
        let advance = font.advancement(forGlyph: glyph).width
        return max(1, ceil(advance * scale) / scale)
    }

    /// The width SwiftTerm keeps for its scroller, read from its public
    /// optimal-frame size (columns × cell + that strip).
    private static func reservedWidth(of terminal: TerminalView, cellWidth: CGFloat) -> CGFloat {
        let cols = CGFloat(terminal.getTerminal().cols)
        return max(0, terminal.getOptimalFrameSize().width - cols * cellWidth)
    }
}
