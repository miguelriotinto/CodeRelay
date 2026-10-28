import XCTest
import CodeRelayClient
import CodeRelayKit
// Module is c99-sanitized from PRODUCT_NAME "Code[Relay]" — see project.yml.
@testable import Code_Relay_

final class HubSidebarOrderTests: XCTestCase {
    private func info(_ id: UUID) -> SessionInfo {
        SessionInfo(id: id, state: .activeDetached, tokenId: "t", createdAt: Date(), cols: 80, rows: 24)
    }

    func testRowsFollowSectionOrderAndKeepServerIdentity() {
        let a = ConnectionConfig(name: "a", host: "a"), b = ConnectionConfig(name: "b", host: "b")
        let s1 = UUID(), s2 = UUID()
        let sections = [
            ServerSection(config: a, status: .live, sessions: [info(s1)],
                          isCached: false, rollups: [], awaitingInput: 0, isCollapsed: false),
            ServerSection(config: b, status: .offline, sessions: [info(s2)],
                          isCached: true, rollups: [], awaitingInput: 0, isCollapsed: false)
        ]
        let rows = HubSidebarView.rows(for: sections)
        XCTAssertEqual(rows.map(\.ref), [SessionRef(serverId: a.id, sessionId: s1), SessionRef(serverId: b.id, sessionId: s2)])
        XCTAssertEqual(rows.map(\.isCached), [false, true])
    }

    func testCollapsedSectionContributesNoRows() {
        let section = ServerSection(config: ConnectionConfig(name: "a", host: "a"), status: .live,
                                    sessions: [info(UUID())],
                                    isCached: false, rollups: [], awaitingInput: 0, isCollapsed: true)
        XCTAssertTrue(HubSidebarView.rows(for: [section]).isEmpty)
    }
}
