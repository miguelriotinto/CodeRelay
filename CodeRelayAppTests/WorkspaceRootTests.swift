import XCTest
import CodeRelayClient
@testable import CodeRelayApp

@MainActor
final class WorkspaceRootTests: XCTestCase {
    func testStatusCheckerTargetsOnlyDisabledBookmarks() {
        let a = ConnectionConfig(name: "a", host: "a", enabled: true), b = ConnectionConfig(name: "b", host: "b", enabled: false)
        XCTAssertEqual(ServerListViewModel.pollTargets([a, b]).map(\.id), [b.id])
    }

    func testEmptyStateOpensManagementAndFirstBookmarkStartsWithoutRelaunch() {
        var agg = HubAggregate()
        XCTAssertTrue(WorkspaceRoot.shouldPresentManagement(aggregate: agg), "zero bookmarks: the sheet is the only way forward")
        agg.totalServers = 1; agg.enabledServers = 0
        XCTAssertTrue(WorkspaceRoot.shouldPresentManagement(aggregate: agg), "bookmarks exist but none enabled")
        agg.enabledServers = 1
        XCTAssertFalse(WorkspaceRoot.shouldPresentManagement(aggregate: agg), "an enabled server: the workspace shows it")
    }

    func testDeepLinkBeforeHubIsRegisteredIsHeldUntilStart() async {
        // The App struct receives onOpenURL before WorkspaceView's .task has
        // called hub.start(); the hub queues it (startGate) — so the root must
        // hand the link straight to the hub, never drop it when no slot exists.
        let suite = "WorkspaceRootTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let hub = IOSServerHubFactory.make(defaults: defaults)
        let router = DeepLinkRouter(hub: hub)
        let pending = Task { await router.open(URL(string: "coderelay://session/\(UUID().uuidString)")!) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(pending.isCancelled)
        await hub.start()
        let outcome = await pending.value
        XCTAssertNotNil(outcome, "routed after start, not dropped")
        hub.stop()
    }

    func testPairingURLsStillGoToThePairingSheet() async {
        let suite = "WorkspaceRootTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let hub = IOSServerHubFactory.make(defaults: defaults)
        let router = DeepLinkRouter(hub: hub)
        let outcome = await router.open(URL(string: "coderelay://pair?host=h&port=9200&tls=0&code=ABCDEFGH")!)
        if case .pairing = outcome {} else { XCTFail("expected .pairing, got \(String(describing: outcome))") }
    }
}
