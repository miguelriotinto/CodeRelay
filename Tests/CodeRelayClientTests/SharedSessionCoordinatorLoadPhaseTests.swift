import XCTest
@testable import CodeRelayClient

/// `sessionLoadPhase` is what the loading overlay renders. The coordinator
/// drives it from the replay hooks it installs in `wireTerminalOutput`, and
/// only ever for the ACTIVE session — a background session's replay must not
/// repaint the veil over the one the user is looking at.
@MainActor
final class SharedSessionCoordinatorLoadPhaseTests: XCTestCase {

    private func makeCoordinator() -> SharedSessionCoordinator {
        SharedSessionCoordinator(connection: RelayConnection(), token: "test-token")
    }

    private func installVM(in coordinator: SharedSessionCoordinator, id: UUID) -> TerminalViewModel {
        let vm = TerminalViewModel(sessionId: id, connection: RelayConnection())
        vm.onTerminalOutput = { _ in }
        vm.terminalReady()
        coordinator.terminalViewModels[id] = vm
        coordinator.wireTerminalOutput(to: id)
        return vm
    }

    func testInitialPhaseIsNil() {
        XCTAssertNil(makeCoordinator().sessionLoadPhase)
    }

    func testReplayProgressMovesAttachingToHistoryAndDeliveryClearsIt() {
        let coordinator = makeCoordinator()
        let id = UUID()
        let vm = installVM(in: coordinator, id: id)
        coordinator.activeSessionId = id
        coordinator.sessionLoadPhase = .attaching

        vm.beginReplay()
        vm.receiveOutput(Data(repeating: 0x41, count: 2048))
        XCTAssertEqual(coordinator.sessionLoadPhase, .loadingHistory(bytes: 2048))

        vm.receiveOutput(Data(repeating: 0x41, count: 1024))
        XCTAssertEqual(coordinator.sessionLoadPhase, .loadingHistory(bytes: 3072))

        vm.endReplay()
        XCTAssertNil(coordinator.sessionLoadPhase, "the first visible frame ends the wait")
    }

    func testABackgroundSessionsReplayDoesNotTouchThePhase() {
        let coordinator = makeCoordinator()
        let active = UUID()
        let background = UUID()
        _ = installVM(in: coordinator, id: active)
        let bgVM = installVM(in: coordinator, id: background)
        coordinator.activeSessionId = active
        coordinator.sessionLoadPhase = .attaching

        bgVM.beginReplay()
        bgVM.receiveOutput(Data(repeating: 0x41, count: 512))
        XCTAssertEqual(coordinator.sessionLoadPhase, .attaching)
        bgVM.endReplay()
        XCTAssertEqual(coordinator.sessionLoadPhase, .attaching)
    }

    func testProgressWithoutAPendingPhaseStaysSilent() {
        // A replay the user did not wait for (e.g. a skipReplay switch that still
        // streams a few bytes) must not conjure an overlay out of nothing.
        let coordinator = makeCoordinator()
        let id = UUID()
        let vm = installVM(in: coordinator, id: id)
        coordinator.activeSessionId = id

        vm.beginReplay()
        vm.receiveOutput(Data(repeating: 0x41, count: 512))
        XCTAssertNil(coordinator.sessionLoadPhase)
    }

    func testClearingTheActiveSessionClearsThePhase() {
        let coordinator = makeCoordinator()
        let id = UUID()
        coordinator.activeSessionId = id
        coordinator.sessionLoadPhase = .loadingSessions

        coordinator.activeSessionId = nil
        XCTAssertNil(coordinator.sessionLoadPhase)
    }

    func testReloadFromServerPublishesAttachingThenClearsOnFailure() async {
        // The name-label tap must raise the sheet immediately, and a failed
        // resume (no controller here) must not leave it up.
        let coordinator = makeCoordinator()
        let id = UUID()
        _ = installVM(in: coordinator, id: id)
        coordinator.activeSessionId = id
        var seen: [SessionLoadPhase?] = []
        let sub = coordinator.$sessionLoadPhase.dropFirst().sink { seen.append($0) }
        defer { sub.cancel() }
        await coordinator.reloadTerminalFromServer(id: id)
        XCTAssertEqual(seen.first, .attaching, "sheet up at the tap, not at the first replay byte")
        XCTAssertNil(coordinator.sessionLoadPhase, "a failed reload clears the phase; the pane keeps its text")
    }

    func testSwitchPublishesAttachingEvenWithALiveTerminal() async {
        // A cached SwiftTerm view skips the replay, so nothing used to set the
        // phase: the switch was invisible. The sheet must rise on every switch.
        let coordinator = makeCoordinator()
        let from = UUID(), to = UUID()
        _ = installVM(in: coordinator, id: from)
        _ = installVM(in: coordinator, id: to)
        coordinator.registerLiveTerminal(for: to, view: NSObject())
        coordinator.activeSessionId = from
        var seen: [SessionLoadPhase?] = []
        let sub = coordinator.$sessionLoadPhase.dropFirst().sink { seen.append($0) }
        defer { sub.cancel() }
        await coordinator.switchToSession(id: to)      // no controller: the resume fails and rolls back
        XCTAssertEqual(seen.first, .attaching)
        XCTAssertNil(coordinator.sessionLoadPhase)
    }
}
