// Tests/CodeRelayServerTests/DraftReplacerTests.swift
import XCTest
import SwiftTerm
@testable import CodeRelayServer

final class DraftReplacerTests: XCTestCase {
    private let esc = "\u{1B}"

    private func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func testLegacyDialectUsesDELAndCSI3Tilde() {
        let out = DraftReplacer.bytes(replacing: "abc", with: "xy", bracketedPaste: false, keyboardFlags: [])
        XCTAssertEqual(string(out), "\u{7F}\u{7F}\u{7F}" + "\(esc)[3~\(esc)[3~\(esc)[3~" + "xy")
    }

    func testKittyReportAllKeysUsesCSI127u() {
        let out = DraftReplacer.bytes(replacing: "ab", with: "z", bracketedPaste: false,
                                      keyboardFlags: [.disambiguate, .reportAllKeys])
        XCTAssertEqual(string(out), "\(esc)[127u\(esc)[127u" + "\(esc)[3~\(esc)[3~" + "z")
    }

    func testKittyDisambiguateOnlyKeepsLegacyBackspace() {
        let out = DraftReplacer.bytes(replacing: "a", with: "z", bracketedPaste: false,
                                      keyboardFlags: [.disambiguate])
        XCTAssertEqual(string(out), "\u{7F}" + "\(esc)[3~" + "z")
    }

    func testCountsUTF16CodeUnitsLikeInk() {
        // "a😀" is 2 characters but 3 UTF-16 code units; Ink's input treats
        // the surrogate pair as two cells.
        let out = DraftReplacer.bytes(replacing: "a😀", with: "", bracketedPaste: false, keyboardFlags: [])
        XCTAssertEqual(out.filter { $0 == 0x7F }.count, 3)
    }

    func testBracketedPasteWrapsTextVerbatim() {
        let out = DraftReplacer.bytes(replacing: "", with: "line1\nline2", bracketedPaste: true, keyboardFlags: [])
        XCTAssertEqual(string(out), "\(esc)[200~line1\nline2\(esc)[201~")
    }

    func testWithoutBracketedPasteNewlinesBecomeSpaces() {
        let out = DraftReplacer.bytes(replacing: "", with: "a\r\nb\nc\rd", bracketedPaste: false, keyboardFlags: [])
        XCTAssertEqual(string(out), "a b c d")
    }

    func testEmptyDraftEmitsNoErasure() {
        let out = DraftReplacer.bytes(replacing: "", with: "hi", bracketedPaste: false, keyboardFlags: [])
        XCTAssertEqual(string(out), "hi")
    }

    func testBracketedPasteStripsEscapeSoPasteEndCannotBeForged() {
        let out = DraftReplacer.bytes(replacing: "", with: "a\u{1B}[201~\rb", bracketedPaste: true, keyboardFlags: [])
        XCTAssertEqual(string(out), "\(esc)[200~a[201~\rb\(esc)[201~")
        let escCount = out.filter { $0 == 0x1B }.count
        XCTAssertEqual(escCount, 2, "Only the wrapper ESCs should remain")
    }

    func testControlBytesAreStrippedButTabAndNewlinesSurviveInsideBracket() {
        let out = DraftReplacer.bytes(replacing: "", with: "x\u{07}\u{00}\ty\n\u{7F}z", bracketedPaste: true, keyboardFlags: [])
        XCTAssertEqual(string(out), "\(esc)[200~x\ty\nz\(esc)[201~")
    }

    func testFlatPathAlsoStripsEscape() {
        let out = DraftReplacer.bytes(replacing: "", with: "a\u{1B}[3~b\rc", bracketedPaste: false, keyboardFlags: [])
        XCTAssertEqual(string(out), "a[3~b c")
    }

