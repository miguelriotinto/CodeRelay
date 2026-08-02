import XCTest
import Foundation
@testable import ClaudeRelayServer

/// Exercises the REAL `PTYSession.forceRepaint()` against a live PTY.
///
/// Regression context: the original implementation sent a bare SIGWINCH at
/// unchanged size. Node/Ink apps (Claude Code) re-query TIOCGWINSZ in their
/// WINCH handler and skip the redraw when the dimensions match their cache —
/// so tap-to-redraw delivered a signal that the target app ignored. The mock
/// tests couldn't catch that: they only assert the call happened. These tests
/// assert the observable contract instead: the PTY's size genuinely changes,
/// the intermediate value is *held* long enough to be observed, and the size
/// ends up restored to the newest client value.
///
/// Assertions read the kernel's `winsize` via
/// `PTYSession._testOnly_kernelWindowSize()` rather than making a shell
/// `echo $COLUMNS`. Master and slave share a single `struct winsize`, so this
/// reads the very state the child's TIOCGWINSZ reports — the same value Node
/// compares against its cache. Asserting through a shell instead adds a
/// requirement the contract doesn't include: the shell must be scheduled to run
/// a command and refresh `$COLUMNS` before the assertion reads it. On a GitHub
/// `macos-15` runner that didn't hold — test 1 saw no trap output at all, test 2
/// read a stale `$COLUMNS` — while both passed locally. (The CI evidence shows
/// the shell didn't *report* the new size in time; it does not establish where
/// in signal delivery that failed, so no diagnosis beyond "don't route the
/// assertion through the shell" is claimed here.) The mutation check still
/// holds: a regression back to a bare same-size SIGWINCH never changes the
/// kernel winsize, so both tests fail deterministically.
final class PTYForceRepaintTests: XCTestCase {

    private var pty: PTYSession?

    override func tearDown() async throws {
        if let pty {
            await pty.terminate()
        }
        pty = nil
    }

    /// The shortest time the intermediate width must stay observable to count as
    /// "held". Deliberately far below `forceRepaint`'s own 150 ms so this asserts
    /// the *contract* (a foreground process handling WINCH a few ms late still
    /// sees the new size) without pinning the implementation's constant. Measured
    /// headroom: a 15 ms hold satisfies "observed once" but fails this.
    private static let minimumHold: TimeInterval = 0.03

