import XCTest
import AppKit
// Module is c99-sanitized from PRODUCT_NAME "Code[Relay]" — see project.yml.
@testable import Code_Relay_

final class ModifierFlagsTests: XCTestCase {

    func testSymbolStringEmptyForNoModifiers() {
        let flags: NSEvent.ModifierFlags = []
        XCTAssertEqual(flags.symbolString, "")
    }

    func testSymbolStringOrderIsControlOptionShiftCommand() {
        let flags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        XCTAssertEqual(flags.symbolString, "⌃⌥⇧⌘")
    }

    func testSymbolStringSubsets() {
        XCTAssertEqual(NSEvent.ModifierFlags.command.symbolString, "⌘")
        XCTAssertEqual(NSEvent.ModifierFlags.option.symbolString, "⌥")
        XCTAssertEqual(NSEvent.ModifierFlags([.command, .option]).symbolString, "⌥⌘")
        XCTAssertEqual(NSEvent.ModifierFlags([.shift, .command]).symbolString, "⇧⌘")
    }

    @MainActor
    func testShortcutDisplayStringCombinesModsAndKey() {
        let settings = AppSettings.shared
        let originalMods = settings.recordingShortcutModifiers
        let originalKey = settings.recordingShortcutKey
        defer {
            settings.recordingShortcutModifiers = originalMods
            settings.recordingShortcutKey = originalKey
        }

        settings.shortcutModifierFlags = [.command, .option]
        settings.recordingShortcutKey = "r"
        XCTAssertEqual(settings.shortcutDisplayString, "⌥⌘R")
    }

    @MainActor
    func testShortcutDisplayStringEmptyKey() {
        let settings = AppSettings.shared
        let originalMods = settings.recordingShortcutModifiers
        let originalKey = settings.recordingShortcutKey
        defer {
            settings.recordingShortcutModifiers = originalMods
            settings.recordingShortcutKey = originalKey
        }

        settings.shortcutModifierFlags = [.command]
        settings.recordingShortcutKey = ""
        XCTAssertEqual(settings.shortcutDisplayString, "⌘")
    }
}
