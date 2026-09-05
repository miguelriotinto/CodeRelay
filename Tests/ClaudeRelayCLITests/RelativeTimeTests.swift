import XCTest
@testable import ClaudeRelayCLI

/// `RelativeTime.portableAbbreviated` — the Linux stand-in for
/// `RelativeDateTimeFormatter`'s `.abbreviated` style. Pinned on every
/// platform so the two implementations cannot drift apart unnoticed.
final class RelativeTimeTests: XCTestCase {

    func testUnitsAndTruncationMatchTheAbbreviatedStyle() {
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 0), "0 sec. ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 45), "45 sec. ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 60), "1 min. ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 5 * 60 + 59), "5 min. ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 3600), "1 hr. ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 2 * 3600 + 1800), "2 hr. ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 86_400), "1 day ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 3 * 86_400), "3 days ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 7 * 86_400), "1 wk. ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 35 * 86_400), "1 mo. ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 400 * 86_400), "1 yr. ago")
    }

    func testFutureDatesReadAsIn() {
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: -90), "in 1 min.")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: -2 * 86_400), "in 2 days")
    }

    func testAbbreviatedUsesTheDateDifference() {
        let now = Date()
        let text = RelativeTime.abbreviated(from: now.addingTimeInterval(-5 * 60), relativeTo: now)
        // Same on both backends: "5 min. ago".
        XCTAssertEqual(text, "5 min. ago")
    }
}
