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
}
