import XCTest
@testable import CodeRelayClient

@MainActor
final class SessionLossCollectorTests: XCTestCase {

    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var sleepGates: [CheckedContinuation<Void, Never>] = []
    private var requestedSleeps: [Duration] = []
    private var flushes: [(taken: [SessionLossItem], ended: [SessionLossItem])] = []
    private var collector: SessionLossCollector!

    private let server = UUID()

    override func setUp() async throws {
        collector = SessionLossCollector(
            now: { [unowned self] in self.clock },
            sleep: { [unowned self] duration in
                self.requestedSleeps.append(duration)
                await withCheckedContinuation { self.sleepGates.append($0) }
            })
        collector.onFlush = { [unowned self] taken, ended in self.flushes.append((taken, ended)) }
    }

    private func item(_ name: String, id: UUID = UUID(), server: UUID? = nil) -> SessionLossItem {
        SessionLossItem(serverId: server ?? self.server, serverName: "Mac", session: LostSession(id: id, name: name))
    }

    /// Lets the debounce tasks reach their sleep, then wakes every one of them.
    private func elapseDebounce() async {
        await Task.yield(); await Task.yield()
        let gates = sleepGates; sleepGates.removeAll()
        for gate in gates { gate.resume() }
        for _ in 0..<5 { await Task.yield() }
    }

    func testTwoLiveReportsWithin1sFlushOnce() async {
        let a = item("api"), b = item("web")
        collector.report([a], kind: .taken)
        await Task.yield()
        collector.report([b], kind: .taken)
        await elapseDebounce()
        XCTAssertEqual(flushes.count, 1, "the second report restarts the 1 s debounce")
        XCTAssertEqual(flushes.first?.taken, [a, b])
        XCTAssertEqual(flushes.first?.ended, [])
        XCTAssertTrue(requestedSleeps.allSatisfy { $0 == .seconds(1) })
    }

    func testRepeatWithin120sIsSuppressed() async {
        let id = UUID()
        collector.report([item("api", id: id)], kind: .taken)
        await elapseDebounce()
        XCTAssertEqual(flushes.count, 1)

        clock += 119
        collector.report([item("api", id: id)], kind: .taken)
        collector.report([item("api", id: id)], kind: .ended)
        await elapseDebounce()
        XCTAssertEqual(flushes.count, 1, "a repeat inside 120 s of the announcement is dropped")

        clock += 2   // 121 s after the announcement
        collector.report([item("api", id: id)], kind: .taken)
        await elapseDebounce()
        XCTAssertEqual(flushes.count, 2, "allowed again once the window has passed")
    }

    func testHoldDefersFlushUntilEndHold() async {
        let a = item("api"), b = item("web"), c = item("db")
        collector.beginHold()
        collector.beginHold()                       // nested (start + foreground overlap)
        collector.report([a], kind: .taken)
        collector.report([b], kind: .ended)
        await elapseDebounce()
        XCTAssertTrue(flushes.isEmpty, "nothing flushes while a hold is open")
        collector.endHold()
        await elapseDebounce()
        XCTAssertTrue(flushes.isEmpty, "the inner endHold does not flush")
        collector.report([c], kind: .taken)
        collector.endHold()
        XCTAssertEqual(flushes.count, 1, "the outermost endHold flushes at once")
        XCTAssertEqual(flushes.first?.taken, [a, c])
        XCTAssertEqual(flushes.first?.ended, [b])
        await elapseDebounce()
        XCTAssertEqual(flushes.count, 1, "no stray debounce flush after the hold")
    }

    func testDuplicateInBatchCollapses() async {
        let id = UUID()
        let other = UUID()
        collector.report([item("api", id: id), item("api", id: id)], kind: .taken)
        collector.report([item("api", id: id)], kind: .ended)
        collector.report([item("api", id: id, server: other)], kind: .taken)
        await elapseDebounce()
        XCTAssertEqual(flushes.count, 1)
        XCTAssertEqual(flushes.first?.taken.map(\.session.id), [id, id], "same session id on another server is distinct")
        XCTAssertEqual(flushes.first?.taken.map(\.serverId), [server, other])
        XCTAssertEqual(flushes.first?.ended, [])
    }

    func testResetDropsPendingAndALateEndHoldIsANoOp() async {
        let id = UUID()
        let stale = collector.beginHold()
        collector.report([item("api", id: id)], kind: .taken)
        collector.reset()
        collector.endHold(epoch: stale)                 // the old hold's cap fires late
        XCTAssertFalse(collector.isHolding)
        XCTAssertTrue(flushes.isEmpty, "pending items were dropped, no flush")

        let fresh = collector.beginHold()
        collector.report([item("web")], kind: .taken)
        collector.endHold(epoch: stale)
        XCTAssertTrue(collector.isHolding, "a pre-reset hold cannot close a new one")
        collector.endHold(epoch: fresh)
        XCTAssertEqual(flushes.map { $0.taken.map(\.session.name) }, [["web"]])

        collector.report([item("db")], kind: .taken)
        collector.reset()
        await elapseDebounce()
        XCTAssertEqual(flushes.count, 1, "reset cancels a pending debounce")
    }
}
