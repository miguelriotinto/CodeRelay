import XCTest
import SwiftTerm
@testable import CodeRelayClient
@testable import CodeRelayKit

/// Drives a headless SwiftTerm `Terminal` with real bytes, so the cell → link
/// lookup both apps use is tested without a simulator.
final class TerminalLinkResolverTests: XCTestCase {
    private final class NullDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    private let delegate = NullDelegate()

    private func terminal(cols: Int = 40, rows: Int = 6, _ output: String) -> Terminal {
        let t = Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows))
        t.feed(text: output)
        return t
    }

    private func osc8(_ url: String, _ text: String) -> String {
        "\u{1b}]8;id=a;\(url)\u{07}\(text)\u{1b}]8;;\u{07}"
    }

    func testPlainURLIsImplicitAndOpens() throws {
        let t = terminal("see https://example.com/a for it")
        let hit = try XCTUnwrap(TerminalLinkResolver.link(in: t, col: 10, row: 0))
        XCTAssertEqual(hit.source, .implicit)
        XCTAssertEqual(hit.decision, .open(URL(string: "https://example.com/a")!))
    }

    func testTextAwayFromTheURLHasNoLink() {
        let t = terminal("see https://example.com/a for it")
        XCTAssertNil(TerminalLinkResolver.link(in: t, col: 1, row: 0))
        XCTAssertNil(TerminalLinkResolver.link(in: t, col: 5, row: 3))
    }

    /// The shape Claude Code prints (probed 2026-11-18): an OSC 8 link whose
    /// text is its own target — opens without a prompt.
    func testClaudeStyleExplicitLinkOpens() throws {
        let url = "https://code.claude.com/docs/en/overview"
        let t = terminal(cols: 60, "For more help: " + osc8(url, url))
        let hit = try XCTUnwrap(TerminalLinkResolver.link(in: t, col: 20, row: 0))
        XCTAssertEqual(hit.source, .explicit)
        XCTAssertEqual(hit.visibleText, url)
        XCTAssertEqual(hit.decision, .open(URL(string: url)!))
    }

    func testExplicitLinkWithALabelConfirms() throws {
        let t = terminal("read " + osc8("https://evil.example/x", "the docs") + " now")
        let hit = try XCTUnwrap(TerminalLinkResolver.link(in: t, col: 7, row: 0))
        XCTAssertEqual(hit.visibleText, "the docs")
        XCTAssertEqual(hit.decision, .confirm(URL(string: "https://evil.example/x")!))
    }

    /// A link wrapped onto a second row is still read whole from either row.
    func testExplicitLinkWrappedAcrossRowsReadsWhole() throws {
        let url = "https://example.com/" + String(repeating: "a", count: 30)   // 50 chars, 40 cols
        let t = terminal(osc8(url, url))
        let fromSecondRow = try XCTUnwrap(TerminalLinkResolver.link(in: t, col: 2, row: 1))
        XCTAssertEqual(fromSecondRow.visibleText, url)
        XCTAssertEqual(fromSecondRow.decision, .open(URL(string: url)!))
    }

    func testOwnDeepLinkIsRejected() throws {
        let link = "coderelay://pair?host=1.2.3.4&port=9200&tls=0&code=ABCDEFGH"
        let t = terminal(cols: 80, osc8(link, "click me"))
        let hit = try XCTUnwrap(TerminalLinkResolver.link(in: t, col: 2, row: 0))
        XCTAssertEqual(hit.decision, .reject)
    }

    /// macOS hands over the target alone; the cells carrying it decide.
    func testHitForTargetFindsTheExplicitRun() {
        let url = "https://code.claude.com/docs"
        let t = terminal(cols: 60, "x " + osc8(url, url) + " y " + osc8("https://evil.example", "label"))
        XCTAssertEqual(TerminalLinkResolver.hit(forTarget: url, in: t).decision, .open(URL(string: url)!))
        XCTAssertEqual(TerminalLinkResolver.hit(forTarget: "https://evil.example", in: t).decision,
                       .confirm(URL(string: "https://evil.example")!))
        // Not carried by a run and not on screen: unknown text, so it asks.
        XCTAssertEqual(TerminalLinkResolver.hit(forTarget: "https://plain.example", in: t).decision,
                       .confirm(URL(string: "https://plain.example")!))
        let plain = terminal("see https://plain.example/a")
        XCTAssertEqual(TerminalLinkResolver.hit(forTarget: "https://plain.example/a", in: plain).decision,
                       .open(URL(string: "https://plain.example/a")!))
    }

    /// The same target shown plainly AND hung on a label: without the click
    /// position the label could be what was clicked, so it must ask.
    func testHitForTargetFailsClosedWhenAnyRunHidesTheTarget() {
        let url = "https://evil.example/x"
        let t = terminal(cols: 60, osc8(url, url) + " " + osc8(url, "your bank"))
        XCTAssertEqual(TerminalLinkResolver.hit(forTarget: url, in: t).decision, .confirm(URL(string: url)!))
    }

    func testOutOfGridIsNil() {
        let t = terminal("https://example.com")
        XCTAssertNil(TerminalLinkResolver.link(in: t, col: -1, row: 0))
        XCTAssertNil(TerminalLinkResolver.link(in: t, col: 0, row: 99))
    }
}
