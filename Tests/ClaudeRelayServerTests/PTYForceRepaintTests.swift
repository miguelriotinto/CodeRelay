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

    /// The PTY's current size, skipping the test if no size can be read.
    ///
    /// Every read of the size goes through here so a dead fd is never asserted
    /// against as though it were a wrong size. `XCTAssertEqual(nil, 120)` reports
    /// "PTY did not start at the requested width" when in fact the child shell
    /// died and there is no width to report — a product accusation for an
    /// environmental failure. Found by mutation: forcing
    /// `_testOnly_kernelWindowSize()` to fail produced exactly that message from
    /// the pre-wiggle check.
    ///
    /// Skipping on *any* read failure — rather than only on `.fdClosed` — is
    /// deliberate, and the reason is a property of pty masters rather than a
    /// convenience: an `ioctlFailed` is not reachable from here. `TIOCGWINSZ` keeps
    /// returning the stored `winsize` even after the child is gone, a non-tty fd is
    /// impossible on this path, and `_testOnly_kernelWindowSize()` short-circuits on
    /// `fdClosed` before issuing the ioctl at all — so the surviving failure mode is
    /// `.fdClosed`, and the two cases need not be told apart to decide on a skip.
    ///
    /// The skip message attributes that to the child hanging up, which holds for the
    /// tests that call this helper but is *not* a property of the flag: `fdClosed` is
    /// also set by `_testOnly_markMasterFDClosed()`, which leaves the descriptor open
    /// and no child dead. No test both marks the flag and then reads through here
    /// (`testWindowSizeReportsClosedFDRatherThanProbingIt` reads
    /// `_testOnly_kernelWindowSize()` directly, so it can assert on the case), and a
    /// future one that did would get a misattributed skip rather than a failure —
    /// worth knowing before adding it. `forceRepaint` never closes the fd, so it can
    /// never be the cause.
    ///
    /// Note the initial 120 read does *not* license a stronger claim later: it proves
    /// only that the master was open, and a child dead since spawn still reads 120
    /// until the EOF is processed asynchronously.
    private func kernelSize(
        of session: PTYSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (rows: UInt16, cols: UInt16) {
        guard case .success(let size) = await session._testOnly_kernelWindowSize() else {
            throw XCTSkip("the PTY's master fd is closed — the child shell died, not a forceRepaint defect",
                          file: file, line: line)
        }
        return size
    }

    /// The PTY's width, or nil if no size could be read at all.
    ///
    /// The polling helpers need "is it 119 yet?" without deciding what a failure
    /// means; the caller re-reads through `kernelSize` to attribute it.
    private func polledCols(of session: PTYSession) async -> UInt16? {
        try? await session._testOnly_kernelWindowSize().get().cols
    }

    /// The outcome of polling for a width, keeping "the PTY went away" distinct
    /// from "the PTY reported a different width".
    ///
    /// Collapsing the two into a plain `UInt16?` made a dead fd read as an
    /// unexpected size, so an environmental failure (the child never spawned, or
    /// exited early) was reported as a `forceRepaint` regression. Attributing
    /// failures correctly is this branch's entire purpose, so the distinction is
    /// carried in the type rather than reconstructed at the assertion.
    private enum ColsOutcome: Equatable {
        case matched
        /// Polling ended with the PTY reporting this width instead.
        case mismatched(UInt16)
        /// No size could be read at all, so there is nothing to compare. Reached
        /// via `polledCols`, which collapses both `WindowSizeFailure` cases: mid-poll
        /// the distinction isn't actionable from inside the loop. Callers treat this
        /// as environmental and `XCTSkip` — they do not re-read to narrow it, because
        /// only `.fdClosed` is reachable here (see `kernelSize`) and it is terminal:
        /// nothing reopens the descriptor, so a second read would return the same
        /// case. Not a statement about `forceRepaint`.
        case ptyUnavailable
    }

    /// Polls the PTY's kernel window size until `cols` is observed or `timeout`
    /// elapses. Returns as soon as `cols` appears, so callers can act while the
    /// wiggle is still mid-flight.
    ///
    /// `Task.sleep` is awaited without `try?` swallowing cancellation: on a
    /// cancelled test the sleep throws immediately and every subsequent sleep
    /// throws too, which turns this loop into a hot spin until its wall-clock
    /// deadline. Rethrowing exits at the first cancellation instead.
    private func waitForCols(
        _ cols: UInt16,
        in session: PTYSession,
        timeout: TimeInterval
    ) async throws -> ColsOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        var last = await polledCols(of: session)
        while Date() < deadline {
            if last == cols { return .matched }
            try await Task.sleep(nanoseconds: 5_000_000)
            last = await polledCols(of: session)
        }
        guard let last else { return .ptyUnavailable }
        return .mismatched(last)
    }

    private enum HoldObservation {
        /// `cols` was seen at least once. `heldFor` spans first to last sighting,
        /// across which *every* sample matched `cols`.
        ///
        /// This is a *sampled* span, not a proof of continuous observability:
        /// polling establishes only that the width matched at each sample, and
        /// says nothing about the gaps between them. It generally understates the
        /// true hold, since the width may have been set before the first sighting
        /// and persisted after the last, and the understatement has no fixed bound —
        /// `Task.sleep` and the cross-actor `await` each guarantee a *minimum*
        /// delay, so a descheduled poller can miss an arbitrary stretch. It is not
        /// a one-directional guarantee, though: both stamps are `Date()` reads taken
        /// *after* the matching size came back, so a restore landing between the last
        /// read and its stamp inflates the span. No bound is claimed on that
        /// overstatement — it is the interval between an ioctl returning and the next
        /// `Date()` read on a descheduled task, which nothing here limits, and an
        /// earlier version of this comment asserting "one poll gap plus scheduling
        /// latency" was stating a bound it had no basis for. In practice it is a
        /// handful of microseconds against a 30 ms floor; the point is that the
        /// assertion is not conservative *by construction*, only in expectation.
        ///
        /// The span is *not* guaranteed to be a single continuous hold, and the
        /// assertion must not be read as proving one. `measureHold` breaks on the
        /// first non-matching sample it *observes*, so a width that departs and
        /// returns entirely within one ~5 ms gap is never seen, and `firstSeen ...
        /// lastSeen` then spans two shorter holds plus the gap between them. An
        /// earlier version of this comment claimed the measured span "can be too
        /// short but never too long"; that does not follow from the premise above,
        /// and the counter-example is exactly the flicker this test guards against.
        ///
        /// What the assertion does establish is weaker and still useful: the width
        /// was observed at `cols` across a span of at least `minimumHold`, with no
        /// contrary observation in between. A regression to a bare same-size
        /// SIGWINCH — the one that actually shipped — never reaches `cols` at all
        /// and fails on `neverObserved`, which is the failure this file exists to
        /// catch. Detecting sub-sample flicker would need the PTY to timestamp its
        /// own `TIOCSWINSZ` calls, which the kernel does not offer.
        case held(heldFor: TimeInterval)
        /// Polling ran to its deadline with the PTY reporting this width instead.
        case neverObserved(lastSeen: UInt16)
        /// No size could be sampled — in practice the master fd is closed, the only
        /// reachable failure (see `kernelSize`). Says nothing about `forceRepaint`,
        /// and callers skip on it rather than re-reading: see
        /// `ColsOutcome.ptyUnavailable`.
        case ptyUnavailable
    }

    /// Polls until `cols` appears, then keeps polling until it goes away, and
    /// reports how long it remained.
    ///
    /// Distinct from `waitForCols`, which returns on first sighting: a single
    /// sighting shows the size changed but not that it stayed long enough for a
    /// process handling WINCH a few ms late to see it. That short-hold mode is
    /// hypothetical — the regression that actually shipped was a bare same-size
    /// SIGWINCH, which changes the width at no point and so fails on
    /// `neverObserved` alone. `minimumHold` guards the adjacent failure a single
    /// observation would miss; its headroom came from mutation testing, not from
    /// a bug seen in the wild.
    ///
    /// Cancellation is rethrown rather than swallowed, for the reason given on
    /// `waitForCols`.
    private func measureHold(
        of cols: UInt16,
        in session: PTYSession,
        timeout: TimeInterval
    ) async throws -> HoldObservation {
        let deadline = Date().addingTimeInterval(timeout)
        var firstSeen: Date?
        var lastSeen: Date?
        var last: UInt16?

        while Date() < deadline {
            last = await polledCols(of: session)
            if last == cols {
                let now = Date()
                if firstSeen == nil { firstSeen = now }
                lastSeen = now
            } else if firstSeen != nil {
                break   // it was held and has now been restored
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        if let first = firstSeen, let final = lastSeen {
            return .held(heldFor: final.timeIntervalSince(first))
        }
        guard let last else { return .ptyUnavailable }
        return .neverObserved(lastSeen: last)
    }

    /// Once the fd is marked closed, reading the size must report `.fdClosed` rather
    /// than issuing the ioctl.
    ///
    /// This is the only test that reaches the `fdClosed` guard: every other read
    /// happens while the PTY is deliberately alive, and the real close happens on a
    /// dispatch queue when the child exits, which no assertion here can schedule.
    /// Deleting the guard therefore left the whole suite green (verified by
    /// mutation) — the lock and its check were entirely uncovered.
    ///
    /// The setup marks the flag *without* closing the descriptor (see
    /// `_testOnly_markMasterFDClosed`), which is what gives the assertion its teeth
    /// rather than weakening it. The fd stays valid, so an unguarded read succeeds and
    /// comes back `.success(120x40)` — a deterministic failure. That is also the real
    /// hazard in miniature: production's danger is an ioctl on a *recycled* fd number
    /// succeeding and returning a plausible size that belongs to another session, and
    /// a read that succeeds when the flag says closed is exactly that bug, with the
    /// recycling made deterministic instead of left to the kernel.
    ///
    /// Hence `.fdClosed` specifically, not merely "no size": `.ioctlFailed` would mean
    /// the guard let the call through and the fd happened to be unusable, which is the
    /// same defect passing for a pass.
    func testWindowSizeReportsClosedFDRatherThanProbingIt() async throws {
        let session = try PTYSession(
            sessionId: UUID(),
            cols: 120,
            rows: 40,
            scrollbackSize: 64 * 1024
        )
        pty = session
        await session.startReading()

        // Live first, so the failure below can only come from the guard.
        let live = try await kernelSize(of: session)
        XCTAssertEqual(live.cols, 120, "PTY did not start at the requested width")

        await session._testOnly_markMasterFDClosed()

        switch await session._testOnly_kernelWindowSize() {
        case .success(let size):
            XCTFail("""
                read a size (\(size.cols)x\(size.rows)) despite the fd being marked closed — the \
                guard is not in force; against a recycled fd this would be another session's PTY
                """)
        case .failure(.fdClosed):
            break   // the guard held
        case .failure(.ioctlFailed(let code)):
            XCTFail("""
                the ioctl was issued instead of short-circuiting, and failed (errno \(code)) — the \
                fd here is still open, so the guard was bypassed and only an unrelated error hid it
                """)
        }
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

        let initial = try await kernelSize(of: session)
        XCTAssertEqual(initial.cols, 120, "PTY did not start at the requested width")

        // Run the wiggle concurrently with polling: the intermediate width (119)
        // is exactly what Node keys its redraw on, and it must be *held* for a
        // sustained window rather than flickering, or a foreground process that
        // handles WINCH a few ms later observes only the restored size and skips
        // the redraw. Measuring the hold (not just sighting it once) is what
        // makes the duration part of the contract enforceable. A regression back
        // to a bare same-size SIGWINCH never changes the kernel winsize at all,
        // so the hold comes back `.neverObserved` and this fails deterministically.
        async let repaint: Void = session.forceRepaint()
        let hold = try await measureHold(of: 119, in: session, timeout: 2.0)
        await repaint

        switch hold {
        case .held(let heldFor):
            XCTAssertGreaterThanOrEqual(
                heldFor,
                Self.minimumHold,
                "the intermediate size flickered (held \(heldFor)s) — a process handling WINCH late sees only the restored size"
            )
        case .neverObserved(let lastSeen):
            XCTFail("""
                the intermediate size was never observable (PTY stayed at \(lastSeen)) \
                — a repaint would be skipped by Node/Ink apps
                """)
        case .ptyUnavailable:
            throw XCTSkip("the PTY's master fd closed during the wiggle — the child shell died, not a forceRepaint defect")
        }

        // And the size must be restored afterwards.
        let restored = try await kernelSize(of: session)
        XCTAssertEqual(restored.cols, 120, "size was not restored after the wiggle")
        XCTAssertEqual(restored.rows, 40, "rows must be untouched by the wiggle")
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
        let midWiggle = try await waitForCols(119, in: session, timeout: 2.0)
        switch midWiggle {
        case .matched:
            break
        case .mismatched(let lastSeen):
            await repaint
            XCTFail("wiggle never started (PTY stayed at \(lastSeen)) — the race below would be vacuous")
            return
        case .ptyUnavailable:
            await repaint
            throw XCTSkip("the PTY's master fd closed before the wiggle was observable — the child shell died")
        }
        await session.resize(cols: 90, rows: 25)
        await repaint

        let final = try await kernelSize(of: session)
        XCTAssertEqual(final.cols, 90, "mid-wiggle resize was stomped by forceRepaint's restore")
        XCTAssertEqual(final.rows, 25, "mid-wiggle resize's ROWS were stomped by a stale restore")
    }
}
