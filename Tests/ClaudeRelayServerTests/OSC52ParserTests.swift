import XCTest
import Foundation
@testable import ClaudeRelayServer

final class OSC52ParserTests: XCTestCase {

    /// Build an OSC 52 clipboard-write sequence for `text` with the given
    /// selection field and terminator.
    private func osc52(_ text: String, selection: String = "c", useST: Bool = false) -> Data {
        let b64 = Data(text.utf8).base64EncodedString()
        let terminator = useST ? "\u{1B}\\" : "\u{07}"
        return Data("\u{1B}]52;\(selection);\(b64)\(terminator)".utf8)
    }

    func testParsesClipboardWriteWithBEL() {
        XCTAssertEqual(OSC52Parser.parse(osc52("hello world")), ["hello world"])
    }

    func testParsesClipboardWriteWithST() {
        XCTAssertEqual(OSC52Parser.parse(osc52("via ST", useST: true)), ["via ST"])
    }

    func testParsesEmbeddedInSurroundingOutput() {
        var data = Data("some terminal output\r\n".utf8)
        data.append(osc52("copied text"))
        data.append(Data("more output".utf8))
        XCTAssertEqual(OSC52Parser.parse(data), ["copied text"])
    }

    func testParsesMultipleSequencesInOrder() {
        var data = osc52("first")
        data.append(osc52("second"))
        XCTAssertEqual(OSC52Parser.parse(data), ["first", "second"])
    }

    func testAcceptsNonClipboardSelection() {
        // primary selection ("p") is still a clipboard write we mirror.
        XCTAssertEqual(OSC52Parser.parse(osc52("primary", selection: "p")), ["primary"])
    }

    func testIgnoresReadRequest() {
        // "?" payload is a clipboard READ request — must not be mirrored.
        let data = Data("\u{1B}]52;c;?\u{07}".utf8)
        XCTAssertEqual(OSC52Parser.parse(data), [])
    }

    func testIgnoresNonOSC52Sequences() {
        // OSC title (0) and other OSC codes must not match.
        let title = Data("\u{1B}]0;my title\u{07}".utf8)
        XCTAssertEqual(OSC52Parser.parse(title), [])
        let other = Data("\u{1B}]4;1;rgb:00/00/00\u{07}".utf8)
        XCTAssertEqual(OSC52Parser.parse(other), [])
    }

    func testNoESCShortCircuits() {
        XCTAssertEqual(OSC52Parser.parse(Data("plain output, no escapes".utf8)), [])
    }

    func testDropsUnterminatedSequence() {
        // Split across a chunk boundary — no terminator yet → drop, don't emit partial.
        let b64 = Data("incomplete".utf8).base64EncodedString()
        let data = Data("\u{1B}]52;c;\(b64)".utf8)   // no BEL/ST
        XCTAssertEqual(OSC52Parser.parse(data), [])
    }

    func testDropsInvalidBase64() {
        let data = Data("\u{1B}]52;c;!!!not-base64!!!\u{07}".utf8)
        XCTAssertEqual(OSC52Parser.parse(data), [])
    }

    func testDropsEmptyPayload() {
        let data = Data("\u{1B}]52;c;\u{07}".utf8)
        XCTAssertEqual(OSC52Parser.parse(data), [])
    }

    func testDropsOversizeDecodedPayload() {
        let big = String(repeating: "A", count: OSC52Parser.maxDecodedBytes + 1)
        XCTAssertEqual(OSC52Parser.parse(osc52(big)), [], "payload over the cap must be dropped")
    }

    func testUnicodeRoundTrips() {
        XCTAssertEqual(OSC52Parser.parse(osc52("café — 日本語 🎉")), ["café — 日本語 🎉"])
    }

    // MARK: - Stateful: sequences split across PTY reads (Codex review)

    /// Feed a full OSC 52 sequence one byte at a time; the completed write must
    /// emerge exactly once, on the read carrying the terminator.
    func testSequenceSplitByteByByte() {
        var parser = OSC52Parser()
        let seq = osc52("split across reads")
        var results: [String] = []
        for byte in seq {
            results += parser.feed(Data([byte]))
        }
        XCTAssertEqual(results, ["split across reads"])
    }

    /// Split at a few representative boundaries (mid-prefix, mid-selection,
    /// mid-payload, just before the terminator).
    func testSequenceSplitAtVariousBoundaries() {
        let seq = [UInt8](osc52("boundary test payload"))
        for cut in [2, 4, 6, 10, seq.count - 1] {
            var parser = OSC52Parser()
            var results = parser.feed(Data(seq[0..<cut]))
            XCTAssertTrue(results.isEmpty, "no emit before terminator (cut=\(cut))")
            results += parser.feed(Data(seq[cut...]))
            XCTAssertEqual(results, ["boundary test payload"], "cut=\(cut)")
        }
    }

    /// A large payload that necessarily spans multiple 64 KB-ish reads.
    func testLargePayloadSpanningReads() {
        let text = String(repeating: "x", count: 200_000)  // > one PTY read
        let seq = [UInt8](osc52(text))
        var parser = OSC52Parser()
        var results: [String] = []
        var offset = 0
        while offset < seq.count {
            let end = min(offset + 65_536, seq.count)
            results += parser.feed(Data(seq[offset..<end]))
            offset = end
        }
        XCTAssertEqual(results, [text])
    }

    /// ST (ESC \) terminator split between its two bytes across reads.
    func testSTTerminatorSplitAcrossReads() {
        let seq = [UInt8](osc52("st split", useST: true))
        var parser = OSC52Parser()
        // Cut right after the ESC of the ESC-\ terminator.
        let cut = seq.count - 1
        var results = parser.feed(Data(seq[0..<cut]))
        XCTAssertTrue(results.isEmpty)
        results += parser.feed(Data(seq[cut...]))
        XCTAssertEqual(results, ["st split"])
    }

    /// An unterminated sequence that exceeds the pending cap is abandoned, and
    /// the parser recovers for the next valid sequence.
    func testRunawaySequenceAbandonedThenRecovers() {
        var parser = OSC52Parser()
        // Start a sequence and feed a huge unterminated payload (> cap).
        var runaway = Data("\u{1B}]52;c;".utf8)
        runaway.append(Data(repeating: 0x41, count: OSC52Parser.maxPendingBytes + 10))  // 'A'…
        XCTAssertEqual(parser.feed(runaway), [])
        // A subsequent well-formed sequence still parses (buffer was reset).
        XCTAssertEqual(parser.feed(osc52("recovered")), ["recovered"])
    }

    /// Two sequences, the second split across the boundary, in one stream.
    func testMixedCompleteAndSplit() {
        let first = [UInt8](osc52("first"))
        let second = [UInt8](osc52("second"))
        var parser = OSC52Parser()
        // Chunk 1: all of first + half of second.
        let half = second.count / 2
        var chunk1 = first; chunk1.append(contentsOf: second[0..<half])
        XCTAssertEqual(parser.feed(Data(chunk1)), ["first"])
        // Chunk 2: rest of second.
        XCTAssertEqual(parser.feed(Data(second[half...])), ["second"])
    }
}
