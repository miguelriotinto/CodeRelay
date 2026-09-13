// Sources/CodeRelayServer/Prompt/DraftReplacer.swift
import Foundation
import SwiftTerm

/// Builds the input bytes that erase the current draft and type a replacement
/// at the agent's input line, in the dialect the foreground program
/// negotiated with the terminal. Never submits: no CR/LF is ever emitted.
///
/// Erasure is Backspace×N then Delete×N (N = UTF-16 count) so the draft is
/// removed wherever the cursor sits; the extra keys are no-ops at either end.
/// Ink-based agents count UTF-16 code units, hence that unit rather than
/// characters or scalars.
enum DraftReplacer {
    private static let legacyBackspace: [UInt8] = [0x7F]
    /// kitty `CSI 127 u`, used only when the program asked for *all* keys as
    /// escape codes; with lesser kitty flags Backspace stays the legacy byte.
    private static let kittyBackspace: [UInt8] = Array("\u{1B}[127u".utf8)
    private static let deleteKey: [UInt8] = Array("\u{1B}[3~".utf8)
    private static let pasteStart: [UInt8] = Array("\u{1B}[200~".utf8)
    private static let pasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)

    static func bytes(replacing draft: String, with text: String,
                      bracketedPaste: Bool, keyboardFlags: KittyKeyboardFlags) -> Data {
        let count = draft.utf16.count
        let backspace = keyboardFlags.contains(.reportAllKeys) ? kittyBackspace : legacyBackspace
        var out = Data()
        out.reserveCapacity(count * (backspace.count + deleteKey.count) + text.utf8.count + 12)
        for _ in 0..<count { out.append(contentsOf: backspace) }
        for _ in 0..<count { out.append(contentsOf: deleteKey) }
        if bracketedPaste {
            out.append(contentsOf: pasteStart)
            out.append(contentsOf: Array(text.utf8))
            out.append(contentsOf: pasteEnd)
        } else {
            // Without bracketed paste a newline would submit; fold to one line.
            let flat = text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            out.append(contentsOf: Array(flat.utf8))
        }
        return out
    }
}
