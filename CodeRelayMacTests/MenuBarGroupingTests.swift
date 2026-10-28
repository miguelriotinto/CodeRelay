import XCTest
import SwiftUI
import CodeRelayClient
import CodeRelayKit
// Module is c99-sanitized from PRODUCT_NAME "Code[Relay]" — see project.yml.
@testable import Code_Relay_

@MainActor
final class MenuBarGroupingTests: XCTestCase {
    private func section(_ name: String, _ status: ServerSectionStatus, enabled: Bool = true, sessions: Int = 1) -> ServerSection {
        var c = ConnectionConfig(name: name, host: name); c.enabled = enabled
        let list = (0..<sessions).map { _ in
            SessionInfo(id: UUID(), state: .activeDetached, tokenId: "t", createdAt: Date(), cols: 80, rows: 24)
        }
        return ServerSection(config: c, status: status, sessions: list, isCached: !status.isLive,
                             rollups: [], awaitingInput: 0, isCollapsed: false)
    }

    func testOneEnabledServerHasNoGroupTitle() {
        let groups = MenuBarViewModel.groups(from: [section("a", .live), section("b", .disabled, enabled: false)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0].title, "G8: a one-server user sees no server prefix")
    }

    func testSeveralEnabledServersAreTitledAndKeepOrder() {
        let groups = MenuBarViewModel.groups(from: [section("a", .live), section("b", .offline)])
        XCTAssertEqual(groups.map(\.title), ["a", "b"])
        XCTAssertEqual(groups[1].statusColor, .red)
        XCTAssertEqual(groups[1].sessions.count, 1, "cached rows stay listed")
    }

    func testConnectionColourRules() {
        XCTAssertEqual(MenuBarViewModel.connectionColor(for: [section("a", .live)], activeServerId: nil), .green)
        XCTAssertEqual(MenuBarViewModel.connectionColor(for: [section("a", .live), section("b", .reconnecting)], activeServerId: nil), .orange)
        XCTAssertEqual(MenuBarViewModel.connectionColor(for: [section("a", .offline), section("b", .offline)], activeServerId: nil), .red)
        XCTAssertEqual(MenuBarViewModel.connectionColor(for: [section("a", .disabled, enabled: false)], activeServerId: nil), .secondary)
        XCTAssertEqual(MenuBarViewModel.connectionColor(for: [section("a", .live), section("b", .authFailed("x"))], activeServerId: nil), .orange)
    }

    func testStatusCheckerTargetsOnlyDisabledBookmarks() {
        let a = ConnectionConfig(name: "a", host: "a", enabled: true), b = ConnectionConfig(name: "b", host: "b", enabled: false)
        XCTAssertEqual(ServerListViewModel.pollTargets([a, b]).map(\.id), [b.id])
    }
}
