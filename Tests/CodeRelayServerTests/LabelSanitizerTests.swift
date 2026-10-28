import XCTest
@testable import CodeRelayServer

final class LabelSanitizerTests: XCTestCase {
    func testTrimsWhitespaceAndNewlines() {
        XCTAssertEqual(LabelSanitizer.sanitize("  Studio \n"), "Studio")
    }

    func testStripsControlCharactersAndEmbeddedNewlines() {
        XCTAssertEqual(LabelSanitizer.sanitize("\u{1B}[31mEvil\nrelay\u{7F}"), "[31mEvilrelay")
    }

    func testCapsAtSixtyScalars() {
        let long = String(repeating: "é", count: 70)
        XCTAssertEqual(LabelSanitizer.sanitize(long).unicodeScalars.count, 60)
    }

    func testEmptyAndControlOnlyBecomeEmpty() {
        XCTAssertEqual(LabelSanitizer.sanitize(""), "")
        XCTAssertEqual(LabelSanitizer.sanitize("\n\t\u{07}"), "")
    }
}
