import XCTest
@testable import ClaudeRelayClient

final class SidebarCollapseModelTests: XCTestCase {
    func testTogglesCollapseState() {
        var model = SidebarCollapseModel()
        XCTAssertFalse(model.isCollapsed("/repo/a"))
        model.toggle("/repo/a")
        XCTAssertTrue(model.isCollapsed("/repo/a"))
        model.toggle("/repo/a")
        XCTAssertFalse(model.isCollapsed("/repo/a"))
    }

    func testIndependentGroups() {
        var model = SidebarCollapseModel()
        model.toggle("/repo/a")
        XCTAssertTrue(model.isCollapsed("/repo/a"))
        XCTAssertFalse(model.isCollapsed("/repo/b"))
    }
}
