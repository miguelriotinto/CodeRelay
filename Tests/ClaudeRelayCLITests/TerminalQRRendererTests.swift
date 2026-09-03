import XCTest
@testable import ClaudeRelayCLI

final class TerminalQRRendererTests: XCTestCase {

    private let payload = "coderelay://pair?host=silverwing.local&port=9200&tls=0&code=K7QP2M4X"

    func testMatrixIsSquareAndIncludesQuietZone() throws {
        let renderer = TerminalQRRenderer(quietZone: 2)
        let matrix = try XCTUnwrap(renderer.matrix(for: payload))
        XCTAssertFalse(matrix.isEmpty)
        for row in matrix {
            XCTAssertEqual(row.count, matrix.count, "matrix must be square")
        }
        // This payload at correction level M is QR version 5 = 37 modules.
        // CoreImage adds its own 1-module border, and quietZone=2 adds two
        // more each side: 37 + 1 + 1 + 2 + 2 = 43. A different number here
        // means the payload grew into a higher QR version.
        XCTAssertEqual(matrix.count, 43)
    }

    func testQuietZoneIsAllLightModules() throws {
        let renderer = TerminalQRRenderer(quietZone: 2)
        let matrix = try XCTUnwrap(renderer.matrix(for: payload))
        for row in matrix.prefix(2) {
            XCTAssertFalse(row.contains(true), "top quiet zone must be blank")
        }
        for row in matrix.suffix(2) {
            XCTAssertFalse(row.contains(true), "bottom quiet zone must be blank")
        }
        for row in matrix {
            XCTAssertFalse(row.prefix(2).contains(true), "left quiet zone must be blank")
            XCTAssertFalse(row.suffix(2).contains(true), "right quiet zone must be blank")
        }
    }

    func testMatrixIsDeterministic() throws {
        let renderer = TerminalQRRenderer()
        let first = try XCTUnwrap(renderer.matrix(for: payload))
        let second = try XCTUnwrap(renderer.matrix(for: payload))
        XCTAssertEqual(first, second)
    }

    func testFinderPatternPresentAtTopLeftOfDataArea() throws {
        let renderer = TerminalQRRenderer(quietZone: 2)
        let matrix = try XCTUnwrap(renderer.matrix(for: payload))
        // A QR finder pattern is a 7x7 dark border. CoreImage adds a 1-module
        // border on top of our quietZone=2, so the data area starts at (3,3).
        for offset in 3..<10 {
            XCTAssertTrue(matrix[3][offset], "top edge of finder pattern at col \(offset)")
            XCTAssertTrue(matrix[offset][3], "left edge of finder pattern at row \(offset)")
        }
        XCTAssertTrue(matrix[5][5], "finder pattern centre [5][5] should be dark")
        XCTAssertTrue(matrix[6][6], "finder pattern centre [6][6] should be dark")
    }

    func testRenderUsesHalfHeightRowsAndExplicitColours() throws {
        let renderer = TerminalQRRenderer(quietZone: 2)
        let matrix = try XCTUnwrap(renderer.matrix(for: payload))
        let output = try XCTUnwrap(renderer.render(payload))
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        // Half-block glyphs pack two module rows per text row.
        XCTAssertEqual(lines.count, (matrix.count + 1) / 2)
        // Explicit SGR colours: a dark terminal theme would otherwise invert
        // the modules and most scanners fail on an inverted QR.
        XCTAssertTrue(output.contains("\u{1B}[38;2;"), "expected explicit foreground colour")
        XCTAssertTrue(output.contains("\u{1B}[48;2;"), "expected explicit background colour")
        XCTAssertTrue(output.contains("\u{1B}[0m"), "expected SGR reset")
    }

    func testRenderReturnsNilForEmptyPayload() {
        XCTAssertNil(TerminalQRRenderer().render(""))
    }
}
