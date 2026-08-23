import XCTest
import UIKit
import SwiftTerm
@testable import ClaudeRelayApp

/// Records what the terminal sends back to the host, which is where a wheel
/// report ends up. Deliberately non-isolated, matching the app's own
/// `IOSTerminalCoordinator`, so it satisfies the non-isolated protocol.
private final class RecordingTerminalDelegate: NSObject, TerminalViewDelegate {
    var sent: [UInt8] = []

    var sentText: String { String(decoding: sent, as: UTF8.self) }

    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func scrolled(source: TerminalView, position: Double) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Guards the one gesture a phone terminal cannot afford to get wrong: the
/// one-finger swipe.
///
/// Two regressions, one gesture. First a swipe *selected* text — SwiftTerm's
/// `mouseModeChanged` installs a pan that reports the drag as a button drag, and
/// upstream #586 (SwiftTerm 1.13 → 1.15) changed iOS drags from button 1 to
/// button 0, so Claude Code read it as a selection and answered "copied 393
/// characters to clipboard". Suppressing that pan stopped the selection but the
/// swipe then did nothing at all, because:
///
/// Claude Code runs in the **alternate screen buffer** (`CSI ? 1049 h`), which
/// has no scrollback. `contentSize.height` is `rows * cellHeight`, so the
/// `UIScrollView` has nothing to scroll — the viewport is not what moves. The
/// agent's own transcript is, and it scrolls on **wheel reports** (buttons 4/5,
/// SGR-encoded under `CSI ? 1006 h`), which is what macOS's `scrollWheel`
/// already sends and iOS had no source for.
///
/// So the contract is: while a program tracks the mouse, a swipe is a wheel
/// report; while it does not, the swipe belongs to the scroll view and its real
/// local scrollback.
@MainActor
final class TerminalSwipeScrollTests: XCTestCase {

    /// A laid-out terminal with a monospace font, so SwiftTerm has a real cell
    /// dimension and row count (same setup as `TerminalScrollSyncTests`).
    private func makeView() -> (RelayTerminalView, RecordingTerminalDelegate) {
        let view = RelayTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let delegate = RecordingTerminalDelegate()
        view.terminalDelegate = delegate
        view.layoutIfNeeded()
        return (view, delegate)
    }

    /// Every `UIPanGestureRecognizer` on the view except the scroll view's own.
    private func addedPanGestures(on view: RelayTerminalView) -> [UIPanGestureRecognizer] {
        (view.gestureRecognizers ?? [])
            .compactMap { $0 as? UIPanGestureRecognizer }
            .filter { $0 !== view.panGestureRecognizer }
    }

    /// The sequences that turn tracking on, weakest to strongest. The last is
    /// what Claude Code actually sends.
    private let mouseModeEnablers: [(name: String, bytes: String)] = [
        ("1000 vt200", "\u{1B}[?1000h"),
        ("1002 buttonEventTracking", "\u{1B}[?1002h"),
        ("1003 anyEvent", "\u{1B}[?1003h"),
        ("1000+1006 (what Claude Code sends)", "\u{1B}[?1000h\u{1B}[?1006h")
    ]

    private func enableTracking(_ view: RelayTerminalView, _ bytes: String = "\u{1B}[?1000h\u{1B}[?1006h") {
        view.feedTrackingScrollbackClear(ArraySlice(Array(bytes.utf8)))
    }

    // MARK: - A swipe reaches the agent as a wheel report

    /// The bug the user reported twice: with tracking on, dragging must produce
    /// wheel notches. One row of travel is one notch, matching the trackpad.
    func testDraggingDownSendsWheelUp() {
        for enabler in mouseModeEnablers {
            let (view, delegate) = makeView()
            enableTracking(view, enabler.bytes)
            XCTAssertNotEqual(view.getTerminal().mouseMode, .off,
                              "\(enabler.name): the emulator must actually have entered mouse mode")
            delegate.sent.removeAll()

            let notches = view.sendWheel(travel: view.wheelRowHeight * 3,
                                         at: CGPoint(x: 100, y: 200))

            XCTAssertEqual(notches, 3, "\(enabler.name): three rows of travel is three notches")
            // SGR wheel-up is button 64; 1000-only sessions fall back to X10,
            // where the same button arrives as byte 64 + 32.
            let text = delegate.sentText
            let sawSGR = text.contains("<64;")
            let sawX10 = delegate.sent.contains(UInt8(64 + 32))
            XCTAssertTrue(sawSGR || sawX10,
                          "\(enabler.name): expected a wheel-up report, got \(text.debugDescription)")
            XCTAssertFalse(text.contains("<0;"),
                           "\(enabler.name): must never report a left-button press — that is the selection bug")
        }
    }

    func testDraggingUpSendsWheelDown() {
        let (view, delegate) = makeView()
        enableTracking(view)
        delegate.sent.removeAll()

        let notches = view.sendWheel(travel: -view.wheelRowHeight * 2, at: CGPoint(x: 100, y: 200))

        XCTAssertEqual(notches, -2)
        XCTAssertTrue(delegate.sentText.contains("<65;"),
                      "expected wheel-down (button 65), got \(delegate.sentText.debugDescription)")
    }

