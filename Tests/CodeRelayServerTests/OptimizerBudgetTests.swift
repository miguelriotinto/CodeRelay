import XCTest
@testable import CodeRelayServer

/// The cost bound on the paid model call (review B-3).
final class OptimizerBudgetTests: XCTestCase {

    func testTheShippedBoundIsTwentyPerMinute() {
        XCTAssertEqual(RelayMessageHandler.maxOptimizesPerMinutePerToken, 20)
        XCTAssertEqual(OptimizerBudget.defaultMaxPerWindow, 20)
    }

    /// The whole point: the Nth call inside the window is allowed and the
    /// N+1th is not.
    func testTwentyAreAllowedAndTheTwentyFirstIsRefused() {
        let budget = OptimizerBudget()
        for i in 1...RelayMessageHandler.maxOptimizesPerMinutePerToken {
            XCTAssertTrue(budget.allow(tokenId: "token-a"), "call \(i) is inside the budget")
        }
        XCTAssertFalse(budget.allow(tokenId: "token-a"), "the 21st call in the window is refused")
    }

    /// The bound is per token: one device burning its budget must not disable
    /// the wand for every other device the operator issued a token to.
    func testTheBudgetIsPerToken() {
        let budget = OptimizerBudget(maxPerWindow: 2)
        XCTAssertTrue(budget.allow(tokenId: "token-a"))
        XCTAssertTrue(budget.allow(tokenId: "token-a"))
        XCTAssertFalse(budget.allow(tokenId: "token-a"))
        XCTAssertTrue(budget.allow(tokenId: "token-b"), "a different token has its own window")
    }

    /// A refused call charges nothing, so a client that retries in a tight loop
    /// cannot drag its own window forward and stay blocked forever — it is
    /// allowed again exactly `windowSeconds` after its *first* charged call.
    func testTheWindowSlidesAndARefusalChargesNothing() async {
        let budget = OptimizerBudget(maxPerWindow: 2, windowSeconds: 0.4)
        XCTAssertTrue(budget.allow(tokenId: "token-a"))
        XCTAssertTrue(budget.allow(tokenId: "token-a"))
        XCTAssertFalse(budget.allow(tokenId: "token-a"))
        // Retry storm while refused: none of these may extend the window.
        for _ in 0..<10 { XCTAssertFalse(budget.allow(tokenId: "token-a")) }

        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(budget.allow(tokenId: "token-a"),
                      "the two charged calls have aged out of the window")
    }

    /// Same LRU discipline as `RateLimiter.maxTrackedIPs`: the map is bounded,
    /// with 10% headroom so the sort amortizes instead of firing on every call.
    func testTrackedTokensAreLRUCapped() {
        let budget = OptimizerBudget(maxPerWindow: 5, windowSeconds: 600, maxTrackedTokens: 10)
        for i in 0..<200 { XCTAssertTrue(budget.allow(tokenId: "token-\(i)")) }
        XCTAssertLessThanOrEqual(budget._testOnly_trackedTokenCount, 11,
                                 "tracked tokens must stay within the cap plus its eviction headroom")
        XCTAssertGreaterThan(budget._testOnly_trackedTokenCount, 0)
    }

    /// The budget is shared across connections, so `allow` is called from
    /// several event loops at once. It is lock-guarded, not an actor — this is
    /// the test that says so.
    func testConcurrentCallsAreSerializedAndExact() async {
        let budget = OptimizerBudget(maxPerWindow: 50, windowSeconds: 600)
        let allowed = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<200 {
                group.addTask { budget.allow(tokenId: "token-a") }
            }
            var count = 0
            for await ok in group where ok { count += 1 }
            return count
        }
        XCTAssertEqual(allowed, 50, "exactly the budget is granted, no matter the interleaving")
    }
}