    /// Polls the PTY's kernel window size until `cols` is observed or `timeout`
    /// elapses. Returns the last size seen. Returns as soon as `cols` appears, so
    /// callers can act while the wiggle is still mid-flight.
    private func waitForCols(
        _ cols: UInt16,
        in session: PTYSession,
        timeout: TimeInterval
    ) async -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        var last = await session._testOnly_kernelWindowSize()?.cols
        while Date() < deadline {
            if last == cols { return last }
            try? await Task.sleep(nanoseconds: 5_000_000)
            last = await session._testOnly_kernelWindowSize()?.cols
        }
        return last
    }

    private struct HoldObservation {
        /// Whether `cols` was ever observed at all.
        var observed: Bool
        /// How long `cols` stayed continuously observable after first sighting.
        /// Measured from first to last sighting, so it *understates* the true
        /// hold by up to one poll interval — the assertion direction is safe.
        var heldFor: TimeInterval
        /// Last width seen, for the failure message when `observed` is false.
        var lastSeen: UInt16?
    }

    /// Polls until `cols` appears, then keeps polling until it goes away, and
    /// reports how long it remained.
    ///
    /// Distinct from `waitForCols`, which returns on first sighting: a single
    /// observation cannot distinguish a held intermediate size from a flicker,
    /// and the flicker is precisely the regression that makes Node/Ink apps skip
    /// the redraw.
    private func measureHold(
        of cols: UInt16,
        in session: PTYSession,
        timeout: TimeInterval
    ) async -> HoldObservation {
        let deadline = Date().addingTimeInterval(timeout)
        var firstSeen: Date?
        var lastSeen: Date?
        var last: UInt16?

        while Date() < deadline {
            last = await session._testOnly_kernelWindowSize()?.cols
            if last == cols {
                let now = Date()
                if firstSeen == nil { firstSeen = now }
                lastSeen = now
            } else if firstSeen != nil {
                break   // it was held and has now been restored
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        guard let first = firstSeen, let final = lastSeen else {
            return HoldObservation(observed: false, heldFor: 0, lastSeen: last)
        }
        return HoldObservation(observed: true, heldFor: final.timeIntervalSince(first), lastSeen: cols)
    }

    func testForceRepaintDeliversRealSizeChangeAndRestores() async throws {
        let session = try PTYSession(
            sessionId: UUID(),
            cols: 120,
            rows: 40,
            scrollbackSize: 64 * 1024
        )
        pty = session
        await session.startReading()

        let initial = await session._testOnly_kernelWindowSize()
        XCTAssertEqual(initial?.cols, 120, "PTY did not start at the requested width")

        // Run the wiggle concurrently with polling: the intermediate width (119)
        // is exactly what Node keys its redraw on, and it must be *held* for a
        // sustained window rather than flickering, or a foreground process that
        // handles WINCH a few ms later observes only the restored size and skips
        // the redraw. Measuring the hold (not just sighting it once) is what
        // makes the duration part of the contract enforceable. A regression back
        // to a bare same-size SIGWINCH never changes the kernel winsize at all,
        // so `observed` goes false and this fails deterministically.
        async let repaint: Void = session.forceRepaint()
        let hold = await measureHold(of: 119, in: session, timeout: 2.0)
        XCTAssertTrue(
            hold.observed,
            """
            the intermediate size was never observable (last saw \
            \(hold.lastSeen.map(String.init) ?? "nil")) — a repaint would be \
            skipped by Node/Ink apps
            """
        )
        XCTAssertGreaterThanOrEqual(
            hold.heldFor,
            Self.minimumHold,
            "the intermediate size flickered (held \(hold.heldFor)s) — a process handling WINCH late sees only the restored size"
        )
        await repaint

        // And the size must be restored afterwards.
        let restored = await session._testOnly_kernelWindowSize()
        XCTAssertEqual(restored?.cols, 120, "size was not restored after the wiggle")
        XCTAssertEqual(restored?.rows, 40, "rows must be untouched by the wiggle")
    }

    func testForceRepaintRestoresToNewestSizeWhenResizedMidWiggle() async throws {
        let session = try PTYSession(
            sessionId: UUID(),
            cols: 120,
            rows: 40,
            scrollbackSize: 64 * 1024
        )
        pty = session
        await session.startReading()

        // Land a client resize strictly *inside* the wiggle, then assert the
        // restore honours it. forceRepaint re-reads currentCols/currentRows
        // after its sleep precisely so a mid-flight resize wins.
        //
        // The interleaving is synchronized on observable state, not on task
        // start order: `async let` only creates the child task, it does not
        // guarantee it runs before the next statement. Simply calling
        // `resize(90)` on the following line therefore usually won the race and
        // landed *before* the wiggle began — at which point a stale-restore
        // implementation and a correct one both end at 90 and the test asserts
        // nothing. Verified: it passed against a deliberately stale restore.
        // Waiting for the kernel to actually hold 119 proves the wiggle is
        // mid-flight before the resize is issued.
        //
        // The resize changes BOTH dimensions, and both are asserted. Rows are
        // not incidental: with rows held at 40 throughout, a restore that reused
        // a stale pre-await `currentRows` while re-reading `currentCols` passed
        // both tests (verified by mutation). Device rotation changes rows and
        // cols together, so that is the realistic trigger, not a contrived one.
        async let repaint: Void = session.forceRepaint()
        let midWiggle = await waitForCols(119, in: session, timeout: 2.0)
        XCTAssertEqual(midWiggle, 119, "wiggle never started — the race below would be vacuous")
        await session.resize(cols: 90, rows: 25)
        await repaint

        let final = await session._testOnly_kernelWindowSize()
        XCTAssertEqual(final?.cols, 90, "mid-wiggle resize was stomped by forceRepaint's restore")
        XCTAssertEqual(final?.rows, 25, "mid-wiggle resize's ROWS were stomped by a stale restore")
    }
}
