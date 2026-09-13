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
}
