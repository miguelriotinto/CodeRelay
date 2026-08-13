import XCTest
import UIKit
import SwiftTerm
@testable import ClaudeRelayApp

/// Guards the terminal's scroll geometry against app-side interference.
///
/// The app feeds every output frame through
/// `RelayTerminalView.feedTrackingScrollbackClear`. That hook exists to repair
/// one thing only — the scroll geometry left stale by `CSI 3 J`, which SwiftTerm
/// applies without notifying the view. Anything beyond that is a hazard: only
/// SwiftTerm knows the true cell height and whether a gesture is in flight, so
/// app-side offset math ends up fighting the user's own scrolling.
///
/// The regression these tests lock down: while the user is scrolled up into
/// history, SwiftTerm deliberately stops syncing `yDisp` from `contentOffset`
/// once the finger lifts (see `syncYDispFromContentOffset`'s `isTracking`
/// guard), so a downward fling legitimately runs the offset ahead of `yDisp`.
/// App code that read that gap as "stale geometry" truncated `contentSize` to
/// the lift point, deleting the content below it — the user could scroll up but
/// never back down to the prompt, and nothing restored the content height until
/// the next output arrived.
@MainActor
final class TerminalScrollSyncTests: XCTestCase {

    /// A laid-out terminal with a monospace font, so SwiftTerm has a real cell
    /// dimension and a non-zero row count to work from.
    private func makeView() -> RelayTerminalView {
        let view = RelayTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.layoutIfNeeded()
        return view
    }

    /// Fills the scrollback with `count` numbered lines of output.
    private func feedLines(_ count: Int, into view: RelayTerminalView) {
        let text = (0..<count).map { "line \($0)\r\n" }.joined()
        view.feedTrackingScrollbackClear(ArraySlice(Array(text.utf8)))
    }

    // MARK: - The scroll-down lock

    /// The bug as reported: scrolled up into history, output arrives, and the
    /// way back down disappears.
    ///
    /// `contentSize.height` must never come back smaller than SwiftTerm set it —
    /// that height IS the user's ability to scroll down, and only SwiftTerm may
    /// shrink it (when the buffer really did lose lines).
    func testOutputWhileScrolledUpDoesNotTruncateTheContentBelow() {
        let view = makeView()
        let rows = view.getTerminal().rows
        XCTAssertGreaterThan(rows, 4, "test needs a real laid-out grid")

        feedLines(rows * 3, into: view)
        view.scrollUp(lines: rows)               // user scrolls a page into history

        let reachableHeight = view.contentSize.height

        // The finger lifts and momentum coasts downward. SwiftTerm freezes yDisp
        // for the coast, so the offset now legitimately sits ahead of it —
        // half a page here, well clear of the two-cell slop the old check used.
        let cellHeight = view.bounds.height / CGFloat(rows)
        view.contentOffset.y += cellHeight * CGFloat(rows / 2)
        let coastingOffset = view.contentOffset.y

        // Output lands mid-coast (no newline: the buffer must not grow, so any
        // change in contentSize is the app's doing, not SwiftTerm's).
        view.feedTrackingScrollbackClear(ArraySlice(Array("x".utf8)))

        XCTAssertGreaterThanOrEqual(
            view.contentSize.height, reachableHeight,
            "output must not shrink the scrollable content — that is the scroll-down lock"
        )
        XCTAssertEqual(
            view.contentOffset.y, coastingOffset, accuracy: 0.5,
            "output must not yank a coasting scroll back up"
        )
    }

    /// The same invariant for the ordinary case — parked in history with no
    /// gesture in flight, output arriving. SwiftTerm keeps the user's position;
    /// the app must not second-guess it.
    func testOutputWhileParkedInHistoryKeepsThePositionAndTheContent() {
        let view = makeView()
        let rows = view.getTerminal().rows

        feedLines(rows * 3, into: view)
        view.scrollUp(lines: rows)

        let parkedOffset = view.contentOffset.y
        let reachableHeight = view.contentSize.height

        view.feedTrackingScrollbackClear(ArraySlice(Array("x".utf8)))

        XCTAssertEqual(view.contentOffset.y, parkedOffset, accuracy: 0.5,
                       "a quiet chunk must not move the user's view")
        XCTAssertGreaterThanOrEqual(view.contentSize.height, reachableHeight)
    }

