import XCTest
import UIKit
import SwiftTerm
@testable import ClaudeRelayApp

/// Guards the one gesture a phone terminal cannot afford to give away: the
/// one-finger swipe.
///
/// The regression as reported: swiping up or down in a Claude Code session
/// highlighted a block of terminal text and the agent answered "copied 393
/// characters to clipboard" instead of the view scrolling. Claude Code enables
/// mouse tracking (`CSI ? 1000 h` + `CSI ? 1006 h`) on startup, and SwiftTerm's
/// `mouseModeChanged` responds by installing a one-finger `UIPanGestureRecognizer`
/// (`panMouseHandler`) that reports the drag upstream as a mouse press → release.
/// On a pointer device that is correct; on a touch device the one-finger drag is
/// the only way to scroll, so it belongs to the `UIScrollView` that `TerminalView`
/// is.
///
/// It became destructive rather than merely inert in the SwiftTerm 1.13 → 1.15
/// bump: upstream #586 changed iOS taps/drags from button 1 (middle) to button 0
/// (left), turning a drag no TUI acts on into a selection drag.
///
/// `RelayTerminalView` therefore overrides `mouseModeChanged` to do nothing.
/// These tests fail against the un-overridden implementation.
@MainActor
final class TerminalSwipeScrollTests: XCTestCase {

    /// A laid-out terminal with a monospace font, so SwiftTerm has a real cell
    /// dimension and row count (same setup as `TerminalScrollSyncTests`).
    private func makeView() -> RelayTerminalView {
        let view = RelayTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.layoutIfNeeded()
        return view
    }

    /// Every `UIPanGestureRecognizer` on the view except the scroll view's own —
    /// i.e. everything that could intercept a swipe before it scrolls.
    private func addedPanGestures(on view: RelayTerminalView) -> [UIPanGestureRecognizer] {
        (view.gestureRecognizers ?? [])
            .compactMap { $0 as? UIPanGestureRecognizer }
            .filter { $0 !== view.panGestureRecognizer }
    }

    /// The sequences that turn tracking on, weakest to strongest. 1003 (anyEvent)
    /// is the worst case: it reports motion with no button held at all.
    private let mouseModeEnablers: [(name: String, bytes: String)] = [
        ("1000 vt200", "\u{1B}[?1000h"),
        ("1002 buttonEventTracking", "\u{1B}[?1002h"),
        ("1003 anyEvent", "\u{1B}[?1003h"),
        ("1000+1006 (what Claude Code sends)", "\u{1B}[?1000h\u{1B}[?1006h")
    ]

    // MARK: - The swipe stays with the scroll view

    func testEnablingMouseTrackingInstallsNoPanGesture() {
        for enabler in mouseModeEnablers {
            let view = makeView()
            XCTAssertTrue(addedPanGestures(on: view).isEmpty,
                          "\(enabler.name): precondition — no extra pan before tracking is on")

            view.feedTrackingScrollbackClear(ArraySlice(Array(enabler.bytes.utf8)))

            // Without this the test would pass vacuously against a view that
            // simply never saw the sequence.
            XCTAssertNotEqual(view.getTerminal().mouseMode, .off,
                              "\(enabler.name): the emulator must actually have entered mouse mode")
            XCTAssertTrue(addedPanGestures(on: view).isEmpty,
                          "\(enabler.name): a swipe would be reported as a mouse drag instead of scrolling")
        }
    }

    /// Mouse mode goes on and off repeatedly across a session (an agent enables
    /// it, a pager disables it). No path through those transitions may leave a
    /// pan behind.
    func testMouseModeTogglingNeverLeavesAPanGesture() {
        let view = makeView()
        for _ in 0..<3 {
            view.feedTrackingScrollbackClear(ArraySlice(Array("\u{1B}[?1002h".utf8)))
            XCTAssertNotEqual(view.getTerminal().mouseMode, .off)
            XCTAssertTrue(addedPanGestures(on: view).isEmpty, "enabling must not add a pan")

            view.feedTrackingScrollbackClear(ArraySlice(Array("\u{1B}[?1002l".utf8)))
            XCTAssertEqual(view.getTerminal().mouseMode, .off)
            XCTAssertTrue(addedPanGestures(on: view).isEmpty, "disabling must not add a pan either")
        }
    }

    /// The other side of the same property: with tracking on, the scroll view is
    /// still the one holding the swipe. A real drag can't be injected here (a
    /// `UIGestureRecognizer` needs a genuine touch sequence), so the testable
    /// statement is that nothing about entering mouse mode disarms the scroll
    /// view or leaves it with nowhere to scroll.
    func testScrollViewStillOwnsTheSwipeWhileMouseTrackingIsOn() {
        let view = makeView()
        let rows = view.getTerminal().rows
        XCTAssertGreaterThan(rows, 4, "test needs a real laid-out grid")

        let text = (0..<(rows * 3)).map { "line \($0)\r\n" }.joined()
        view.feedTrackingScrollbackClear(ArraySlice(Array(text.utf8)))
        view.feedTrackingScrollbackClear(ArraySlice(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8)))

        XCTAssertNotEqual(view.getTerminal().mouseMode, .off)
        XCTAssertTrue(view.isScrollEnabled, "mouse mode must not disable scrolling")
        XCTAssertTrue(view.panGestureRecognizer.isEnabled,
                      "the scroll view's own pan must stay armed")
        XCTAssertGreaterThan(view.contentSize.height, view.bounds.height,
                            "there must be history for the swipe to reach")
    }

    // MARK: - What the fix must NOT cost

    /// The narrow fix is dropping the *pan*. Muting `allowMouseReporting` would
    /// have been broader and wrong: `singleTap`/`doubleTap`/`tripleTap` consult
    /// that flag independently, and a tap is a click the user does want sent —
    /// it is how an agent's clickable UI works.
    func testTapsAreStillReportedAsClicks() {
        let view = makeView()
        view.feedTrackingScrollbackClear(ArraySlice(Array("\u{1B}[?1000h".utf8)))

        XCTAssertTrue(view.allowMouseReporting,
                      "taps must still reach the remote app; only the pan is dropped")
        XCTAssertNotEqual(view.getTerminal().mouseMode, .off,
                          "and the emulator must still know tracking is on")
    }
}
