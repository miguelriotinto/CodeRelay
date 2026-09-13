import XCTest
import SwiftTerm
@testable import CodeRelayServer

final class PromptContextTests: XCTestCase {
    func testTrailingScreenLinesDropsBlankRowsAndKeepsLastForty() {
        let text = (1...60).map { "row \($0)" }.joined(separator: "\n\n   \n")
        let lines = PromptContext.trailingScreenLines(text)
        XCTAssertEqual(lines.count, 40)
        XCTAssertEqual(lines.first, "row 21")
        XCTAssertEqual(lines.last, "row 60")
    }

    func testTrailingScreenLinesCapsBytesFromTheTop() {
        let wide = String(repeating: "x", count: 1000)
        let text = (1...6).map { "\($0)-" + wide }.joined(separator: "\n")
        let lines = PromptContext.trailingScreenLines(text)
        let bytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        XCTAssertLessThanOrEqual(bytes, PromptContext.maxScreenBytes)
        XCTAssertEqual(lines.last?.prefix(2), "6-")
        XCTAssertEqual(lines.count, 4)
    }

    func testKeyboardFlagsRoundTripThroughRawValue() {
        let ctx = PromptContext(draft: "", agentId: nil, agentDisplayName: nil, workingDirectory: nil,
                                screenLines: [], bracketedPaste: false,
                                keyboardFlagsRawValue: KittyKeyboardFlags([.disambiguate, .reportAllKeys]).rawValue)
        XCTAssertTrue(ctx.keyboardFlags.contains(.reportAllKeys))
        XCTAssertFalse(ctx.keyboardFlags.contains(.reportEvents))
    }
}
