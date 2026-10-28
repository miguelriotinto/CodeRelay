import XCTest
import SwiftUI
@testable import CodeRelayClient

@MainActor
final class SessionLoadingPresentationTests: XCTestCase {
    private func make(_ phase: SessionLoadPhase?, recovering: Bool = false,
                      recovery: SharedSessionCoordinator.RecoveryPhase = .reconnecting,
                      expectsSession: Bool = true,
                      sessionAttached: Bool = true, failed: Bool = false,
                      recoveryFailed: Bool = false) -> SessionLoadingPresentation {
        SessionLoadingPresentation(loadPhase: phase, isRecovering: recovering, recoveryPhase: recovery,
                                   expectsSession: expectsSession, sessionAttached: sessionAttached,
                                   loadFailed: failed, recoveryFailed: recoveryFailed,
                                   sessionName: "Arya", serverName: "studio")
    }

    /// Scripted sleeps: each call parks until the test releases it, in order.
    @MainActor
    final class Sleeper {
        private(set) var parked: [(Duration, CheckedContinuation<Void, Never>)] = []
        var durations: [Duration] { parked.map(\.0) }
        func sleep(_ d: Duration) async { await withCheckedContinuation { parked.append((d, $0)) } }
        func release(_ d: Duration) {
            guard let i = parked.firstIndex(where: { $0.0 == d }) else { return }
            parked.remove(at: i).1.resume()
        }
    }

    private func settle() async { await Task.yield(); try? await Task.sleep(for: .milliseconds(10)) }

    // MARK: - Ready (user request: "show 0 KB, then the bytes, then Ready for 0.6 s")

    func testAFullySyncedSessionShowsZeroThenReadyThenDismisses() async {
        // A cached-terminal switch (or a session already in sync) streams no
        // bytes: the counter used to sit at "0 KB" and the sheet just vanished.
        let sleeper = Sleeper()
        let model = SessionLoadingSheetModel(sleep: { await sleeper.sleep($0) })
        model.update(make(.attaching))
        XCTAssertEqual(model.shown?.detail, "0 KB")
        XCTAssertFalse(model.shown?.isReady ?? true)
        model.update(make(nil))                                  // loaded, session attached, no error
        XCTAssertTrue(model.isPresented, "still up: Ready is shown before the sheet goes")
        XCTAssertEqual(model.shown?.isReady, true)
        XCTAssertEqual(model.shown?.status, "Ready")
        XCTAssertEqual(model.shown?.detail, "0 KB", "nothing streamed: 0 KB, then Ready")
        await settle()
        XCTAssertTrue(sleeper.durations.contains(SessionLoadingSheetModel.readyDwell))
        sleeper.release(SessionLoadingSheetModel.minimumVisible)
        await settle()
        XCTAssertTrue(model.isPresented, "Ready holds for its own dwell, not the minimum hold")
        sleeper.release(SessionLoadingSheetModel.readyDwell)
        await settle()
        XCTAssertFalse(model.isPresented, "dismissed after Ready")
    }

    func testReadyKeepsTheFinalByteCount() {
        let model = SessionLoadingSheetModel(sleep: { _ in await withCheckedContinuation { _ in } })
        model.update(make(.attaching))
        model.update(make(.loadingHistory(bytes: 212_000)))
        model.update(make(nil))
        XCTAssertEqual(model.shown?.isReady, true)
        XCTAssertEqual(model.shown?.detail, SessionLoadPhase.formatBytes(212_000), "Ready next to the bytes that synced")
        XCTAssertFalse(model.shown?.allowsCancel ?? true)
    }

    func testAFailedLoadNeverSaysReady() {
        let model = SessionLoadingSheetModel(sleep: { _ in await withCheckedContinuation { _ in } })
        model.update(make(.attaching))
        model.update(make(nil, failed: true))
        XCTAssertNotEqual(model.shown?.isReady, true, "an error alert follows; Ready would be a lie")
        model.update(make(.attaching))
        model.update(make(nil, sessionAttached: false))
        XCTAssertNotEqual(model.shown?.isReady, true, "nothing attached (e.g. a handshake that gave up)")
    }

    func testACancelledReconnectNeverSaysReady() {
        let model = SessionLoadingSheetModel(sleep: { _ in await withCheckedContinuation { _ in } })
        model.update(make(nil, recovering: true))
        model.update(make(nil, recovering: false, recoveryFailed: true))
        XCTAssertNotEqual(model.shown?.isReady, true)
        // A successful reconnect does.
        let ok = SessionLoadingSheetModel(sleep: { _ in await withCheckedContinuation { _ in } })
        ok.update(make(nil, recovering: true))
        ok.update(make(nil))
        XCTAssertEqual(ok.shown?.isReady, true)
    }

    func testANewLoadDuringReadyTakesOver() async {
        let sleeper = Sleeper()
        let model = SessionLoadingSheetModel(sleep: { await sleeper.sleep($0) })
        model.update(make(.attaching))
        model.update(make(nil))                                  // Ready
        XCTAssertEqual(model.shown?.isReady, true)
        model.update(make(.attaching))                           // the user tapped another tab
        XCTAssertEqual(model.shown?.isReady, false)
        await settle()
        sleeper.release(SessionLoadingSheetModel.readyDwell)
        await settle()
        XCTAssertTrue(model.isPresented, "the earlier Ready's dwell must not dismiss the new load")
    }

