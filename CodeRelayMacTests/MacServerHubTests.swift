import XCTest
import CodeRelayClient
// Module is c99-sanitized from PRODUCT_NAME "Code[Relay]" — see project.yml.
@testable import Code_Relay_

@MainActor
final class MacServerHubTests: XCTestCase {

    func testFactoryNamespacesEachCoordinatorByBookmark() {
        let config = ConnectionConfig(name: "studio", host: "studio.local")
        let coordinator = MacServerHubFactory.makeCoordinator(config: config, token: "t")
        XCTAssertEqual(coordinator.ownershipKeyPrefixForTest, "com.clauderelay.mac.\(config.id.uuidString)")
        coordinator.tearDown()
    }

    func testCoordinatorConstructsWithoutInstallingObservers() {
        // The hub fans wake/network events out with a stagger (D10); a
        // coordinator that also listened would reconnect twice per wake.
        let config = ConnectionConfig(name: "studio", host: "127.0.0.1", port: 1)
        let coordinator = SessionCoordinator(config: config, token: "t", ownershipKeyPrefix: "mac.test.\(UUID().uuidString)")
        XCTAssertNotNil(coordinator)
        XCTAssertFalse(coordinator.isConnected)
        coordinator.tearDown()
    }

    func testRegistryExposesTheActiveCoordinatorOfTheHub() {
        let registry = ActiveCoordinatorRegistry.shared
        registry.clear()
        XCTAssertNil(registry.hub)
        XCTAssertNil(registry.coordinator)
        XCTAssertNil(registry.serverName)
    }
}
