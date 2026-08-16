import XCTest
@testable import ClaudeRelayServer

final class TerminalScreenModelTests: XCTestCase {

    func testPlainTextAppearsInSnapshot() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        _ = model.feed(Data("hello world".utf8))
        XCTAssertTrue(model.snapshot().text.contains("hello world"))
    }

    func testTrailingBlankColumnsAreTrimmed() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        _ = model.feed(Data("abc".utf8))
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
        _ = model.feed(Data(bytes))
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
        _ = model.feed(osc("4;1;40"))
        XCTAssertTrue(model.snapshot().oscProgress.hasPrefix("4;1"), "set state should be reflected")
        _ = model.feed(osc("4;0"))
        XCTAssertTrue(model.snapshot().oscProgress.hasPrefix("4;0"), "remove state maps to herdr's ^4;0 idle signal")
    }

    func testResizeDoesNotCrashAndKeepsContent() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        _ = model.feed(Data("resize me".utf8))
        model.resize(cols: 100, rows: 30)
        XCTAssertTrue(model.snapshot().text.contains("resize me"))
    }

    // MARK: - Answering terminal queries

    /// The other half of the fix `TerminalQueryFilter` starts: with the query
    /// stripped from the client stream, THIS emulator owes the answer. Nobody
    /// else is left to give it.
    func testBackgroundColourQueryIsAnswered() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        let answer = String(decoding: model.feed(Data("\u{1B}]11;?\u{07}".utf8)), as: UTF8.self)
        XCTAssertTrue(answer.contains("11;rgb:"), "expected an OSC 11 colour report, got \(answer.debugDescription)")
    }

    /// Cursor position is the answer that must come from a grid identical to the
    /// device's — which is exactly what this model is (same bytes, same size).
    func testCursorPositionQueryIsAnsweredFromTheEmulatedGrid() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        _ = model.feed(Data("\u{1B}[5;9H".utf8))          // CUP row 5, col 9
        let answer = String(decoding: model.feed(Data("\u{1B}[6n".utf8)), as: UTF8.self)
        XCTAssertEqual(answer, "\u{1B}[5;9R", "CPR must report where the emulated cursor actually is")
    }

    func testDeviceAttributesQueryIsAnswered() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        XCTAssertFalse(model.feed(Data("\u{1B}[c".utf8)).isEmpty, "DA1 must be answered")
    }

    /// Ordinary output must not generate PTY writes — every answer we invent is a
    /// byte injected into the user's input stream.
    func testPlainOutputAnswersNothing() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        XCTAssertEqual(model.feed(Data("hello \u{1B}[1;31mworld\u{1B}[0m\n".utf8)), Data())
    }

    /// Answers are per-feed, not cumulative: a chunk that asks nothing must not
    /// re-send the previous chunk's answer.
    func testAnswersDoNotRepeatOnTheNextFeed() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        XCTAssertFalse(model.feed(Data("\u{1B}[6n".utf8)).isEmpty)
        XCTAssertEqual(model.feed(Data("plain".utf8)), Data(), "the answer must not be replayed")
    }

    /// An answer fed back in (the shell echoes it when the asking program has
    /// already gone) must not itself provoke an answer — that would be a loop
    /// between the PTY and this emulator. SwiftTerm logs `Unknown CSI Code …
    /// code=R` during this test; that log line IS the property being asserted.
    func testFeedingAnAnswerBackDoesNotProvokeAnother() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        let answer = model.feed(Data("\u{1B}[6n".utf8))
        XCTAssertFalse(answer.isEmpty)
        XCTAssertEqual(model.feed(answer), Data(), "an answer is not a query")
    }

    /// A stream packed with queries is bounded here, so it can't evict the user's
    /// real keystrokes from the PTY write queue.
    func testAnswerBurstIsCapped() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        let flood = Data(repeating: 0, count: 0) + Data(String(repeating: "\u{1B}[6n", count: 5000).utf8)
        XCTAssertLessThanOrEqual(model.feed(flood).count, TerminalScreenModel.maxResponseBytesPerFeed)
    }
}
