import XCTest
@testable import CodeRelayServer

final class ScrollbackSanitizerTests: XCTestCase {

    func testCleanDataPassesThrough() {
        let data = Data("Hello, world!\n".utf8)
        XCTAssertEqual(ScrollbackSanitizer.sanitize(data), data)
    }

    func testEmptyDataReturnsEmpty() {
        XCTAssertEqual(ScrollbackSanitizer.sanitize(Data()), Data())
    }

    func testLeadingUTF8ContinuationStripped() {
        // 0x80-0xBF are UTF-8 continuation bytes — invalid as lead
        var bytes: [UInt8] = [0x80, 0xBF, 0xA3]
        bytes.append(contentsOf: "Hello".utf8)
        let result = ScrollbackSanitizer.sanitize(Data(bytes))
        XCTAssertEqual(result, Data("Hello".utf8))
    }

    func testLeadingPartialCSIWithContinuationBytes() {
        // Start with UTF-8 continuation then printable — skips continuation
        var bytes: [UInt8] = [0x80, 0xBF] // continuation bytes
        bytes.append(contentsOf: "31m\nClean line".utf8)
        let result = ScrollbackSanitizer.sanitize(Data(bytes))
        // Skips continuations, lands on '3' (printable)
        XCTAssertEqual(result, Data("31m\nClean line".utf8))
    }

    func testStartingWithESCIsClean() {
        let bytes: [UInt8] = [0x1B, 0x5B, 0x33, 0x31, 0x6D] // ESC[31m (red)
        let data = Data(bytes)
        XCTAssertEqual(ScrollbackSanitizer.sanitize(data), data)
    }

    func testStartingWithASCIIPrintableIsClean() {
        let data = Data("normal text".utf8)
        XCTAssertEqual(ScrollbackSanitizer.sanitize(data), data)
    }

    func testStartingWithNewlineIsClean() {
        let data = Data("\nline after".utf8)
        XCTAssertEqual(ScrollbackSanitizer.sanitize(data), data)
    }

    func testContinuationBytesBeforeNewline() {
        // Continuation bytes then newline — skips to after newline
        var bytes: [UInt8] = [0x80, 0x91, 0xA5]
        bytes.append(0x0A) // newline
        bytes.append(contentsOf: "prompt$ ".utf8)
        let result = ScrollbackSanitizer.sanitize(Data(bytes))
        XCTAssertEqual(result, Data("prompt$ ".utf8))
    }

    func testAllGarbageReturnsEmpty() {
        // 256 continuation bytes with no clean start
        let bytes = [UInt8](repeating: 0x80, count: 256)
        let result = ScrollbackSanitizer.sanitize(Data(bytes))
        XCTAssertEqual(result, Data())
    }
}
