import XCTest
@testable import Code_Relay_

/// The text gets the same margin left and right, whatever the window width.
final class TerminalHostViewTests: XCTestCase {
    private func margins(_ frame: CGRect, in bounds: CGRect, cell: CGFloat, reserved: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let textWidth = frame.width - reserved
        XCTAssertEqual(textWidth.truncatingRemainder(dividingBy: cell), 0, accuracy: 0.001, "whole columns")
        return (frame.minX - bounds.minX, bounds.maxX - (frame.minX + textWidth))
    }

    func testMarginsAreEqualAcrossWidths() {
        for width in stride(from: 300.0, through: 1600.0, by: 37.0) {
            let bounds = CGRect(x: 0, y: 0, width: width, height: 500)
            let frame = TerminalHostView.terminalFrame(in: bounds, cellWidth: 7.5, reservedWidth: 0, minimumMargin: 12)
            let m = margins(frame, in: bounds, cell: 7.5, reserved: 0)
            XCTAssertGreaterThanOrEqual(m.left, 12, "width \(width)")
            XCTAssertEqual(m.left, m.right, accuracy: 0.5, "width \(width)")   // ≤ one Retina pixel
        }
    }

    func testScrollerStripSitsInsideTheRightMargin() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
        let frame = TerminalHostView.terminalFrame(in: bounds, cellWidth: 8, reservedWidth: 15, minimumMargin: 12)
        let m = margins(frame, in: bounds, cell: 8, reserved: 15)
        XCTAssertEqual(m.left, m.right, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(m.right, 15, "the scroller fits in the right margin")
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX)
    }

    func testFullHeightAndNeverWiderThanTheHost() {
        let bounds = CGRect(x: 0, y: 0, width: 50, height: 300)
        let frame = TerminalHostView.terminalFrame(in: bounds, cellWidth: 8, reservedWidth: 0, minimumMargin: 12)
        XCTAssertEqual(frame.height, 300)
        XCTAssertEqual(frame.width, 24, "a 50 pt host still fits floor((50 − 24) / 8) = 3 columns")
    }
}
