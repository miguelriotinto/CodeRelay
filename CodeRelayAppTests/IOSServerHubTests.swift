import XCTest
import CodeRelayClient
@testable import CodeRelayApp

@MainActor
final class IOSServerHubTests: XCTestCase {
    func testFactoryNamespacesEachCoordinatorByBookmark() {
        let config = ConnectionConfig(name: "studio", host: "studio.local")
        let coordinator = IOSServerHubFactory.makeCoordinator(config: config, token: "t")
        XCTAssertEqual(coordinator.ownershipKeyPrefixForTest, "com.clauderelay.\(config.id.uuidString)")
        coordinator.tearDown()
    }

    func testMigrationReadsTheLegacyLastConnectedServerKey() {
        // AppSettings stores the pre-hub choice under this @AppStorage key; the
        // hub's one-time migration (spec §9) must read the same string.
        XCTAssertEqual(IOSServerHubFactory.lastServerIdKey, "lastConnectedServerId")
        let settings = AppSettings.shared
        let probe = UUID().uuidString
        let previous = settings.lastConnectedServerId
        settings.lastConnectedServerId = probe
        XCTAssertEqual(UserDefaults.standard.string(forKey: IOSServerHubFactory.lastServerIdKey), probe)
        settings.lastConnectedServerId = previous
    }

    func testCoordinatorInstallsNoObserversOfItsOwn() {
        // Wake/network events are fanned out by the hub with a stagger (D10);
        // a coordinator that also listened would reconnect twice per wake.
        let coordinator = SessionCoordinator(config: ConnectionConfig(name: "a", host: "127.0.0.1", port: 1),
                                             token: "t", ownershipKeyPrefix: "ios.test.\(UUID().uuidString)")
        XCTAssertFalse(coordinator.hasNetworkRecoveryForTest)
        coordinator.tearDown()
    }

    func testHubStartsWithTheSavedBookmarksInAnIsolatedSuite() async {
        let suite = "IOSServerHubTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let hub = IOSServerHubFactory.make(defaults: defaults)
        await hub.start()
        XCTAssertEqual(hub.aggregate.totalServers, CodeRelayApp.savedConnections.loadAll().count,
                       "the factory reads the app's bookmark store; the hub state lives in the given defaults")
        hub.stop()
    }
}
