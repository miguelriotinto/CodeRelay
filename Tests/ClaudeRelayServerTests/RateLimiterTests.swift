import XCTest
@testable import ClaudeRelayServer

final class RateLimiterTests: XCTestCase {

    func testAllowsUnderThreshold() async {
        let limiter = RateLimiter(maxAttempts: 3, windowSeconds: 60)
        let blocked1 = await limiter.recordFailure(ip: "1.2.3.4")
        XCTAssertFalse(blocked1, "Should not block after 1 failure")
        let blocked2 = await limiter.recordFailure(ip: "1.2.3.4")
        XCTAssertFalse(blocked2, "Should not block after 2 failures")
    }

    func testBlocksAtThreshold() async {
        let limiter = RateLimiter(maxAttempts: 3, windowSeconds: 60)
        await limiter.recordFailure(ip: "1.2.3.4")
        await limiter.recordFailure(ip: "1.2.3.4")
        let blocked = await limiter.recordFailure(ip: "1.2.3.4")
        XCTAssertTrue(blocked, "Should block at threshold")
    }

    func testIsBlockedReturnsTrueWhenBlocked() async {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 60)
        await limiter.recordFailure(ip: "10.0.0.1")
        await limiter.recordFailure(ip: "10.0.0.1")
        let blocked = await limiter.isBlocked(ip: "10.0.0.1")
        XCTAssertTrue(blocked)
    }

    func testIsBlockedReturnsFalseForUnknownIP() async {
        let limiter = RateLimiter(maxAttempts: 5, windowSeconds: 60)
        let blocked = await limiter.isBlocked(ip: "unknown")
        XCTAssertFalse(blocked)
    }

    func testResetClearsBlocking() async {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 60)
        await limiter.recordFailure(ip: "5.5.5.5")
        await limiter.recordFailure(ip: "5.5.5.5")
        let blockedBefore = await limiter.isBlocked(ip: "5.5.5.5")
        XCTAssertTrue(blockedBefore)

        await limiter.reset(ip: "5.5.5.5")
        let blockedAfter = await limiter.isBlocked(ip: "5.5.5.5")
        XCTAssertFalse(blockedAfter)
    }

    func testDifferentIPsAreIndependent() async {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 60)
        await limiter.recordFailure(ip: "A")
        await limiter.recordFailure(ip: "A")
        let blockedA = await limiter.isBlocked(ip: "A")
        let blockedB = await limiter.isBlocked(ip: "B")
        XCTAssertTrue(blockedA)
        XCTAssertFalse(blockedB)
    }

    func testWindowExpiry() async {
        // Use a 0-second window so entries expire immediately
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 0)
        await limiter.recordFailure(ip: "X")
        await limiter.recordFailure(ip: "X")
        // After cleanup (triggered by isBlocked), entries should be expired
        let blocked = await limiter.isBlocked(ip: "X")
        XCTAssertFalse(blocked, "Should not be blocked after window expires")
    }

    func testRateLimiterEvictsLRUEntries() async {
        // maxTrackedIPs=10 triggers eviction only above 11 (10 + 10/10 headroom).
        // Add 25 unique IPs and confirm the total is bounded well below 25.
        let limiter = RateLimiter(maxAttempts: 5, windowSeconds: 600, maxTrackedIPs: 10)

        for i in 0..<25 {
            await limiter.recordFailure(ip: "10.0.0.\(i)")
        }
        let count = await limiter._testOnly_trackedIPCount
        // We allow some slack because eviction only runs after crossing 11;
        // the count will hover in the 12-20 range depending on how the
        // amortization unfolds, but must never approach 25.
        XCTAssertLessThanOrEqual(count, 20, "LRU cap should keep the map well below the unlimited case")
        XCTAssertGreaterThanOrEqual(count, 10, "Should retain at least the configured capacity")

        // Most recent entry should still be tracked but not blocked (1 failure < 5 threshold).
        let blockedRecent = await limiter.isBlocked(ip: "10.0.0.24")
        XCTAssertFalse(blockedRecent, "Recent IP with single failure should not be blocked")
    }

    /// Regression test for the real-world "window expires" path, not just the
    /// 0-second degenerate case. Uses a 1-second window and waits past it to
    /// verify an IP becomes unblocked once its failure entries age out.
    func testIPUnblocksAfterWindowElapses() async {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 1, maxTrackedIPs: 100)
        await limiter.recordFailure(ip: "9.9.9.9")
        await limiter.recordFailure(ip: "9.9.9.9")
        let blockedInitially = await limiter.isBlocked(ip: "9.9.9.9")
        XCTAssertTrue(blockedInitially)

        try? await Task.sleep(for: .milliseconds(1100))
        let blockedAfterWait = await limiter.isBlocked(ip: "9.9.9.9")
        XCTAssertFalse(blockedAfterWait,
                       "IP should be released once the failure window has elapsed")
    }

    // MARK: - Concurrency

    func testConcurrentRecordFailuresNoCrash() async {
        let limiter = RateLimiter(maxAttempts: 100, windowSeconds: 60, maxTrackedIPs: 1000)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    _ = await limiter.recordFailure(ip: "192.168.1.\(i % 20)")
                }
            }
        }

        let count = await limiter._testOnly_trackedIPCount
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThanOrEqual(count, 20)
    }

    func testConcurrentRecordAndCheckSameIP() async {
        let limiter = RateLimiter(maxAttempts: 5, windowSeconds: 60)
        let ip = "10.10.10.10"

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await limiter.recordFailure(ip: ip)
                }
            }
            for _ in 0..<10 {
                group.addTask {
                    await limiter.isBlocked(ip: ip)
                }
            }
            // All operations must complete without crash or data race
            for await _ in group {}
        }

        let blocked = await limiter.isBlocked(ip: ip)
        XCTAssertTrue(blocked, "10 failures > threshold of 5 should block")
    }

    func testResetDuringConcurrentChecks() async {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 60)
        await limiter.recordFailure(ip: "5.5.5.5")
        await limiter.recordFailure(ip: "5.5.5.5")

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await limiter.reset(ip: "5.5.5.5")
            }
            for _ in 0..<5 {
                group.addTask {
                    _ = await limiter.isBlocked(ip: "5.5.5.5")
                }
            }
        }

        let blockedAfterReset = await limiter.isBlocked(ip: "5.5.5.5")
        XCTAssertFalse(blockedAfterReset, "Reset should clear the IP")
    }

    func testLRUEvictionRetainsMostRecentIPs() async {
        let limiter = RateLimiter(maxAttempts: 5, windowSeconds: 60, maxTrackedIPs: 5)

        for i in 0..<10 {
            await limiter.recordFailure(ip: "10.0.\(i).1")
        }

        // The most recent IP should definitely still be tracked
        let lastBlocked = await limiter.isBlocked(ip: "10.0.9.1")
        XCTAssertFalse(lastBlocked, "Most recent IP should exist but not be blocked (1 failure)")
    }

    // MARK: - Per-IP retention bound

    /// `maxTrackedIPs` bounds how many IPs are tracked, not how many failures
    /// each one accumulates. Without a per-IP cap, one IP failing in a tight
    /// loop grows its timestamp array for the whole window — and `cleanup`'s
    /// `removeFirst()` loop is O(n²) in that length, on an actor that
    /// serializes every other caller behind it.
    func testRetainedFailuresAreBoundedByMaxAttempts() async {
        let limiter = RateLimiter(maxAttempts: 10, windowSeconds: 60)

        for _ in 0..<5_000 {
            await limiter.recordFailure(ip: "9.9.9.9")
        }

        let retained = await limiter._testOnly_retainedFailureCount(ip: "9.9.9.9")
        XCTAssertEqual(retained, 10,
            "retention must be capped at maxAttempts, got \(retained) after 5000 failures")
        let blocked = await limiter.isBlocked(ip: "9.9.9.9")
        XCTAssertTrue(blocked, "capping retention must not weaken the block")
    }

    /// The cap drops the OLDEST timestamp rather than refusing the newest, so
    /// the window slides forward with an ongoing attack and the block persists.
    /// Refusing to append once full would instead let the block lapse
    /// `windowSeconds` after the first burst however long the attack ran.
    func testRetentionCapKeepsWindowSlidingForward() async {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 60)

        await limiter.recordFailure(ip: "8.8.8.8")
        await limiter.recordFailure(ip: "8.8.8.8")

        // Keep failing past the cap; the retained timestamps must track the
        // most recent attempts, so the IP stays blocked rather than aging out
        // on the basis of the two original ones.
        for _ in 0..<20 {
            await limiter.recordFailure(ip: "8.8.8.8")
        }

        let retained = await limiter._testOnly_retainedFailureCount(ip: "8.8.8.8")
        XCTAssertEqual(retained, 2, "retention capped at maxAttempts")
        let blocked = await limiter.isBlocked(ip: "8.8.8.8")
        XCTAssertTrue(blocked, "a sustained attacker must stay blocked")
    }

    /// A capped bucket must still unblock once its retained failures age out,
    /// so the cap cannot turn a rolling window into a permanent ban.
    func testCappedBucketStillExpiresWithTheWindow() async {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 0)

        for _ in 0..<50 {
            await limiter.recordFailure(ip: "7.7.7.7")
        }

        let blocked = await limiter.isBlocked(ip: "7.7.7.7")
        XCTAssertFalse(blocked, "a zero-length window must expire even a capped bucket")
    }
}
