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

    func testLoadingPresentationNamesTheFocusServer() {
        // The Mac sheet reads the same presentation as iOS; the server name is
        // the section title of the focus server.
        let p = SessionLoadingPresentation(loadPhase: .attaching, isRecovering: false, recoveryPhase: .reconnecting,
                                           sessionName: "Arya", serverName: "studio")
        XCTAssertEqual(p.subtitle, "Arya · studio")
        XCTAssertEqual(SessionLoadingSheetLayout.macWidth, 320, "width fixed; the height follows the content")
    }

    func testEditingALiveServerDoesNotRebuildItsCoordinator() {
        func section(_ status: ServerSectionStatus) -> ServerSection {
            ServerSection(config: ConnectionConfig(name: "a", host: "a"), status: status, sessions: [], isCached: false,
                          rollups: [], awaitingInput: 0, isCollapsed: false)
        }
        XCTAssertFalse(ServerListWindow.shouldRebuild(afterEditing: section(.live)))
        XCTAssertTrue(ServerListWindow.shouldRebuild(afterEditing: section(.authFailed("x"))))
    }
}
