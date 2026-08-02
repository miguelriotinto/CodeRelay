import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

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
/// Assertions read the kernel's `winsize` via `PTYSession.kernelWindowSize()`
/// rather than making a shell `echo $COLUMNS`. Master and slave share one
/// `struct winsize`, so this is byte-for-byte what the child's TIOCGWINSZ
/// returns — the same value Node compares against its cache. Going through a
/// shell instead adds two requirements the contract doesn't include and CI
/// does not satisfy: SIGWINCH must reach the shell's process group (the
/// session's shell is a grandchild of setuid `login`, so its membership in the
/// tty's foreground pgrp is environment-dependent), and the shell must then be
/// scheduled to run a command. On a GitHub `macos-15` runner neither held —
/// test 1 saw no trap output at all and test 2 read a stale `$COLUMNS` — while
/// both passed locally. The mutation check still holds: a regression back to a
/// bare same-size SIGWINCH never changes the kernel winsize, so both tests
/// fail deterministically.
final class PTYForceRepaintTests: XCTestCase {

    private var pty: PTYSession?

    override func tearDown() async throws {
        if let pty {
            await pty.terminate()
        }
        pty = nil
    }

    /// Polls the PTY's kernel window size until `cols` is observed or `timeout`
    /// elapses. Returns the last size seen.
    @discardableResult
    private func waitForCols(
        _ cols: UInt16,
        in session: PTYSession,
        timeout: TimeInterval
    ) async -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        var last = await session.kernelWindowSize()?.cols
        while Date() < deadline {
            if last == cols { return last }
            try? await Task.sleep(nanoseconds: 5_000_000)
            last = await session.kernelWindowSize()?.cols
        }
        return last
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

        let initial = await session.kernelWindowSize()
        XCTAssertEqual(initial?.cols, 120, "PTY did not start at the requested width")

        // Run the wiggle concurrently with polling: the intermediate width (119)
        // is exactly what Node keys its redraw on, and it must be *held* for a
        // sustained window rather than flickering, or a foreground process that
        // handles WINCH a few ms later observes only the restored size and skips
        // the redraw. A regression back to a bare same-size SIGWINCH never
        // changes the kernel winsize at all, so this fails deterministically.
        async let repaint: Void = session.forceRepaint()
        let intermediate = await waitForCols(119, in: session, timeout: 2.0)
        XCTAssertEqual(
            intermediate,
            119,
            "the intermediate size was never observable — a repaint would be skipped by Node/Ink apps"
        )
        await repaint

        // And the size must be restored afterwards.
        let restored = await session.kernelWindowSize()
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
        async let repaint: Void = session.forceRepaint()
        let midWiggle = await waitForCols(119, in: session, timeout: 2.0)
        XCTAssertEqual(midWiggle, 119, "wiggle never started — the race below would be vacuous")
        await session.resize(cols: 90, rows: 40)
        await repaint

        let final = await session.kernelWindowSize()
        XCTAssertEqual(final?.cols, 90, "mid-wiggle resize was stomped by forceRepaint's restore")
    }
}
