import XCTest
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class PairingCodeStoreTests: XCTestCase {

    /// A controllable clock so expiry is tested without sleeping.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ start: Date) { value = start }
        var current: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    private func makeStore(ttl: TimeInterval = 300, maxPending: Int = 8)
        -> (PairingCodeStore, Clock) {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = PairingCodeStore(ttl: ttl, maxPending: maxPending, now: { clock.current })
        return (store, clock)
    }

    func testMintProducesRedeemableCode() async {
        let (store, _) = makeStore()
        let grant = await store.mint(label: "iPhone")
        XCTAssertEqual(grant.code.count, PairingCode.length)
        let redeemed = await store.redeem(grant.code)
        XCTAssertEqual(redeemed?.label, "iPhone")
    }

    func testRedeemIsSingleUse() async {
        let (store, _) = makeStore()
        let grant = await store.mint(label: nil)
        let first = await store.redeem(grant.code)
        XCTAssertNotNil(first)
        let second = await store.redeem(grant.code)
        XCTAssertNil(second, "a code must not be redeemable twice")
        let count = await store.pendingCount()
        XCTAssertEqual(count, 0)
    }

    func testRedeemRejectsUnknownCode() async {
        let (store, _) = makeStore()
        _ = await store.mint(label: nil)
        let result = await store.redeem("00000000")
        XCTAssertNil(result)
    }

    func testRedeemNormalizesHyphenatedLowercaseInput() async {
        let (store, _) = makeStore()
        let grant = await store.mint(label: nil)
        let typed = PairingCode.formatted(grant.code).lowercased()
        let result = await store.redeem(typed)
        XCTAssertNotNil(result)
    }

    func testExpiredCodeIsNotRedeemable() async {
        let (store, clock) = makeStore(ttl: 300)
        let grant = await store.mint(label: nil)
        clock.advance(301)
        let result = await store.redeem(grant.code)
        XCTAssertNil(result)
    }

    func testCodeIsStillValidJustBeforeExpiry() async {
        let (store, clock) = makeStore(ttl: 300)
        let grant = await store.mint(label: nil)
        clock.advance(299)
        let result = await store.redeem(grant.code)
        XCTAssertNotNil(result)
    }

    func testExpiresAtReflectsTTL() async {
        let (store, clock) = makeStore(ttl: 300)
        let before = clock.current
        let grant = await store.mint(label: nil)
        XCTAssertEqual(grant.expiresAt.timeIntervalSince(before), 300, accuracy: 0.001)
    }

    func testMintingPastCapEvictsOldest() async {
        let (store, clock) = makeStore(maxPending: 3)
        let first = await store.mint(label: "first")
        clock.advance(1)
        let second = await store.mint(label: "second")
        clock.advance(1)
        _ = await store.mint(label: "third")
        clock.advance(1)
        _ = await store.mint(label: "fourth")

        let count = await store.pendingCount()
        XCTAssertEqual(count, 3)
        let firstResult = await store.redeem(first.code)
        XCTAssertNil(firstResult, "oldest should have been evicted")
        let secondResult = await store.redeem(second.code)
        XCTAssertNotNil(secondResult)
    }

    func testExpiredEntriesAreSweptOnMint() async {
        let (store, clock) = makeStore(ttl: 60, maxPending: 8)
        _ = await store.mint(label: nil)
        _ = await store.mint(label: nil)
        let count1 = await store.pendingCount()
        XCTAssertEqual(count1, 2)
        clock.advance(61)
        _ = await store.mint(label: nil)
        let count2 = await store.pendingCount()
        XCTAssertEqual(count2, 1, "stale entries should be swept")
    }

    func testRedeemRejectsMalformedInputWithoutTouchingStore() async {
        let (store, _) = makeStore()
        let grant = await store.mint(label: nil)
        let malformed = await store.redeem("!!!")
        XCTAssertNil(malformed)
        let count = await store.pendingCount()
        XCTAssertEqual(count, 1)
        let redeemed = await store.redeem(grant.code)
        XCTAssertNotNil(redeemed)
    }
}
