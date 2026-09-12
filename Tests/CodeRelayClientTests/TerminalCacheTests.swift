#if canImport(AppKit) || canImport(UIKit)
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import XCTest
@testable import CodeRelayClient

/// Direct unit tests against `TerminalCache`. The coordinator-level
/// `TerminalCacheLRUTests` still covers integration behavior; these tests
/// exercise the cache API in isolation.
@MainActor
final class TerminalCacheTests: XCTestCase {

    func testInitLimitMustBePositive() {
        // Precondition-violation paths aren't XCTest-friendly; instead just
        // verify that a positive limit is accepted.
        let cache = TerminalCache(limit: 1)
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.limit, 1)
    }

    func testRegisterAndLookup() {
        let cache = TerminalCache(limit: 4)
        let id = UUID()
        let view = NSObject()
        cache.register(view: view, for: id)
        XCTAssertTrue(cache.view(for: id) === view)
        XCTAssertEqual(cache.count, 1)
        XCTAssertTrue(cache.liveSessionIds.contains(id))
    }

    func testEvictRemovesAllTrackingForSession() {
        let cache = TerminalCache(limit: 4)
        let id = UUID()
        cache.register(view: NSObject(), for: id)
        cache.evict(id)
        XCTAssertNil(cache.view(for: id))
        XCTAssertFalse(cache.liveSessionIds.contains(id))
        XCTAssertEqual(cache.count, 0)
    }

    func testLRUEvictsOldestBeyondLimit() {
        let cache = TerminalCache(limit: 3)
        var ids: [UUID] = []
        for _ in 0..<5 {
            let id = UUID()
            ids.append(id)
            cache.register(view: NSObject(), for: id)
        }
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache.view(for: ids[0]))
        XCTAssertNil(cache.view(for: ids[1]))
        XCTAssertNotNil(cache.view(for: ids[2]))
        XCTAssertNotNil(cache.view(for: ids[4]))
    }

    func testActiveSessionIsNeverEvicted() {
        let cache = TerminalCache(limit: 3)
        let pinned = UUID()
        cache.register(view: NSObject(), for: pinned, activeSessionId: pinned)
        for _ in 0..<5 {
            cache.register(view: NSObject(), for: UUID(), activeSessionId: pinned)
        }
        XCTAssertNotNil(cache.view(for: pinned))
        XCTAssertEqual(cache.count, 3,
            "Non-active victims are always available; cache returns to limit")
    }

    func testTouchUpdatesLRUOrder() {
        let cache = TerminalCache(limit: 3)
        let a = UUID(), b = UUID(), c = UUID()
        cache.register(view: NSObject(), for: a)
        cache.register(view: NSObject(), for: b)
        cache.register(view: NSObject(), for: c)
        // Touching `a` makes it MRU; now registering a 4th entry should evict
        // `b` (the new oldest), not `a`.
        cache.touch(a)
        let d = UUID()
        cache.register(view: NSObject(), for: d)
        XCTAssertNotNil(cache.view(for: a))
        XCTAssertNil(cache.view(for: b), "b should have been evicted after a was touched")
        XCTAssertNotNil(cache.view(for: c))
        XCTAssertNotNil(cache.view(for: d))
    }

    func testPruneStaleEvictsMissingSessions() {
        let cache = TerminalCache(limit: 5)
        let keep = UUID(), drop = UUID()
        cache.register(view: NSObject(), for: keep)
        cache.register(view: NSObject(), for: drop)
        cache.pruneStale(knownSessionIds: [keep])
        XCTAssertNotNil(cache.view(for: keep))
        XCTAssertNil(cache.view(for: drop))
    }

    func testRemoveAllClearsEverything() {
        let cache = TerminalCache(limit: 3)
        cache.register(view: NSObject(), for: UUID())
        cache.register(view: NSObject(), for: UUID())
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertTrue(cache.liveSessionIds.isEmpty)
        XCTAssertTrue(cache._testOnly_lruOrder.isEmpty)
    }

    func testRegisterOverwritesExistingView() {
        let cache = TerminalCache(limit: 3)
        let id = UUID()
        let first = NSObject()
        let second = NSObject()
        cache.register(view: first, for: id)
        cache.register(view: second, for: id)
        XCTAssertTrue(cache.view(for: id) === second)
        XCTAssertEqual(cache.count, 1)
    }
}
#endif