    /// End-to-end against the real mirror: type "hello world", move the cursor
    /// five left, then feed the replacer's own bytes back through `KeyDecoder`
    /// into the tracker. BS×11 eats everything left of the cursor and stops at
    /// the line start; DEL×11 eats everything right of it — the asymmetry is why
    /// the replacer emits both counts instead of one.
    func testReplacementRoundTripsThroughDecoderAndTracker() {
        var tracker = DraftTracker(profile: .default, columns: 80)
        tracker.apply(.text("hello world"))
        for _ in 0..<5 { tracker.apply(.left) }
        XCTAssertEqual(tracker.draft, "hello world")
        XCTAssertEqual(tracker.cursor, 6)
        XCTAssertFalse(tracker.cursorUncertain)

        let out = DraftReplacer.bytes(replacing: tracker.draft, with: "new",
                                      bracketedPaste: false, keyboardFlags: [])
        var decoder = KeyDecoder()
        tracker.apply(contentsOf: decoder.decode(out))
        XCTAssertEqual(tracker.draft, "new")
        XCTAssertEqual(tracker.cursor, 3)
    }

    // MARK: G2 — the text the replacer actually types

    /// `adopt` is given `effectiveText`, not the raw text: without bracketed paste
    /// a `\r\n` becomes ONE space, so adopting the raw text would leave the mirror
    /// one scalar longer than the real line.
    func testEffectiveTextFoldsNewlinesWithoutBracketedPaste() {
        XCTAssertEqual(DraftReplacer.effectiveText("a\r\nb", bracketedPaste: false), "a b")
        XCTAssertEqual(DraftReplacer.effectiveText("a\nb\rc", bracketedPaste: false), "a b c")
    }

    /// H1: outside a bracketed paste a raw 0x09 is expand-or-complete in zsh and
    /// in the agents' input boxes, so it cannot be *typed* — the real line grows
    /// past what was sent while the mirror still holds the pre-completion text.
    /// Same failure mode as a newline, so the same fold.
    func testEffectiveTextFoldsTabWithoutBracketedPaste() {
        XCTAssertEqual(DraftReplacer.effectiveText("a\tb", bracketedPaste: false), "a b")
        XCTAssertEqual(DraftReplacer.effectiveText("a\t\tb", bracketedPaste: false), "a  b")
    }

    /// Inside the paste bracket the tab is inert literal text — no fold there.
    func testEffectiveTextKeepsTabInsideBracketedPaste() {
        XCTAssertEqual(DraftReplacer.effectiveText("a\tb", bracketedPaste: true), "a\tb")
    }

    /// The emitted payload carries the fold too, so `bytes` and the adopted text
    /// still agree (`bytes` routes through `effectiveText`).
    func testBytesEmitNoTabWithoutBracketedPaste() {
        let out = DraftReplacer.bytes(replacing: "", with: "a\tb", bracketedPaste: false, keyboardFlags: [])
        XCTAssertEqual(string(out), "a b")
        XCTAssertFalse(out.contains(0x09), "a typed tab would trigger completion at the input line")
    }

    func testEffectiveTextKeepsNewlinesInsideBracketedPaste() {
        XCTAssertEqual(DraftReplacer.effectiveText("a\nb", bracketedPaste: true), "a\nb")
    }

    func testEffectiveTextDropsControlBytes() {
        XCTAssertEqual(DraftReplacer.effectiveText("x\u{07}\u{00}\ty\u{7F}z", bracketedPaste: true), "x\tyz")
    }

    /// The pasted tail of `bytes` is exactly `effectiveText`, so the two cannot
    /// drift apart.
    func testBytesPasteExactlyTheEffectiveText() {
        let text = "a\r\nb\u{07}c"
        let flat = DraftReplacer.effectiveText(text, bracketedPaste: false)
        XCTAssertEqual(string(DraftReplacer.bytes(replacing: "", with: text,
                                                 bracketedPaste: false, keyboardFlags: [])), flat)
        let wrapped = DraftReplacer.effectiveText(text, bracketedPaste: true)
        XCTAssertEqual(string(DraftReplacer.bytes(replacing: "", with: text,
                                                 bracketedPaste: true, keyboardFlags: [])),
                       "\(esc)[200~" + wrapped + "\(esc)[201~")
    }
}