    /// A slow drag moves a few points per callback. Dropping sub-row travel
    /// instead of banking it would make those swipes do nothing at all.
    func testSubRowTravelAccumulatesInsteadOfBeingDropped() {
        let (view, delegate) = makeView()
        enableTracking(view)
        delegate.sent.removeAll()

        let sixth = view.wheelRowHeight / 6
        for _ in 0..<5 {
            XCTAssertEqual(view.sendWheel(travel: sixth, at: CGPoint(x: 10, y: 10)), 0,
                           "a fraction of a row is not yet a notch")
        }
        XCTAssertTrue(delegate.sent.isEmpty, "nothing should have been reported yet")

        XCTAssertEqual(view.sendWheel(travel: sixth, at: CGPoint(x: 10, y: 10)), 1,
                       "the sixth sixth completes a row and fires one notch")
    }

    /// The report carries the cell under the finger: tmux and split-pane TUIs
    /// scroll the pane the pointer is over, not the focused one.
    func testWheelReportCarriesTheCellUnderTheFinger() {
        let (view, delegate) = makeView()
        enableTracking(view)
        delegate.sent.removeAll()

        let point = CGPoint(x: view.wheelColumnWidth * 12.5, y: view.wheelRowHeight * 7.5)
        view.sendWheel(travel: view.wheelRowHeight, at: point)

        // SGR coordinates are 1-based, so column 12 / row 7 report as 13 / 8.
        XCTAssertTrue(delegate.sentText.contains("<64;13;8M"),
                      "expected the cell under the finger, got \(delegate.sentText.debugDescription)")
    }

    // MARK: - And never reaches a shell that did not ask for it

    /// The other half of the contract. With no program tracking the mouse the
    /// swipe belongs to the scroll view, whose scrollback is real: reporting
    /// anything here would send stray bytes to a bare shell prompt.
    func testNoWheelReportWhenNothingIsTrackingTheMouse() {
        let (view, delegate) = makeView()
        view.feedTrackingScrollbackClear(ArraySlice(Array("ready\r\n".utf8)))
        XCTAssertEqual(view.getTerminal().mouseMode, .off, "precondition: no tracking")
        delegate.sent.removeAll()

        XCTAssertEqual(view.sendWheel(travel: view.wheelRowHeight * 4, at: CGPoint(x: 10, y: 10)), 0)
        XCTAssertTrue(delegate.sent.isEmpty,
                      "a shell must receive nothing, got \(delegate.sentText.debugDescription)")
    }

    func testWheelPanIsOnlyArmedWhileTrackingIsOn() {
        let (view, _) = makeView()
        XCTAssertTrue(addedPanGestures(on: view).allSatisfy { !$0.isEnabled },
                      "nothing may compete with the scroll view before tracking starts")

        for _ in 0..<3 {
            enableTracking(view, "\u{1B}[?1002h")
            XCTAssertNotEqual(view.getTerminal().mouseMode, .off)
            let armed = addedPanGestures(on: view).filter(\.isEnabled)
            XCTAssertEqual(armed.count, 1, "exactly one pan carries the swipe while tracking is on")

            enableTracking(view, "\u{1B}[?1002l")
            XCTAssertEqual(view.getTerminal().mouseMode, .off)
            XCTAssertTrue(addedPanGestures(on: view).allSatisfy { !$0.isEnabled },
                          "turning tracking off must hand the swipe back to the scroll view")
        }
    }

    /// With tracking off the scroll view must still own the swipe outright: its
    /// own pan armed, scrolling enabled, and history to reach.
    func testScrollViewKeepsTheSwipeWhenTrackingIsOff() {
        let (view, _) = makeView()
        let rows = view.getTerminal().rows
        XCTAssertGreaterThan(rows, 4, "test needs a real laid-out grid")

        let text = (0..<(rows * 3)).map { "line \($0)\r\n" }.joined()
        view.feedTrackingScrollbackClear(ArraySlice(Array(text.utf8)))

        XCTAssertEqual(view.getTerminal().mouseMode, .off)
        XCTAssertTrue(view.isScrollEnabled)
        XCTAssertTrue(view.panGestureRecognizer.isEnabled)
        XCTAssertGreaterThan(view.contentSize.height, view.bounds.height,
                            "there must be history for the swipe to reach")
    }

    // MARK: - What the fix must NOT cost

    /// Muting `allowMouseReporting` would have been the broad fix and is wrong:
    /// `singleTap`/`doubleTap`/`tripleTap` consult it independently, and a tap is
    /// a click the user does want sent — it is how an agent's clickable UI works.
    func testTapsAreStillReportedAsClicks() {
        let (view, _) = makeView()
        enableTracking(view, "\u{1B}[?1000h")

        XCTAssertTrue(view.allowMouseReporting,
                      "taps must still reach the remote app; only the drag changes meaning")
        XCTAssertNotEqual(view.getTerminal().mouseMode, .off,
                          "and the emulator must still know tracking is on")
    }
}
