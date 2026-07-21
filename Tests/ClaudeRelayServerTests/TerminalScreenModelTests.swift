import XCTest
@testable import ClaudeRelayServer

final class TerminalScreenModelTests: XCTestCase {

    func testPlainTextAppearsInSnapshot() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        model.feed(Data("hello world".utf8))
        XCTAssertTrue(model.snapshot().text.contains("hello world"))
    }

    func testTrailingBlankColumnsAreTrimmed() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        model.feed(Data("abc".utf8))
        // translateToString(trimRight:) must drop the null cells padding the row.
        let firstLine = model.snapshot().text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        XCTAssertEqual(firstLine, "abc")
    }

    func testOSCTitleIsCaptured() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        // ESC ] 0 ; <title> BEL
        var bytes: [UInt8] = [0x1B, 0x5D, 0x30, 0x3B]
        bytes.append(contentsOf: "✳ my-project".utf8)
        bytes.append(0x07)
        model.feed(Data(bytes))
        XCTAssertEqual(model.snapshot().oscTitle, "✳ my-project")
    }

    func testOSCProgressSetThenRemove() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        // OSC 9 ; 4 ; <state> ; <pct> ST  — SwiftTerm parses "4;<state>..." progress.
        func osc(_ payload: String) -> Data {
            var b: [UInt8] = [0x1B, 0x5D, 0x39, 0x3B]   // ESC ] 9 ;
            b.append(contentsOf: payload.utf8)
            b.append(0x07)
            return Data(b)
        }
        model.feed(osc("4;1;40"))
        XCTAssertTrue(model.snapshot().oscProgress.hasPrefix("4;1"), "set state should be reflected")
        model.feed(osc("4;0"))
        XCTAssertTrue(model.snapshot().oscProgress.hasPrefix("4;0"), "remove state maps to herdr's ^4;0 idle signal")
    }

    func testResizeDoesNotCrashAndKeepsContent() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        model.feed(Data("resize me".utf8))
        model.resize(cols: 100, rows: 30)
        XCTAssertTrue(model.snapshot().text.contains("resize me"))
    }
}
