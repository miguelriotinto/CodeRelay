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
}
