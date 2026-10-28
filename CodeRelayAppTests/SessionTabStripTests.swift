import XCTest
import CodeRelayClient
import CodeRelayKit
@testable import CodeRelayApp

@MainActor
final class SessionTabStripTests: XCTestCase {
    private func section(_ name: String, _ status: ServerSectionStatus, enabled: Bool = true, sessions: Int) -> ServerSection {
        var c = ConnectionConfig(name: name, host: name); c.enabled = enabled
        let list = (0..<sessions).map { _ in SessionInfo(id: UUID(), state: .activeDetached, tokenId: "t", createdAt: Date(), cols: 80, rows: 24) }
        return ServerSection(config: c, status: status, sessions: list, isCached: !status.isLive, rollups: [], awaitingInput: 0, isCollapsed: false)
    }

    func testTabsNumberAcrossServersInSidebarOrderAndSkipDisabled() {
        let a = section("a", .live, sessions: 2), b = section("b", .live, sessions: 1), c = section("c", .disabled, enabled: false, sessions: 3)
        let active = SessionRef(serverId: b.id, sessionId: b.sessions[0].id)
        let tabs = SessionTabStripModel.tabs(sections: [a, b, c], activeRef: active)
        XCTAssertEqual(tabs.map(\.number), [1, 2, 3], "numbers run across servers like ⌘1…9 on the Mac")
        XCTAssertEqual(tabs.map(\.ref.serverId), [a.id, a.id, b.id], "a disabled server's cached rows are not tabs")
        XCTAssertEqual(tabs.map(\.isSelected), [false, false, true])
        XCTAssertEqual(tabs.map(\.serverTitle), ["a", "a", "b"], "several servers: tabs carry the server name for the accessibility label")
    }

    func testOneEnabledServerHasNoServerTitle() {
        let a = section("a", .live, sessions: 1), c = section("c", .disabled, enabled: false, sessions: 1)
        XCTAssertEqual(SessionTabStripModel.tabs(sections: [a, c], activeRef: nil).map(\.serverTitle), [nil], "G8: a one-server user sees no prefix")
    }

    func testTerminalHostKeyChangesAcrossServers() {
        // A cross-server switch must rebuild the host (SwiftTerm keeps hosting the
        // old coordinator's view otherwise); within one server the host is reused.
        let x = IOSServerHubFactory.makeCoordinator(config: ConnectionConfig(name: "x", host: "x"), token: "t")
        let y = IOSServerHubFactory.makeCoordinator(config: ConnectionConfig(name: "y", host: "y"), token: "t")
        XCTAssertEqual(ActiveTerminalView.hostKey(for: x), ActiveTerminalView.hostKey(for: x))
        XCTAssertNotEqual(ActiveTerminalView.hostKey(for: x), ActiveTerminalView.hostKey(for: y))
        XCTAssertNil(ActiveTerminalView.hostKey(for: nil))
        x.tearDown(); y.tearDown()
    }
}
