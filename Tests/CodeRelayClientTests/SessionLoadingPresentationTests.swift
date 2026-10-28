import XCTest
import SwiftUI
@testable import CodeRelayClient

@MainActor
final class SessionLoadingPresentationTests: XCTestCase {
    private func make(_ phase: SessionLoadPhase?, recovering: Bool = false,
                      recovery: SharedSessionCoordinator.RecoveryPhase = .reconnecting) -> SessionLoadingPresentation {
        SessionLoadingPresentation(loadPhase: phase, isRecovering: recovering, recoveryPhase: recovery,
                                   sessionName: "Arya", serverName: "studio")
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
        XCTAssertEqual(make(.attaching).detail, SessionLoadPhase.formatBytes(0),
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
        var release: CheckedContinuation<Void, Never>?
        let model = SessionLoadingSheetModel(sleep: { d in sleeps.append(d); await withCheckedContinuation { release = $0 } })
        model.update(make(.attaching))
        XCTAssertTrue(model.isPresented, "up immediately on the first active presentation")
        model.update(make(nil))                              // loading finished 5 ms later
        XCTAssertTrue(model.isPresented, "held: a 5 ms sheet reads as a flicker")
        await Task.yield(); try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(sleeps, [SessionLoadingSheetModel.minimumVisible])
        release?.resume(); release = nil
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
        model.update(make(nil))
        await Task.yield()
        XCTAssertFalse(model.isPresented, "past the hold, dismissal is immediate")
    }

    func testPresentationClearsOnEveryTerminalPath() {
        // Recovery cancelled, auth rejected, replay never delivered: the inputs go
        // back to nil/false and the presentation must be inactive — the model
        // then dismisses. (Each producer's own tests prove it resets its input.)
        XCTAssertFalse(make(nil, recovering: false).isActive)
    }
}
