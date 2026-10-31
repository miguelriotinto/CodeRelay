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

    func testEdgeSwipeRule() {
        func open(x: CGFloat = 5, dx: CGFloat = 60, dy: CGFloat = 0, listOpen: Bool = false) -> Bool {
            EdgeSwipeRule.shouldOpen(startX: x, dx: dx, dy: dy, listOpen: listOpen)
        }
        XCTAssertTrue(open(), "clear rightward swipe from the strip")
        XCTAssertTrue(open(x: 20), "strip edge is inside")
        XCTAssertFalse(open(x: 21), "starts outside the strip: the terminal's")
        XCTAssertFalse(open(x: -1))
        XCTAssertFalse(open(dx: 39.9), "below the threshold")
        XCTAssertTrue(open(dx: 40), "at the threshold")
        XCTAssertFalse(open(dx: 60, dy: 30), "exactly 2x vertical is not horizontal-dominant")
        XCTAssertTrue(open(dx: 60, dy: 29))
        XCTAssertTrue(open(dx: 60, dy: -29))
        XCTAssertFalse(open(dx: 60, dy: 80), "too vertical")
        XCTAssertFalse(open(dx: -60), "leftward")
        XCTAssertFalse(open(listOpen: true), "list already open: nothing")
    }

    /// A hub over an isolated bookmark store and stub tokens: the tests never
    /// touch the app's real bookmarks or keychain, and never dial.
    private func isolatedHub(bookmarks configs: [ConnectionConfig] = []) -> IOSServerHub {
        let suite = "WorkspaceRootTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SavedConnectionStore(key: "test.bookmarks", defaults: defaults)
        store.saveAll(configs)
        return IOSServerHubFactory.make(defaults: defaults, bookmarks: store, tokens: NoTokens())
    }

    final class NoTokens: TokenProviding {
        func loadToken(for connectionId: UUID) throws -> String? { nil }
    }

    func testDeepLinkBeforeHubIsRegisteredIsHeldUntilStart() async {
        // The App struct receives onOpenURL before WorkspaceView's .task has
        // called hub.start(); the hub queues it (startGate) — so the root must
        // hand the link straight to the hub, never drop it when no slot exists.
        let hub = isolatedHub(bookmarks: [ConnectionConfig(name: "a", host: "a.local")])
        let router = DeepLinkRouter(hub: hub)
        var returned = false
        let pending = Task { let o = await router.open(URL(string: "coderelay://session/\(UUID().uuidString)")!); returned = true; return o }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(returned, "held until start(), not answered (or dropped) early")
        await hub.start()
        let outcome = await pending.value
        XCTAssertEqual(outcome, .session(.notFound(serverName: nil)), "routed after start: the only server has no token, so nothing lists it")
        hub.stop()
    }

    func testEditingALiveServerDoesNotRebuildItsCoordinator() {
        // A rebuild detaches the attached session; a working server renamed by
        // its user must not blank the terminal. Only a server that is not live
        // (rejected or missing token, offline) needs the fresh coordinator a
        // pasted token requires.
        func section(_ status: ServerSectionStatus) -> ServerSection {
            ServerSection(config: ConnectionConfig(name: "a", host: "a"), status: status, sessions: [], isCached: false,
                          rollups: [], awaitingInput: 0, isCollapsed: false)
        }
        XCTAssertFalse(ServerListView.shouldRebuild(afterEditing: section(.live)))
        XCTAssertTrue(ServerListView.shouldRebuild(afterEditing: section(.authFailed("No token stored for this server"))))
        XCTAssertTrue(ServerListView.shouldRebuild(afterEditing: section(.offline)))
    }

    func testPairingURLsStillGoToThePairingSheet() async {
        let hub = isolatedHub()
        let router = DeepLinkRouter(hub: hub)
        let outcome = await router.open(URL(string: "coderelay://pair?host=h&port=9200&tls=0&code=ABCDEFGH")!)
        if case .pairing = outcome {} else { XCTFail("expected .pairing, got \(String(describing: outcome))") }
    }
}
