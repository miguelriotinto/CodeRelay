import XCTest
@testable import CodeRelayClient

/// The two coordinator-facing replay hooks that drive the session-loading
/// overlay: `onReplayProgress` reports the bytes buffered so far while a replay
/// streams in, and `onReplayDelivered` fires exactly once, the instant the
/// buffered replay is actually handed to the terminal view — the first frame
/// the user can see. Both flush paths must fire it: the normal one in
/// `endReplay()` and the deferred one in `terminalReady()` (macOS race).
@MainActor
final class TerminalViewModelReplayProgressTests: XCTestCase {

    private func makeVM() -> TerminalViewModel {
        TerminalViewModel(sessionId: UUID(), connection: RelayConnection())
    }

    func testProgressReportsCumulativeBytesWhileReplaying() {
        let vm = makeVM()
        var reports: [Int] = []
        vm.onReplayProgress = { reports.append($0) }
        vm.onTerminalOutput = { _ in }
        vm.terminalReady()
        vm.beginReplay()

        vm.receiveOutput(Data(repeating: 0x41, count: 100))
        vm.receiveOutput(Data(repeating: 0x42, count: 250))

        XCTAssertEqual(reports, [100, 350])
    }

    func testProgressIsSilentOutsideAReplay() {
        let vm = makeVM()
        var reports: [Int] = []
        vm.onReplayProgress = { reports.append($0) }
        vm.onTerminalOutput = { _ in }
        vm.terminalReady()

        vm.receiveOutput(Data(repeating: 0x41, count: 100))

        XCTAssertTrue(reports.isEmpty, "live output is not replay progress")
    }

    func testDeliveredFiresOnceWhenEndReplayFlushes() {
        let vm = makeVM()
        var delivered = 0
        var flushedBytes = 0
        vm.onReplayDelivered = { delivered += 1 }
        vm.onTerminalOutput = { flushedBytes += $0.count }
        vm.terminalReady()
        vm.beginReplay()
        vm.receiveOutput(Data(repeating: 0x41, count: 64))

        XCTAssertEqual(delivered, 0, "nothing is visible until the flush")
        vm.endReplay()
        XCTAssertEqual(delivered, 1)
        XCTAssertGreaterThanOrEqual(flushedBytes, 64)

        vm.endReplay()
        XCTAssertEqual(delivered, 1, "a second endReplay is a no-op")
    }

    func testDeliveredFiresOnceOnTheDeferredFlush() {
        let vm = makeVM()
        var delivered = 0
        vm.onReplayDelivered = { delivered += 1 }
        vm.onTerminalOutput = { _ in }
        vm.beginReplay()
        vm.receiveOutput(Data(repeating: 0x41, count: 64))

        // replay_complete beats layout: the flush is deferred to terminalReady.
        vm.endReplay()
        XCTAssertEqual(delivered, 0)
        vm.terminalReady()
        XCTAssertEqual(delivered, 1)
    }

    func testDeliveredNeverFiresWithoutAReplay() {
        let vm = makeVM()
        var delivered = 0
        vm.onReplayDelivered = { delivered += 1 }
        vm.onTerminalOutput = { _ in }
        vm.receiveOutput(Data(repeating: 0x41, count: 64))
        vm.terminalReady()
        vm.endReplay()
        XCTAssertEqual(delivered, 0)
    }
}
