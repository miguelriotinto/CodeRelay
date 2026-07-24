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

    // F3: seed from persistence + expose the set for saving.
    func testSeedsFromPersistedSet() {
        let model = SidebarCollapseModel(collapsed: ["/repo/a", "/repo/c"])
        XCTAssertTrue(model.isCollapsed("/repo/a"))
        XCTAssertTrue(model.isCollapsed("/repo/c"))
        XCTAssertFalse(model.isCollapsed("/repo/b"))
    }

    func testCollapsedGroupIdsReflectsToggles() {
        var model = SidebarCollapseModel(collapsed: ["/repo/a"])
        model.toggle("/repo/b")       // add
        model.toggle("/repo/a")       // remove
        XCTAssertEqual(model.collapsedGroupIds, ["/repo/b"])
    }
}
