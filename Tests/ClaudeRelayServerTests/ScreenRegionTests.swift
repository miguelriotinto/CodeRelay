import XCTest
@testable import ClaudeRelayServer

final class ScreenRegionTests: XCTestCase {

    private func snap(_ text: String, oscTitle: String = "", oscProgress: String = "") -> ScreenSnapshot {
        ScreenSnapshot(text: text, oscTitle: oscTitle, oscProgress: oscProgress)
    }

    func testWholeRecentReturnsFullText() {
        let s = snap("a\nb\nc")
        XCTAssertEqual(ScreenRegion.slice("whole_recent", snapshot: s), "a\nb\nc")
    }

    func testOSCRegionsSourceFromDedicatedFields() {
        let s = snap("screen text", oscTitle: "T", oscProgress: "4;0")
        XCTAssertEqual(ScreenRegion.slice("osc_title", snapshot: s), "T")
        XCTAssertEqual(ScreenRegion.slice("osc_progress", snapshot: s), "4;0")
    }

    func testBottomNonEmptyLines() {
        let s = snap("one\n\ntwo\nthree\n\n")
        // Last 2 non-empty lines are "two" and "three"; slice runs from "two" to end.
        XCTAssertEqual(ScreenRegion.slice("bottom_non_empty_lines(2)", snapshot: s), "two\nthree\n\n")
    }

    func testBottomNonEmptyLinesEmptyWhenNoContent() {
        XCTAssertEqual(ScreenRegion.slice("bottom_non_empty_lines(3)", snapshot: snap("\n\n")), "")
    }

    func testIsHorizontalRule() {
        XCTAssertTrue(ScreenRegion.isHorizontalRule("────────"))
        XCTAssertTrue(ScreenRegion.isHorizontalRule("─── Tools ───"))   // ≥3 leading + suffix
        XCTAssertFalse(ScreenRegion.isHorizontalRule("─ x"))            // 1 leading, non-empty suffix
        XCTAssertFalse(ScreenRegion.isHorizontalRule("plain text"))
        XCTAssertFalse(ScreenRegion.isHorizontalRule("   "))
    }

    func testAfterLastHorizontalRule() {
        let s = snap("top\n────\nmiddle\n────\nbottom line")
        XCTAssertEqual(ScreenRegion.slice("after_last_horizontal_rule", snapshot: s), "bottom line")
    }

    func testAfterLastHorizontalRuleWholeWhenNoRule() {
        let s = snap("no rules here\njust text")
        XCTAssertEqual(ScreenRegion.slice("after_last_horizontal_rule", snapshot: s), "no rules here\njust text")
    }

    func testPromptBoxBody() {
        // Two rules near the bottom; body is what sits strictly between the
        // 2nd-from-bottom rule and the next rule below it.
        let s = snap("history\n────\n❯ type here\n────\nesc to cancel")
        XCTAssertEqual(ScreenRegion.slice("prompt_box_body", snapshot: s), "❯ type here")
    }

    func testPromptBoxBodyEmptyWithoutTwoRules() {
        XCTAssertEqual(ScreenRegion.slice("prompt_box_body", snapshot: snap("just\none rule\n────")), "")
    }

    func testAfterLastPromptMarker() {
        let s = snap("history\n› old\nmiddle\n› \nafter marker")
        XCTAssertEqual(ScreenRegion.slice("after_last_prompt_marker", snapshot: s), "after marker")
    }

    func testAfterLastPromptMarkerWholeWhenNoMarker() {
        let s = snap("no prompt\nlines")
        XCTAssertEqual(ScreenRegion.slice("after_last_prompt_marker", snapshot: s), "no prompt\nlines")
    }

    func testUnknownRegionReturnsEmpty() {
        XCTAssertEqual(ScreenRegion.slice("nonsense_region", snapshot: snap("x")), "")
    }
}