    func testHandshakePhasesDoNotRaiseTheSheetWithoutASessionToShow() {
        // The launch/wake handshake publishes connecting/authenticating/
        // loadingSessions only while no session is attached. With nothing to
        // restore there is no session loading — the old overlay never showed
        // these, and a modal here sat for ~54 s against an unreachable host.
        for phase in [SessionLoadPhase.connecting, .authenticating, .loadingSessions] {
            XCTAssertFalse(make(phase, expectsSession: false).isActive, "\(phase) with no session expected")
            XCTAssertTrue(make(phase, expectsSession: true).isActive, "\(phase) while a restore is pending")
        }
        XCTAssertTrue(make(.attaching, expectsSession: false).isActive, "a switch always shows")
        XCTAssertTrue(make(nil, recovering: true, expectsSession: false).isActive, "recovery always shows (it has Cancel)")
    }

    func testDetailReadsZeroKBBeforeHistoryStreams() {
        XCTAssertEqual(make(.attaching).detail, "0 KB")
        XCTAssertEqual(make(nil, recovering: true).detail, "0 KB")
        XCTAssertEqual(make(.loadingHistory(bytes: 2048)).detail, "2 KB")
    }

    func testSheetDismissesAfterAStallEvenWhileLoadingAndReturnsOnProgress() async {
        // Review Focus 0: a replay that never delivers must not pin the sheet
        // (and the blackout) until recovery notices ~30 s later.
        var gates: [Duration: CheckedContinuation<Void, Never>] = [:]
        let model = SessionLoadingSheetModel(sleep: { d in await withCheckedContinuation { gates[d] = $0 } })
        model.update(make(.loadingHistory(bytes: 1024)))
        XCTAssertTrue(model.isPresented)
        await Task.yield(); try? await Task.sleep(for: .milliseconds(10))
        gates[SessionLoadingSheetModel.minimumVisible]?.resume()
        gates[SessionLoadingSheetModel.stallTimeout]?.resume()          // 15 s with no change
        await Task.yield(); try? await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(model.isPresented, "stalled: the sheet lowers so the pane is usable")
        model.update(make(.loadingHistory(bytes: 4096)))                 // bytes moved again
        XCTAssertTrue(model.isPresented, "progress resumed: the sheet comes back")
    }

    func testInactiveWhenNothingLoads() {
        XCTAssertFalse(make(nil).isActive)
    }

    func testLoadPhasesDriveTitleStatusAndBytes() {
        let p = make(.loadingHistory(bytes: 212_000))
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.title, "Loading session")
        XCTAssertEqual(p.status, "Loading session history…")
        XCTAssertEqual(p.detail, SessionLoadPhase.formatBytes(212_000))
        XCTAssertEqual(p.subtitle, "Arya · studio")
        XCTAssertFalse(p.allowsCancel)
        XCTAssertEqual(make(.authenticating).status, "Authenticating…")
        XCTAssertEqual(make(.attaching).detail, "0 KB",
                       "the counter slot is reserved from the first phase so the layout never jumps")
        XCTAssertNil(make(nil).detail)
    }

    func testBytesAreTheLargestTextOnTheSheet() {
        // The counter is the one line that proves progress is real; it must not
        // be a caption under the status.
        XCTAssertEqual(SessionLoadingSheet.bytesFont, .title2.monospacedDigit().weight(.semibold))
        XCTAssertEqual(SessionLoadingSheet.statusFont, .subheadline)
    }

    func testRecoveryWinsTheTitleAndOffersCancel() {
        let p = make(nil, recovering: true, recovery: .authenticating)
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.title, "Reconnecting")
        XCTAssertEqual(p.status, "Authenticating…")
        XCTAssertTrue(p.allowsCancel)
        // Recovery then resumes the session: the replay phase takes over the status line.
        XCTAssertEqual(make(.loadingHistory(bytes: 10), recovering: true, recovery: .resuming).status, "Loading session history…")
    }

    func testSheetHoldsAMinimumEvenWhenLoadingIsInstant() async {
        var sleeps: [Duration] = []
        var holdRelease: CheckedContinuation<Void, Never>?
        let model = SessionLoadingSheetModel(sleep: { d in
            sleeps.append(d)
            await withCheckedContinuation { c in
                if d == SessionLoadingSheetModel.minimumVisible { holdRelease = c } else { c.resume() }
            }
        })
        model.update(make(.attaching))
        XCTAssertTrue(model.isPresented, "up immediately on the first active presentation")
        model.update(make(nil, failed: true))                // failed 5 ms later (no Ready on failure)
        XCTAssertTrue(model.isPresented, "held: a 5 ms sheet reads as a flicker")
        await Task.yield(); try? await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(sleeps.contains(SessionLoadingSheetModel.minimumVisible))
        holdRelease?.resume(); holdRelease = nil
        await Task.yield(); try? await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(model.isPresented, "dismissed once the hold elapsed and nothing is loading")
        XCTAssertEqual(model.shown?.status, "Attaching to session…", "the text stays while the sheet animates down")
    }

    func testSheetStaysWhileLoadingOutlivesTheHold() async {
        var release: CheckedContinuation<Void, Never>?
        let model = SessionLoadingSheetModel(sleep: { _ in await withCheckedContinuation { release = $0 } })
        model.update(make(.attaching))
        await Task.yield(); try? await Task.sleep(for: .milliseconds(10))
        release?.resume(); release = nil
        await Task.yield(); try? await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(model.isPresented, "the hold elapsed but the load is still running")
        model.update(make(.loadingHistory(bytes: 4096)))
        XCTAssertEqual(model.shown?.detail, SessionLoadPhase.formatBytes(4096))
        model.update(make(nil, failed: true))
        await Task.yield()
        XCTAssertFalse(model.isPresented, "past the hold, a failed load dismisses immediately")
    }

}
