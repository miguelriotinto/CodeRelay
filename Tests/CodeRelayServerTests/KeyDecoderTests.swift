import XCTest
@testable import CodeRelayServer

final class KeyDecoderTests: XCTestCase {
    private func decode(_ chunks: [UInt8]...) -> [KeyEvent] {
        var decoder = KeyDecoder()
        var events: [KeyEvent] = []
        for chunk in chunks { events += decoder.decode(Data(chunk)) }
        return events
    }
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testPlainTextIsOneRun() {
        XCTAssertEqual(decode(bytes("hello")), [.text("hello")])
    }

    func testUTF8SplitAcrossChunksCarries() {
        // "é" = C3 A9; the lead byte arrives alone.
        XCTAssertEqual(decode([0xC3], [0xA9, 0x21]), [.text("é!")])
    }

    func testCarriageReturnAndLineFeed() {
        XCTAssertEqual(decode([0x0D]), [.enter([])])
        XCTAssertEqual(decode([0x0A]), [.enter([.control])])
    }

    func testBackspaceAndDelete() {
        XCTAssertEqual(decode([0x7F]), [.backspace])
        XCTAssertEqual(decode([0x08]), [.backspace])
        XCTAssertEqual(decode(bytes("\u{1B}[3~")), [.delete])
        XCTAssertEqual(decode(bytes("\u{1B}[3;5~")), [.delete])
    }

    func testControlKeys() {
        XCTAssertEqual(decode([0x01]), [.control(0x01)])
        XCTAssertEqual(decode([0x15]), [.control(0x15)])
        XCTAssertEqual(decode([0x1F]), [.control(0x1F)])
        XCTAssertEqual(decode([0x09]), [.ignored])   // Tab: completion, not text
    }

    func testAltPrintableAndAltBackspace() {
        XCTAssertEqual(decode(bytes("\u{1B}b")), [.alt("b")])
        XCTAssertEqual(decode([0x1B, 0x7F]), [.alt("\u{7F}")])
        XCTAssertEqual(decode([0x1B, 0x0D]), [.enter([.alt])])
    }

    func testArrowsFromCSIAndSS3IgnoreModifiers() {
        XCTAssertEqual(decode(bytes("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D")), [.up, .down, .right, .left])
        XCTAssertEqual(decode(bytes("\u{1B}OA\u{1B}OD")), [.up, .left])
        XCTAssertEqual(decode(bytes("\u{1B}[1;5D")), [.left])
    }

    func testHomeAndEndVariants() {
        XCTAssertEqual(decode(bytes("\u{1B}[H\u{1B}[F")), [.home, .end])
        XCTAssertEqual(decode(bytes("\u{1B}OH\u{1B}OF")), [.home, .end])
        XCTAssertEqual(decode(bytes("\u{1B}[1~\u{1B}[4~\u{1B}[7~\u{1B}[8~")), [.home, .end, .home, .end])
    }

    func testEscapeSequenceSplitAcrossChunks() {
        XCTAssertEqual(decode([0x1B], [0x5B], [0x44]), [.left])
    }

    func testKittyEnterWithModifiers() {
        XCTAssertEqual(decode(bytes("\u{1B}[13u")), [.enter([])])
        XCTAssertEqual(decode(bytes("\u{1B}[13;2u")), [.enter([.shift])])
        XCTAssertEqual(decode(bytes("\u{1B}[13;3u")), [.enter([.alt])])
        XCTAssertEqual(decode(bytes("\u{1B}[13;5u")), [.enter([.control])])
    }

    func testKittyReleaseEventIsIgnored() {
        XCTAssertEqual(decode(bytes("\u{1B}[97;1:3u")), [.ignored])
        XCTAssertEqual(decode(bytes("\u{1B}[97;1:2u")), [.text("a")])   // repeat counts
    }

    func testKittyTextFieldWinsOverKeyCode() {
        XCTAssertEqual(decode(bytes("\u{1B}[97;2;65u")), [.text("A")])
    }

    func testKittyShiftedAlternateUsedWhenNoText() {
        XCTAssertEqual(decode(bytes("\u{1B}[97:65;2u")), [.text("A")])
        XCTAssertEqual(decode(bytes("\u{1B}[97u")), [.text("a")])
    }

    func testKittyControlAndAltLetters() {
        XCTAssertEqual(decode(bytes("\u{1B}[97;5u")), [.control(0x01)])
        XCTAssertEqual(decode(bytes("\u{1B}[98;3u")), [.alt("b")])
        XCTAssertEqual(decode(bytes("\u{1B}[95;5u")), [.control(0x1F)])   // Ctrl-_
    }

    func testKittySpecialKeyCodes() {
        XCTAssertEqual(decode(bytes("\u{1B}[127u")), [.backspace])
        XCTAssertEqual(decode(bytes("\u{1B}[127;5u")), [.backspace])
        XCTAssertEqual(decode(bytes("\u{1B}[9u\u{1B}[27u")), [.ignored, .ignored])
        XCTAssertEqual(decode(bytes("\u{1B}[57441;1:3u")), [.ignored])   // modifier-only key
    }

    func testModifyOtherKeysEnter() {
        XCTAssertEqual(decode(bytes("\u{1B}[27;5;13~")), [.enter([.control])])
        XCTAssertEqual(decode(bytes("\u{1B}[27;2;13~")), [.enter([.shift])])
    }

    func testBracketedPasteAccumulatesAcrossChunks() {
        XCTAssertEqual(
            decode(bytes("\u{1B}[200~ab"), bytes("c\nd"), bytes("\u{1B}[201~x")),
            [.paste("abc\nd"), .text("x")]
        )
    }

    func testUnknownSequencesAreIgnoredNotTyped() {
        XCTAssertEqual(decode(bytes("\u{1B}[?2004h")), [.ignored])
        XCTAssertEqual(decode(bytes("\u{1B}]0;title\u{07}z")), [.ignored, .text("z")])
        XCTAssertEqual(decode(bytes("\u{1B}]52;c;YWJj\u{1B}\\z")), [.ignored, .text("z")])
        XCTAssertEqual(decode(bytes("\u{1B}P+q544e\u{1B}\\")), [.ignored])
        XCTAssertEqual(decode(bytes("\u{1B}[<35;10;10M")), [.ignored])   // SGR mouse
    }

    func testTextFlushesBeforeControlEvent() {
        XCTAssertEqual(decode(bytes("ab\u{0D}cd")), [.text("ab"), .enter([]), .text("cd")])
    }
}
