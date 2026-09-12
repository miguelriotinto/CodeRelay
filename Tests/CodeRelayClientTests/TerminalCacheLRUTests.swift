#if canImport(AppKit) || canImport(UIKit)
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import XCTest
@testable import CodeRelayClient

@MainActor
final class TerminalCacheLRUTests: XCTestCase {

    private func makeCoordinator() -> SharedSessionCoordinator {
        SharedSessionCoordinator(connection: RelayConnection(), token: "test-token")
    }

    func testCacheEvictsLRUBeyondLimit() {
        let coordinator = makeCoordinator()

        var ids: [UUID] = []
        for _ in 0..<10 {
            let id = UUID()
            ids.append(id)
            coordinator.registerLiveTerminal(for: id, view: NSObject())
        }

        XCTAssertEqual(coordinator.terminalCache.cachedIds.count, 8,
            "cache should be capped at 8")
        XCTAssertNil(coordinator.cachedTerminalView(for: ids[0]),
            "oldest entry should be evicted")
        XCTAssertNil(coordinator.cachedTerminalView(for: ids[1]),
            "second-oldest should be evicted")
        XCTAssertNotNil(coordinator.cachedTerminalView(for: ids[2]))
        XCTAssertNotNil(coordinator.cachedTerminalView(for: ids[9]))
    }

    func testActiveSessionIsNeverEvictedByLRU() {
        let coordinator = makeCoordinator()

        let pinned = UUID()
        coordinator.registerLiveTerminal(for: pinned, view: NSObject())
        coordinator.activeSessionId = pinned

        // Fill with 15 more sessions. LRU would normally pick `pinned` as the
        // oldest, but it's the active session so it's protected.
        for _ in 0..<15 {
            coordinator.registerLiveTerminal(for: UUID(), view: NSObject())
        }

        XCTAssertNotNil(coordinator.cachedTerminalView(for: pinned),
            "active session must not be evicted")
        // `TerminalCache.enforceLimit` can in principle leave the cache at +1
        // over the limit if the only eviction candidate is the active session —
        // but eviction always finds a non-active victim, bringing count back
        // to exactly 8.
        XCTAssertEqual(coordinator.terminalCache.cachedIds.count, 8,
            "protection prevents evicting the active session; a non-active victim is always available")
    }
}
#endif
