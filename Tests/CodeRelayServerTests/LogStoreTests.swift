import XCTest
@testable import CodeRelayServer

final class LogStoreTests: XCTestCase {
    func testCompactsAtBoundedOvershoot() {
        let store = LogStore(maxEntries: 100)
        for i in 0..<500 {
            store.append(category: "test", message: "msg-\(i)")
        }
        // With maxEntries=100 and overshoot threshold = min(100, max(10, 100/20)) = 10,
        // live array stays at most maxEntries + (threshold-1) = 109 entries.
        let recent = store.recent(count: 200)
        XCTAssertLessThanOrEqual(recent.count, 109, "Live array should stay within ~1.1× capacity")
        // Confirm we kept the most recent entries, not the oldest.
        XCTAssertTrue(recent.contains(where: { $0.contains("msg-499") }))
        XCTAssertFalse(recent.contains(where: { $0.contains("msg-0]") }))
    }
}
