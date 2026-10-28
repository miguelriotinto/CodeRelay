import XCTest
import CodeRelayClient
import CodeRelayKit
@testable import CodeRelayApp

final class SidebarSectionsTests: XCTestCase {
    private func section(_ name: String, _ status: ServerSectionStatus, sessions: Int, collapsed: Bool = false) -> ServerSection {
        let c = ConnectionConfig(name: name, host: name)
        let list = (0..<sessions).map { _ in
            SessionInfo(id: UUID(), state: .activeDetached, tokenId: "t", createdAt: Date(), cols: 80, rows: 24)
        }
        return ServerSection(config: c, status: status, sessions: list, isCached: !status.isLive,
                             rollups: [], awaitingInput: 0, isCollapsed: collapsed)
    }

    func testRowsFollowSidebarOrderSkipCollapsedAndMarkCached() {
        let a = section("a", .live, sessions: 2), b = section("b", .offline, sessions: 1), c = section("c", .live, sessions: 1, collapsed: true)
        let rows = SessionSidebarView.rows(for: [a, b, c])
        XCTAssertEqual(rows.map(\.ref.serverId), [a.id, a.id, b.id], "c is collapsed; order is sidebar order")
        XCTAssertEqual(rows.map(\.isCached), [false, false, true], "offline rows are cached (D4)")
    }

    func testAuthFailedHeaderRetryOpensManagement() {
        XCTAssertEqual(SessionSidebarView.retryAction(for: section("a", .authFailed("Token rejected"), sessions: 0)), .openManagement,
                       "re-pairing happens on the management screen, not by retrying the rejected token")
        XCTAssertEqual(SessionSidebarView.retryAction(for: section("a", .offline, sessions: 0)), .recover)
    }
}
