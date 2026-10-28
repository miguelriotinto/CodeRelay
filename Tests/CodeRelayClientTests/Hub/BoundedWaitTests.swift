import XCTest
@testable import CodeRelayClient

@MainActor
final class BoundedWaitTests: XCTestCase {
    func testOperationFinishingFirstReturnsWithoutWaitingForTheBudget() async {
        let started = ContinuousClock.now
        var ran = false
        await BoundedWait.run(budget: .seconds(5)) { ran = true }
        XCTAssertTrue(ran)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    }

    func testTimerFiringFirstReturnsAtTheBudgetAndALateFinishIsHarmless() async {
        var gate: CheckedContinuation<Void, Never>?
        var finished = false
        let started = ContinuousClock.now
        await BoundedWait.run(budget: .milliseconds(100)) {
            await withCheckedContinuation { gate = $0 }
            finished = true
        }
        let elapsed = ContinuousClock.now - started
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(90))
        XCTAssertLessThan(elapsed, .seconds(2))
        XCTAssertFalse(finished, "returned on the budget, not on the operation")
        gate?.resume()                                       // the straggler completes later, nobody listens
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(finished)
    }
}
