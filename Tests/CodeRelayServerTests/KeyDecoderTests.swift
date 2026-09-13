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

    func testBrokenUTF8DropsThePartialAndKeepsTheASCII() {
        // A lead byte whose continuation never comes: the partial scalar is
        // dropped and the byte that broke it is reprocessed from ground, so the
        // ASCII survives instead of the whole run being lost.
        XCTAssertEqual(decode([0xC3, 0x41, 0x42]), [.text("AB")])
        XCTAssertEqual(decode([0xE2, 0x82], [0x41]), [.text("A")])   // truncated "€"
    }

    func testCarriageReturnAndLineFeed() {
        XCTAssertEqual(decode([0x0D]), [.enter([])])
        // Bare LF is its own event: the probe measured it as the newline chord
        // for claude/codex while CSI 13;5u (`ctrl_enter`) does nothing there.
        XCTAssertEqual(decode([0x0A]), [.lineFeed])
    }

    func testBackspaceAndDelete() {
        XCTAssertEqual(decode([0x7F]), [.backspace])
        XCTAssertEqual(decode([0x08]), [.backspace])
        XCTAssertEqual(decode(bytes("\u{1B}[3~")), [.delete])
        // Ctrl+Delete is a *word* delete — not modelled, so it clears.
        XCTAssertEqual(decode(bytes("\u{1B}[3;5~")), [.unknown])
    }

    func testControlKeys() {
        XCTAssertEqual(decode([0x01]), [.control(0x01)])
        XCTAssertEqual(decode([0x15]), [.control(0x15)])
        XCTAssertEqual(decode([0x1F]), [.control(0x1F)])
        XCTAssertEqual(decode([0x09]), [.control(0x09)])   // Tab: the tracker clears on it
    }

    func testAltPrintableAndAltBackspace() {
        XCTAssertEqual(decode(bytes("\u{1B}b")), [.alt("b")])
        XCTAssertEqual(decode([0x1B, 0x7F]), [.alt("\u{7F}")])
        XCTAssertEqual(decode([0x1B, 0x0D]), [.enter([.alt])])
    }

    func testArrowsFromCSIAndSS3() {
        XCTAssertEqual(decode(bytes("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D")), [.up, .down, .right, .left])
        XCTAssertEqual(decode(bytes("\u{1B}OA\u{1B}OD")), [.up, .left])
        // A modified arrow is a word jump or a selection drag, neither modelled.
        XCTAssertEqual(decode(bytes("\u{1B}[1;5D")), [.unknown])
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

    /// The associated-text field is read *before* the functional-key guard: a
    /// keypad key reports a code above 57344 but carries the digit it typed, and
    /// that digit is what landed on the agent's input line.
    func testKittyFunctionalKeyCodeWithTextEmitsTheText() {
        XCTAssertEqual(decode(bytes("\u{1B}[57400;1;55u")), [.text("7")])   // keypad 7
        XCTAssertEqual(decode(bytes("\u{1B}[57400u")), [.ignored])          // same key, no text
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
        XCTAssertEqual(decode(bytes("\u{1B}[9u\u{1B}[27u")), [.control(0x09), .unknown])
        XCTAssertEqual(decode(bytes("\u{1B}[57441;1:3u")), [.ignored])   // modifier-only key
    }

    /// Super+Enter: the super bit is stripped, so it reads as a plain Enter and
    /// resolves through the profile like one. For the default profile that means
    /// "submit" — i.e. clear — which is the safe direction if the agent ignored it.
    func testKittySuperEnterStripsSuper() {
        XCTAssertEqual(decode(bytes("\u{1B}[13;9u")), [.enter([])])
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

    func testOversizedPasteFlushRetainsPartialTerminator() {
        // A paste larger than maxPasteBytes is flushed in pieces. If the 6-byte
        // terminator (ESC [ 2 0 1 ~) straddles the flush boundary, the last 5
        // bytes must be retained so the terminator is still recognized.
        var decoder = KeyDecoder()
        var events: [KeyEvent] = []

        // Start bracketed paste
        events += decoder.decode(Data(bytes("\u{1B}[200~")))

        // Fill to maxPasteBytes, then add "ESC [" to exceed the cap
        let content = String(repeating: "a", count: KeyDecoder.maxPasteBytes)
        events += decoder.decode(Data(content.utf8))
        events += decoder.decode(Data([0x1B, 0x5B]))  // "ESC [" — first 2 bytes of terminator

        // The flush fires on the ESC (buffer = maxPasteBytes + 1) and retains the
        // last 5 bytes — 4 'a's + ESC — so the terminator can still match. The
        // '[' lands after it. Send the rest of the terminator.
        events += decoder.decode(Data([0x32, 0x30, 0x31, 0x7E]))  // "2 0 1 ~"

        // Verify: send plain text to confirm we exited paste state
        events += decoder.decode(Data(bytes("x")))

        XCTAssertEqual(events.count, 3)
        if case .paste(let first) = events[0] {
            // Flush fires after appending ESC (buffer = 1,048,577 bytes).
            // Flush outputs first 1,048,572 bytes; keeps last 5 (4 'a's + ESC).
            XCTAssertEqual(first.count, KeyDecoder.maxPasteBytes - 4)
        } else {
            XCTFail("Expected first event to be paste, got \(events[0])")
        }
        if case .paste(let second) = events[1] {
            // After flush, buffer has "aaaaESC". Then "[201~" arrives, terminator
            // matches and is removed, leaving "aaaa".
            XCTAssertEqual(second, "aaaa")
        } else {
            XCTFail("Expected second event to be paste, got \(events[1])")
        }
        XCTAssertEqual(events[2], .text("x"))  // Decoder exited paste state
    }

    // MARK: C1 — the OSC/DCS byte cap

    func testUnterminatedOSCIsAbandonedAtTheByteCap() {
        // Alt+] is byte-identical to the OSC introducer, so an unterminated
        // string sequence is a *keystroke*, not a protocol error: without the
        // cap the decoder stays in .osc for the rest of the session while the
        // user keeps typing.
        let filler = String(repeating: "a", count: 1100)
        let events = decode(bytes("\u{1B}]" + filler + "hi"))
        let survivors = 1100 - KeyDecoder.maxStringSequenceBytes - 1
        XCTAssertEqual(events, [.unknown, .text(String(repeating: "a", count: survivors) + "hi")])
    }

    func testUnterminatedDCSIsAbandonedAtTheByteCap() {
        // Alt+Shift+P is byte-identical to the DCS introducer.
        let filler = String(repeating: "b", count: 1100)
        let events = decode(bytes("\u{1B}P" + filler + "hi"))
        let survivors = 1100 - KeyDecoder.maxStringSequenceBytes - 1
        XCTAssertEqual(events, [.unknown, .text(String(repeating: "b", count: survivors) + "hi")])
    }

    func testWellFormedStringSequencesStayIgnored() {
        XCTAssertEqual(decode(bytes("\u{1B}]0;title\u{07}")), [.ignored])
        XCTAssertEqual(decode(bytes("\u{1B}]0;title\u{1B}\\")), [.ignored])
        XCTAssertEqual(decode(bytes("\u{1B}P+q544e\u{1B}\\")), [.ignored])
    }

    // MARK: C2 — .unknown vs .ignored

    func testEscapeThenPrintableIsStillAlt() {
        // The decoder is unchanged here; the tracker is what clears on Alt+H.
        XCTAssertEqual(decode(bytes("\u{1B}h")), [.alt("h")])
    }

    func testModifiedArrowsAndHomeEndAreUnknown() {
        XCTAssertEqual(decode(bytes("\u{1B}[1;5D")), [.unknown])   // Ctrl+Left: word jump
        XCTAssertEqual(decode(bytes("\u{1B}[1;2C")), [.unknown])   // Shift+Right: selection
        XCTAssertEqual(decode(bytes("\u{1B}[1;3H")), [.unknown])
        XCTAssertEqual(decode(bytes("\u{1B}[1;5~")), [.unknown])   // Ctrl+Home
        XCTAssertEqual(decode(bytes("\u{1B}[1;1D")), [.left])      // mods=1 means "none"
    }

    func testUnknownCSIFinalAndSS3AreUnknown() {
        XCTAssertEqual(decode(bytes("\u{1B}[Z")), [.unknown])      // back-tab
        XCTAssertEqual(decode(bytes("\u{1B}OP")), [.unknown])      // SS3 F1
    }

    func testMouseReportAndCursorPositionReplyStayIgnored() {
        XCTAssertEqual(decode(bytes("\u{1B}[<35;10;10M")), [.ignored])   // SGR mouse
        XCTAssertEqual(decode(bytes("\u{1B}[24;80R")), [.ignored])       // CPR reply
        XCTAssertEqual(decode(bytes("\u{1B}[?1;2c")), [.ignored])        // DA reply
    }

    /// PageUp/PageDown scroll the transcript in both measured agents and never
    /// touch the input line, with or without a modifier field. F13… ride the same
    /// tilde codes as F1…F12 and are just as inert. Insert is *not* in that set:
    /// it toggles overwrite mode, which the tracker does not model.
    func testPageKeysAndHighFunctionKeysAreIgnored() {
        XCTAssertEqual(decode(bytes("\u{1B}[5~")), [.ignored])      // PageUp
        XCTAssertEqual(decode(bytes("\u{1B}[6~")), [.ignored])      // PageDown
        XCTAssertEqual(decode(bytes("\u{1B}[5;2~")), [.ignored])    // Shift+PageUp
        XCTAssertEqual(decode(bytes("\u{1B}[25~")), [.ignored])     // F13
        XCTAssertEqual(decode(bytes("\u{1B}[34~")), [.ignored])     // F20
    }

    func testInsertStaysUnknown() {
        XCTAssertEqual(decode(bytes("\u{1B}[2~")), [.unknown])
    }

    func testCSIParameterOverflowIsUnknownThenDecodingResumes() {
        let overlong = String(repeating: "1", count: KeyDecoder.maxCSIParameterBytes + 1)
        // The abandoned sequence's final byte is re-read in ground state, so the
        // 'D' surfaces as text — the point is that the decoder is unwedged.
        XCTAssertEqual(decode(bytes("\u{1B}[" + overlong + "Dok")), [.unknown, .text("Dok")])
    }

    // MARK: C3 — bounded work per frame

    func testLongPrintableFrameIsBoundedAndClearsTheMirror() {
        // The whole over-long run is dropped, not just the excess: a partial
        // tail would leave the mirror holding the end of a much longer real
        // line (under-counting, the one direction that corrupts input).
        var decoder = KeyDecoder()
        let events = decoder.decode(Data(String(repeating: "a", count: 40_000).utf8))
        XCTAssertEqual(events, [.unknown])
        var tracker = DraftTracker(profile: .default, columns: 80)
        tracker.apply(contentsOf: events)
        XCTAssertEqual(tracker.draft, "")

        // Exactly at the bound still fits, and is still one bounded `.text`.
        var decoder2 = KeyDecoder()
        let atBound = decoder2.decode(Data(String(repeating: "a", count: DraftTracker.maxScalars).utf8))
        XCTAssertEqual(atBound.count, 1)
        if case .text(let run) = atBound[0] {
            XCTAssertEqual(run.unicodeScalars.count, DraftTracker.maxScalars)
        } else {
            XCTFail("expected one .text event, got \(atBound)")
        }

        // A dropped run does not poison the rest of the stream.
        var decoder3 = KeyDecoder()
        let mixed = decoder3.decode(Data((String(repeating: "b", count: 20_000) + "\u{1B}[Dok").utf8))
        XCTAssertEqual(mixed, [.unknown, .left, .text("ok")])
    }
}
