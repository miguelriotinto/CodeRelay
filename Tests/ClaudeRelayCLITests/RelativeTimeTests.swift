import XCTest
@testable import ClaudeRelayCLI

/// `RelativeTime.portableAbbreviated` — the Linux stand-in for
/// `RelativeDateTimeFormatter`'s `.abbreviated` style. Pinned on every
/// platform so the two implementations cannot drift apart unnoticed.
final class RelativeTimeTests: XCTestCase {

    func testUnitsAndTruncationMatchTheAbbreviatedStyle() {
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 0), "0s ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 45), "45s ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 60), "1m ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 5 * 60 + 59), "5m ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 3600), "1h ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 2 * 3600 + 1800), "2h ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 86_400), "1d ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 3 * 86_400), "3d ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 7 * 86_400), "1w ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 35 * 86_400), "1mo ago")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: 400 * 86_400), "1y ago")
    }

    func testFutureDatesReadAsIn() {
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: -90), "in 1m")
        XCTAssertEqual(RelativeTime.portableAbbreviated(seconds: -2 * 86_400), "in 2d")
    }

    /// The parity check that matters: on macOS this runs the real
    /// `RelativeDateTimeFormatter`, on Linux the stand-in. If the two ever
    /// diverge, macOS CI fails here rather than the two servers quietly
    /// printing different `session list` output.
    func testAbbreviatedUsesTheDateDifference() {
        let now = Date()
        let text = RelativeTime.abbreviated(from: now.addingTimeInterval(-5 * 60), relativeTo: now)
        XCTAssertEqual(text, "5m ago")
    }
}
