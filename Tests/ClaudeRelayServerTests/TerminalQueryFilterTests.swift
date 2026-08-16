import XCTest
@testable import ClaudeRelayServer

/// The device must never see a terminal *query*: it would answer a WebSocket
/// round trip too late, and the answer lands as typed text at whatever prompt is
/// current (the `11;rgb:0000/0000/0000` report). The server answers instead —
/// see `TerminalScreenModel.feed` — so these bytes are stripped at the seam
/// where PTY output splits into history + client stream.
final class TerminalQueryFilterTests: XCTestCase {

    /// Strip in place of a surrounding payload, so a test failure shows whether
    /// the sequence was missed, over-consumed, or mangled.
    private func stripped(_ sequence: String) -> String {
        let data = Data("before".utf8) + Data(sequence.utf8) + Data("after".utf8)
        return String(decoding: TerminalQueryFilter.strip(data), as: UTF8.self)
    }

    private func assertStripped(_ sequence: String, _ label: String) {
        XCTAssertEqual(stripped(sequence), "beforeafter", "\(label) must not reach the device")
    }

    private func assertPreserved(_ sequence: String, _ label: String) {
        XCTAssertEqual(stripped(sequence), "before\(sequence)after",
                       "\(label) is not a query — it must pass through byte-exact")
    }

    // MARK: - Queries that must be stripped

    func testStripsDeviceAttributeRequests() {
        assertStripped("\u{1B}[c", "DA1 (bare)")
        assertStripped("\u{1B}[0c", "DA1 (explicit 0)")
        assertStripped("\u{1B}[>c", "DA2 (secondary)")
        assertStripped("\u{1B}[=c", "DA3 (tertiary)")
    }

    func testStripsDeviceStatusRequests() {
        assertStripped("\u{1B}[5n", "DSR (operating status)")
        assertStripped("\u{1B}[6n", "DSR (cursor position)")
        assertStripped("\u{1B}[?6n", "DECDSR (extended cursor position)")
        assertStripped("\u{1B}[?25n", "DECDSR (user-defined keys)")
    }

    func testStripsModeAndKeyboardRequests() {
        assertStripped("\u{1B}[?1$p", "DECRQM (private mode)")
        assertStripped("\u{1B}[2$p", "DECRQM (ANSI mode)")
        assertStripped("\u{1B}[?u", "kitty keyboard flags query")
    }

    /// Only the *reporting* window ops. Iconify/raise/title-stack share the `t`
    /// final byte and are real commands, asserted below.
    func testStripsWindowReportRequests() {
        for op in [13, 14, 15, 16, 18, 19, 20, 21] {
            assertStripped("\u{1B}[\(op)t", "XTWINOPS report \(op)t")
        }
    }

    func testStripsDCSRequests() {
        assertStripped("\u{1B}P$qm\u{1B}\\", "DECRQSS (request SGR)")
        assertStripped("\u{1B}P+q544e\u{1B}\\", "XTGETTCAP")
    }

    /// The reported bug: a colour query whose answer the device mints from its
    /// own (forced black) background.
    func testStripsColourQueries() {
        assertStripped("\u{1B}]11;?\u{07}", "OSC 11 background query (BEL-terminated)")
        assertStripped("\u{1B}]11;?\u{1B}\\", "OSC 11 background query (ST-terminated)")
        assertStripped("\u{1B}]10;?\u{07}", "OSC 10 foreground query")
        assertStripped("\u{1B}]12;?\u{07}", "OSC 12 cursor-colour query")
        assertStripped("\u{1B}]4;1;?\u{07}", "OSC 4 palette query")
    }

    /// A read request must never reach the device, or the device's clipboard
    /// answers it — the leak `OSC52Parser` already refuses in the other direction.
    func testStripsClipboardReadRequest() {
        assertStripped("\u{1B}]52;c;?\u{07}", "OSC 52 clipboard read")
    }

    // MARK: - Sequences that must survive

    /// Each of these shares a final byte with a query above; confusing one for
    /// the other would corrupt the render instead of cleaning it up.
    func testPreservesCommandsSharingAQueryFinalByte() {
        assertPreserved("\u{1B}[u", "SCORC (restore cursor) — `u` without `?`")
        assertPreserved("\u{1B}[!p", "DECSTR (soft reset) — `p` without `$`")
        assertPreserved("\u{1B}[22t", "XTWINOPS push title")
        assertPreserved("\u{1B}[23t", "XTWINOPS pop title")
        assertPreserved("\u{1B}[1t", "XTWINOPS de-iconify")
        assertPreserved("\u{1B}[11t", "XTWINOPS report-state — SwiftTerm ignores it")
    }

    func testPreservesRenderingSequences() {
        assertPreserved("\u{1B}[1;31m", "SGR")
        assertPreserved("\u{1B}[10;5H", "CUP")
        assertPreserved("\u{1B}[2J", "ED (erase display)")
        assertPreserved("\u{1B}c", "RIS")
    }

    func testPreservesOSCCommands() {
        assertPreserved("\u{1B}]0;my-project\u{07}", "OSC 0 title set")
        assertPreserved("\u{1B}]11;rgb:1111/2222/3333\u{07}", "OSC 11 background SET")
        assertPreserved("\u{1B}]52;c;aGVsbG8=\u{07}", "OSC 52 clipboard write")
        assertPreserved("\u{1B}]9;4;1;40\u{07}", "OSC 9;4 progress")
    }

    /// A `?` anywhere in an OSC payload is not a query — only a `?` standing
    /// alone as the final parameter is.
    func testPreservesOSCPayloadContainingAQuestionMark() {
        assertPreserved("\u{1B}]0;is this a title?\u{07}", "OSC 0 title ending in '?'")
    }

    // MARK: - Boundaries

    func testEmptyAndPlainInputAreUnchanged() {
        XCTAssertEqual(TerminalQueryFilter.strip(Data()), Data())
        let plain = Data("no escapes at all\n".utf8)
        XCTAssertEqual(TerminalQueryFilter.strip(plain), plain)
    }

    func testStripsRepeatedAndAdjacentQueries() {
        let data = Data("a\u{1B}[6nb\u{1B}]11;?\u{07}\u{1B}[cc".utf8)
        XCTAssertEqual(String(decoding: TerminalQueryFilter.strip(data), as: UTF8.self), "abc")
    }

    /// A trailing partial sequence must be forwarded, not swallowed: holding
    /// bytes back would stall the render whenever a chunk happens to end
    /// mid-escape and no further output arrives.
    func testTruncatedSequenceAtEndOfChunkIsForwarded() {
        for partial in ["\u{1B}", "\u{1B}[", "\u{1B}[6", "\u{1B}]11;", "\u{1B}P$q"] {
            let data = Data("x".utf8) + Data(partial.utf8)
            XCTAssertEqual(TerminalQueryFilter.strip(data), data,
                           "partial \(partial.debugDescription) must pass through")
        }
    }

    /// Documented residual: the filter is stateless, so a query split across two
    /// PTY reads is not recognised and reaches the device (which answers late,
    /// as before this fix). Programs write these tiny sequences in one `write`,
    /// so this is rare — and the outcome is the pre-fix behaviour, never worse.
    func testQuerySplitAcrossChunksIsNotRecognised() {
        let first = Data("\u{1B}[".utf8)
        let second = Data("6n".utf8)
        XCTAssertEqual(TerminalQueryFilter.strip(first), first)
        XCTAssertEqual(TerminalQueryFilter.strip(second), second)
    }
}
