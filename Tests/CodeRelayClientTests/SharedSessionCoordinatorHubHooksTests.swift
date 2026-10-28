import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

/// The additive hooks the multi-server hub needs from a per-server coordinator
/// (spec §7.4). Everything else about the coordinator is unchanged.
@MainActor
final class SharedSessionCoordinatorHubHooksTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        let suite = "HubHooksTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testOwnershipNamespaceIsolatesNamesPerServer() {
        let defaults = isolatedDefaults()
        let serverA = UUID(), serverB = UUID()
        let shared = UUID()   // same session UUID on both servers (ephemeral ids can collide in a test)
        let a = SharedSessionCoordinator(connection: RelayConnection(), token: "t",
                                         ownershipKeyPrefix: "test.\(serverA.uuidString)", defaults: defaults)
        let b = SharedSessionCoordinator(connection: RelayConnection(), token: "t",
                                         ownershipKeyPrefix: "test.\(serverB.uuidString)", defaults: defaults)
        a.sessionNames[shared] = "alpha"
        a.persistNamesForTest()
        b.sessionNames[shared] = "bravo"
        b.persistNamesForTest()

        let a2 = SharedSessionCoordinator(connection: RelayConnection(), token: "t",
                                          ownershipKeyPrefix: "test.\(serverA.uuidString)", defaults: defaults)
        let b2 = SharedSessionCoordinator(connection: RelayConnection(), token: "t",
                                          ownershipKeyPrefix: "test.\(serverB.uuidString)", defaults: defaults)
        XCTAssertEqual(a2.sessionNames[shared], "alpha")
        XCTAssertEqual(b2.sessionNames[shared], "bravo")
    }

    func testDefaultNamespaceIsTheClassPrefix() {
        let defaults = isolatedDefaults()
        let c = SharedSessionCoordinator(connection: RelayConnection(), token: "t", defaults: defaults)
        XCTAssertEqual(c.ownershipKeyPrefixForTest, SharedSessionCoordinator.keyPrefix)
    }

    func testDetachActiveWithNothingAttachedIsANoOp() async {
        let c = SharedSessionCoordinator(connection: RelayConnection(), token: "t", defaults: isolatedDefaults())
        await c.detachActive()
        XCTAssertNil(c.activeSessionId)
        XCTAssertFalse(c.showError, "nothing to detach is not an error")
    }

    func testDetachActiveClearsSelectionEvenWhenTheWireIsDead() async {
        // The connection was never opened, so the detach RPC cannot succeed; the
        // local selection must still be cleared within the budget so the hub can
        // attach on another server.
        let c = SharedSessionCoordinator(connection: RelayConnection(), token: "t", defaults: isolatedDefaults())
        c.detachBudget = .milliseconds(200)
        let id = UUID()
        c.terminalViewModels[id] = TerminalViewModel(sessionId: id, connection: c.connection)
        c.activeSessionId = id
        let started = ContinuousClock.now
        await c.detachActive()
        XCTAssertNil(c.activeSessionId)
        XCTAssertNil(c.terminalViewModels[id])
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "bounded by detachBudget")
        XCTAssertFalse(c.showError, "a failed detach on a dead socket is not surfaced; recovery reconciles")
    }

    func testIsAuthRejectedStartsFalse() {
        let c = SharedSessionCoordinator(connection: RelayConnection(), token: "t", defaults: isolatedDefaults())
        XCTAssertFalse(c.isAuthRejected)
        XCTAssertEqual(c.connectionState, .disconnected)
        XCTAssertNil(c.serverIdentity)
    }
}
