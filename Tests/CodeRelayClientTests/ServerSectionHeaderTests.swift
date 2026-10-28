import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

final class ServerSectionHeaderTests: XCTestCase {
    private func section(_ status: ServerSectionStatus, name: String = "Studio", displayName: String? = nil,
                         awaiting: Int = 0) -> ServerSection {
        var c = ConnectionConfig(name: name, host: "h"); c.displayName = displayName
        return ServerSection(config: c, status: status, sessions: [], isCached: !status.isLive,
                             rollups: [], awaitingInput: awaiting, isCollapsed: false)
    }

    func testTitlePrefersTheRelaysOwnName() {
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.live, displayName: "studio-mac")).title, "studio-mac")
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.live)).title, "Studio")
    }

    func testSubtitlesAndColours() {
        XCTAssertNil(ServerSectionHeaderModel(section: section(.live)).subtitle)
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.connecting)).subtitle, "connecting…")
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.reconnecting)).subtitle, "reconnecting…")
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.offline)).subtitle, "offline")
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.authFailed("Token rejected"))).subtitle, "Token rejected")
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.disabled)).subtitle, "disabled")
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.live)).dotColor, .green)
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.reconnecting)).dotColor, .orange)
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.offline)).dotColor, .red)
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.authFailed("x"))).dotColor, .orange)
    }

    func testBadgeIsTheAwaitingCountOnlyWhenLive() {
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.live, awaiting: 3)).badge, 3)
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.offline, awaiting: 3)).badge, 0)
    }

    func testRetryIsOfferedForOfflineAndAuthFailedOnly() {
        XCTAssertTrue(ServerSectionHeaderModel(section: section(.offline)).offersRetry)
        XCTAssertTrue(ServerSectionHeaderModel(section: section(.authFailed("x"))).offersRetry)
        XCTAssertFalse(ServerSectionHeaderModel(section: section(.live)).offersRetry)
        XCTAssertFalse(ServerSectionHeaderModel(section: section(.reconnecting)).offersRetry)
    }
}
