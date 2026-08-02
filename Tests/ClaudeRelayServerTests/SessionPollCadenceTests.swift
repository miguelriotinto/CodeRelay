import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

/// Foreground-process poll cadence: 1 s while attached, 5 s once detached.
///
/// Split out of `SessionLifecycleTests` to keep both files under SwiftLint's
/// 500-line ceiling.
final class SessionPollCadenceTests: SessionManagerTestCase {

    /// Regression: `resumeSession` reached `.activeAttached` without restoring
    /// the fast poll, so a session kept polling the foreground process at 5 s.
    /// Same-device tab switches detach-then-resume, so this was the common path
    /// — a switched-to session took up to 5 s to notice agent entry/exit.
    func testResumeRestoresAttachedPollCadence() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        let (_, ptyAny) = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id)
        let pty = try XCTUnwrap(ptyAny as? MockPTYSession)

        try await manager.detachSession(id: session.id)
        try await waitForPollCadence(PTYSession.detachedPollCadence, on: pty)

        _ = try await manager.resumeSession(id: session.id, tokenId: tokenInfo.id)
        try await waitForPollCadence(PTYSession.attachedPollCadence, on: pty)
    }

    /// A tab switch is detach + resume. Repeating it must not leave the session
    /// stuck on the slow cadence.
    func testRepeatedTabSwitchKeepsFastCadence() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        let (_, ptyAny) = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id)
        let pty = try XCTUnwrap(ptyAny as? MockPTYSession)

        for _ in 0..<3 {
            try await manager.detachSession(id: session.id)
            try await waitForPollCadence(PTYSession.detachedPollCadence, on: pty)
            _ = try await manager.resumeSession(id: session.id, tokenId: tokenInfo.id)
            try await waitForPollCadence(PTYSession.attachedPollCadence, on: pty)
        }
    }

    /// A rapid detach→resume must end on the fast cadence — the bug this PR fixes.
    ///
    /// Scope: a **mutation** test, not a concurrency test. Now that the cadence
    /// writes are awaited these calls are fully sequential, so the assertion is
    /// deterministic; its value is that reverting to fire-and-forget `Task`s
    /// makes it fail (measured 50/50 iterations, detach's 5 s landing after
    /// resume's 1 s). Reentrancy is covered by
    /// `testDetachTimerIsInstalledBeforeCadenceSuspension` instead.
    ///
    /// The mirror case (…→detach must end *slow*) is deliberately absent: it was
    /// mutation-tested and still passed with `resumeSession`'s cadence restore
    /// deleted, because the trailing detach writes the slow cadence either way.
    /// A test that cannot fail for the bug it names is worse than no test.
    func testRapidDetachResumeEndsOnFastCadence() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        let (_, ptyAny) = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id)
        let pty = try XCTUnwrap(ptyAny as? MockPTYSession)

        for iteration in 0..<50 {
            try await manager.detachSession(id: session.id)
            _ = try await manager.resumeSession(id: session.id, tokenId: tokenInfo.id)

            let cadence = await pty.lastPollCadence
            XCTAssertEqual(
                cadence,
                PTYSession.attachedPollCadence,
                "Iteration \(iteration): resumed session must end on the fast cadence, got \(cadence.map { "\($0)" } ?? "none")"
            )
        }
    }

    /// Deterministic reentrancy check: a `detachSession` suspended in the PTY
    /// cadence write must not corrupt a `resumeSession` that overtakes it.
    ///
    /// `SessionManager` is a **reentrant** actor: every `await` inside a
    /// lifecycle method is a point where another task can enter and run to
    /// completion. `setPollCadence` is a cross-actor call, so it is such a point.
    /// The gate pins `detachSession` there on every run, instead of hoping a
    /// sleep lands in the right window, and asserts two independent invariants:
    ///
    /// 1. **Cadence.** The session ends attached, so it must poll at 1 s. The
    ///    suspended detach captured 5 s before suspending; if it wrote that value
    ///    on resumption the attached session would poll slowly — the exact bug
    ///    this change set out to fix, one level down.
    /// 2. **Timer.** No detach-expiry timer may remain. `detachSession` installs
    ///    the timer *above* the suspension point, so the reentrant resume can see
    ///    and cancel it; installed below, it would be armed against a session
    ///    that is once again `.activeAttached`.
    func testDetachTimerIsInstalledBeforeCadenceSuspension() async throws {
        let (_, tokenInfo) = try await createTestToken()
        // detachTimeout must be > 0 for a timer to be installed at all.
        var config = RelayConfig.default
        config.detachTimeout = 60
        config.scrollbackSize = 4096
        let manager = makeManager(config: config)

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        let (_, ptyAny) = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id)
        let pty = try XCTUnwrap(ptyAny as? MockPTYSession)

        // Hold the next setPollCadence open, then start the detach.
        let gate = AsyncGate()
        await pty.installPollCadenceGate(gate)
        let detach = Task { try await manager.detachSession(id: session.id) }

        // Wait until detachSession is genuinely parked in the gate, so the
        // reentrant resume below is guaranteed to interleave. Polled with a
        // deadline rather than awaiting a continuation: if the detach ever
        // failed before reaching the gate, a continuation would hang this test
        // forever, and an XCTFail is strictly more useful than a stuck suite.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !gate.hasArrived {
            guard ContinuousClock.now < deadline else {
                XCTFail("detachSession never reached setPollCadence — the gate was not exercised")
                detach.cancel()
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }

        // Reentrant resume while detachSession is suspended. It must observe a
        // fully committed .activeDetached — including the timer it needs to cancel.
        await pty.removePollCadenceGate()
        let (resumed, _, _) = try await manager.resumeSession(id: session.id, tokenId: tokenInfo.id)
        XCTAssertEqual(resumed.state, .activeAttached)

        await gate.open()
        try await detach.value

        // The whole point of the change: an attached session polls fast. This is
        // the assertion the first version of this test was missing — it checked
        // only state and timers, so it passed while `detachSession` resumed from
        // the gate and wrote its stale 5 s *after* the resume's 1 s, leaving an
        // attached session on the slow cadence. Ordering statements could not fix
        // that (the race is between the two PTY writes, not the two methods);
        // `SessionManager.syncPollCadence` does, by re-reading the cadence from
        // committed state after every suspension instead of capturing it once.
        // Verified load-bearing: replacing that read with a captured constant
        // fails this assertion 5.0 vs 1.0.
        let cadence = await pty.lastPollCadence
        XCTAssertEqual(
            cadence,
            PTYSession.attachedPollCadence,
            "An attached session must end on the fast cadence, got \(cadence.map { "\($0)" } ?? "none")"
        )

        // Pin the *mechanism*, not just the outcome. The reentrant resume found a
        // sync loop already in flight, so by design it wrote nothing at all — it
        // relies entirely on the suspended owner re-reading state and repairing.
        // So after the initial attach's 1 s (setup, above), the tail must be the
        // detach's 5 s followed by the owner's own corrective 1 s on its next
        // pass. If that tail were just [5.0], the repair pass never ran and the
        // cadence assertion above passed by luck.
        //
        // Note what this does NOT cover. `syncPollCadence` once bounded the loop at
        // 8 passes, which stranded a stale cadence when a transition committed
        // during the final write. This test drives only two passes, so it cannot
        // tell `while true` from any cap >= 2 (measured: cap 1 fails it, cap 2 and
        // cap 8 pass). That removal is guarded by
        // `testSyncLoopTakesAsManyPassesAsThereAreTransitions` instead.
        let writes = await pty.pollCadences
        XCTAssertEqual(
            writes.suffix(2),
            [PTYSession.detachedPollCadence, PTYSession.attachedPollCadence],
            "Expected the owner to write 5 s then repair to 1 s on a re-read pass, got \(writes)"
        )

        // The session is attached, so no detach-expiry timer may remain: the
        // resume cancelled the one detach installed, and detach installed it
        // before suspending rather than after.
        let timers = await manager.detachTimerSessionIds
        XCTAssertFalse(
            timers.contains(session.id),
            "An attached session must not have a detach-expiry timer; " +
            "detachSession installed one after its suspension point"
        )
        let info = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(info.state, .activeAttached, "The reentrant resume must win — it ran last")
    }

    /// The sync loop must take as many repair passes as there are transitions —
    /// which is what makes removing its pass cap observable.
    ///
    /// Why this exists: the cap was removed because a transition committing during
    /// the final permitted write returned early on the single-flight guard, after
    /// which the owner finished its stale write and exhausted the loop without
    /// re-reading — stranding a cadence that disagreed with committed state. But
    /// `testDetachTimerIsInstalledBeforeCadenceSuspension` only ever drives **two**
    /// passes, so it cannot tell `while true` from any cap >= 2. Measured: with a
    /// cap of 1 it fails, with a cap of 2 or 8 — the exact cap that was removed —
    /// it passes. Without this test the cap removal was unguarded, and the comments
    /// claiming otherwise were the kind of unverified assertion this branch has
    /// repeatedly had to correct.
    ///
    /// So: flip the state on every write via the mock's write hook, forcing more
    /// passes than the removed cap allowed. Any finite cap below that count leaves
    /// the PTY holding a value that contradicts committed state — exactly the
    /// stranding the cap caused. Measured against this test: caps of 2, 3 and 8 all
    /// fail it. Under cap 8 the loop stops after 9 writes with the PTY on 1 s while
    /// the session has committed `.activeDetached` — which direction the strand
    /// points depends only on which transition the cap happened to cut off.
    func testSyncLoopTakesAsManyPassesAsThereAreTransitions() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        let (_, ptyAny) = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id)
        let pty = try XCTUnwrap(ptyAny as? MockPTYSession)

        // Flip the committed state from inside each write, so every pass finds a
        // different desired cadence and must write again. Detach/resume are the
        // real transitions, so this exercises the production paths, not a stub.
        // These calls hit the single-flight guard and return without writing —
        // the owner's re-read is the only thing that applies them.
        // Comfortably above the 8-pass cap that was removed, so this test can
        // distinguish `while true` from that cap and not merely from a tiny one.
        let targetPasses = 12
        let sessionId = session.id
        let tokenId = tokenInfo.id
        await pty.setPollCadenceWriteHook { [weak manager] writeCount in
            guard let manager, writeCount < targetPasses else { return }
            if writeCount.isMultiple(of: 2) {
                _ = try? await manager.resumeSession(id: sessionId, tokenId: tokenId)
            } else {
                try? await manager.detachSession(id: sessionId)
            }
        }

        // Kick the loop. The hook drives it well past any cap that was ever used.
        try await manager.detachSession(id: session.id)
        await pty.removePollCadenceWriteHook()

        let writes = await pty.pollCadences
        XCTAssertGreaterThan(
            writes.count, 3,
            "Expected the loop to keep re-reading and repairing; got only \(writes.count) writes: \(writes)"
        )

        // The invariant that matters, whatever the pass count: the PTY ends
        // holding the cadence the last committed transition implies.
        let finalState = try await manager.inspectSession(id: session.id).state
        let expected = finalState == .activeAttached
            ? PTYSession.attachedPollCadence
            : PTYSession.detachedPollCadence
        let finalCadence = await pty.lastPollCadence
        XCTAssertEqual(
            finalCadence, expected,
            "Session ended \(finalState) after \(writes.count) writes \(writes), so the PTY must hold \(expected)"
        )
    }

    /// Polls rather than reading once. The cadence updates are awaited, so the
    /// value is already in place when the transition returns — but polling keeps
    /// this helper correct if a caller ever dispatches one asynchronously again,
    /// and costs nothing on the happy path (first check succeeds).
    private func waitForPollCadence(
        _ expected: TimeInterval,
        on pty: MockPTYSession,
        timeout: Duration = .milliseconds(500),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await pty.lastPollCadence == expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let actual = await pty.lastPollCadence
        let actualDescription = actual.map { "\($0) s" } ?? "none"
        XCTFail(
            "Expected poll cadence \(expected) s, got \(actualDescription)",
            file: file,
            line: line
        )
    }
}