    // MARK: - The case the hook is actually for

    /// `CSI 3 J` really does invalidate the geometry: the history is gone, so the
    /// content height must come down with it rather than leaving the user
    /// scrolling through lines that no longer exist.
    func testClearingScrollbackShrinksTheContentToWhatIsLeft() {
        let view = makeView()
        let rows = view.getTerminal().rows

        feedLines(rows * 3, into: view)
        let heightWithHistory = view.contentSize.height

        // What `clear` sends: home, erase display, erase saved lines.
        view.feedTrackingScrollbackClear(ArraySlice(Array("\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8)))

        XCTAssertLessThan(view.contentSize.height, heightWithHistory,
                          "clearing the scrollback must retire the trimmed lines")
        XCTAssertLessThanOrEqual(
            view.contentOffset.y, max(0, view.contentSize.height - view.bounds.height) + 1,
            "the view must not be left parked past the end of the content"
        )
    }

    // MARK: - Scanner

    func testScannerDetectsClearScrollback() {
        var scanner = ScrollbackClearScanner()
        XCTAssertTrue(scanner.scan(ArraySlice(Array("\u{1B}[3J".utf8))))
    }

    func testScannerIgnoresOtherEraseSequences() {
        var scanner = ScrollbackClearScanner()
        XCTAssertFalse(scanner.scan(ArraySlice(Array("\u{1B}[2J".utf8))), "clear screen keeps history")
        XCTAssertFalse(scanner.scan(ArraySlice(Array("\u{1B}[J".utf8))), "erase-to-end keeps history")
        XCTAssertFalse(scanner.scan(ArraySlice(Array("\u{1B}[33J".utf8))), "33 is not 3")
        XCTAssertFalse(scanner.scan(ArraySlice(Array("\u{1B}[3;1J".utf8))), "only a bare 3 clears scrollback")
        XCTAssertFalse(scanner.scan(ArraySlice(Array("\u{1B}[3m".utf8))), "SGR italic, not an erase")
    }

    func testScannerIgnoresLiteralText() {
        var scanner = ScrollbackClearScanner()
        XCTAssertFalse(scanner.scan(ArraySlice(Array("see [3J in the docs".utf8))))
    }

    /// Output arrives in frames of arbitrary length, so the sequence has to be
    /// recognised even when it is cut in half between two feeds.
    func testScannerSpansFeedBoundaries() {
        for splitPoint in 1..<4 {
            var scanner = ScrollbackClearScanner()
            let bytes = Array("\u{1B}[3J".utf8)
            let first = scanner.scan(ArraySlice(bytes[..<splitPoint]))
            let second = scanner.scan(ArraySlice(bytes[splitPoint...]))
            XCTAssertFalse(first, "split \(splitPoint): must not fire on the partial sequence")
            XCTAssertTrue(second, "split \(splitPoint): must fire once the final byte arrives")
        }
    }

    /// An abandoned escape must not leave the parser primed to misread later
    /// text as the tail of a sequence.
    func testScannerRecoversFromAbandonedEscape() {
        var scanner = ScrollbackClearScanner()
        XCTAssertFalse(scanner.scan(ArraySlice(Array("\u{1B}[3".utf8))))
        XCTAssertFalse(scanner.scan(ArraySlice(Array("\u{07}J".utf8))), "a control byte abandons the sequence")
        XCTAssertTrue(scanner.scan(ArraySlice(Array("\u{1B}[3J".utf8))), "the parser must still work afterwards")
    }

    /// Several sequences in one frame, only one of which matters.
    func testScannerFindsClearAmongOtherSequences() {
        var scanner = ScrollbackClearScanner()
        let stream = "\u{1B}[0m\u{1B}[2J\u{1B}[3J\u{1B}[?25h"
        XCTAssertTrue(scanner.scan(ArraySlice(Array(stream.utf8))))
    }
}
