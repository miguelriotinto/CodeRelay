// Sources/CodeRelayServer/Prompt/DraftReplacer.swift
import Foundation
import SwiftTerm

/// Builds the input bytes that erase the current draft and type a replacement
/// at the agent's input line, in the dialect the foreground program
/// negotiated with the terminal. Never submits: no CR/LF is ever emitted, and
/// control bytes are stripped from the replacement so a model reply cannot
/// forge terminal sequences or break out of the paste bracket.
///
/// Erasure is Backspace×N then Delete×N (N = UTF-16 count) so the draft is
/// removed wherever the cursor sits; the extra keys are no-ops at either end.
/// Ink-based agents count UTF-16 code units, hence that unit rather than
/// characters or scalars.
///
/// **Except in canonical mode.** When the foreground program reads the line
/// through the tty's line discipline (`ICANON` — `cat`, a script's `read`), the
/// discipline honours Backspace as VERASE but knows nothing about `ESC [ 3 ~`:
/// those four bytes are *inserted* into the line, N times, and then delivered to
/// the program on Enter. Backspace×N alone is sufficient there because canonical
/// mode has no intra-line cursor to leave a tail behind (review A-7).
enum DraftReplacer {
    private static let legacyBackspace: [UInt8] = [0x7F]
    /// kitty `CSI 127 u`, used only when the program asked for *all* keys as
    /// escape codes; with lesser kitty flags Backspace stays the legacy byte.
    private static let kittyBackspace: [UInt8] = Array("\u{1B}[127u".utf8)
    private static let deleteKey: [UInt8] = Array("\u{1B}[3~".utf8)
    private static let pasteStart: [UInt8] = Array("\u{1B}[200~".utf8)
    private static let pasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)

    /// Strips control bytes from the replacement text so a model reply (or
    /// prompt injection via shared screen) cannot forge CSI/OSC sequences.
    /// ESC starts CSI and OSC; a literal `ESC [ 201 ~` in the text would end
    /// the paste bracket and let a CR submit. Preserves tab, newline, and CR
    /// (folding happens later for the non-bracketed path).
    private static func sanitized(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            let value = scalar.value
            // Allow tab (U+0009), newline (U+000A), carriage return (U+000D).
            // Remove other C0 controls (U+0000–U+001F) and DEL (U+007F).
            if value == 0x09 || value == 0x0A || value == 0x0D { return true }
            if value <= 0x1F || value == 0x7F { return false }
            return true
        })
    }

    /// The text the replacement actually types: sanitized, and — without
    /// bracketed paste — folded to plain spaces wherever a byte would be read as
    /// a key rather than as text. Outside the paste bracket a newline submits and
    /// a tab is expand-or-complete (zsh and both agents' input boxes), so neither
    /// can be *typed* at all: sending one either sends the line or grows it with
    /// a completion the mirror never saw. Inside the bracket both are literal.
    ///
    /// This is what `DraftTracker.adopt` must be given: the raw text can differ
    /// from it in length (`\r\n` becomes one space) and in content (dropped
    /// control scalars), and a mirror that holds scalars the real input line does
    /// not mis-sizes the next erase.
    static func effectiveText(_ text: String, bracketedPaste: Bool) -> String {
        let sanitizedText = sanitized(text)
        guard !bracketedPaste else { return sanitizedText }
        return sanitizedText
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    /// - Parameter canonical: the tty is in canonical mode, so the Delete run is
    ///   omitted. Defaults to raw mode — the value is a property of the *pty*, so
    ///   only `PTYSession` can supply it (it reads `c_lflag` at replace time);
    ///   the default exists for tests and for callers that have no fd.
    static func bytes(replacing draft: String, with text: String,
                      bracketedPaste: Bool, keyboardFlags: KittyKeyboardFlags,
                      canonical: Bool = false) -> Data {
        // One source of truth for what gets typed, so `bytes` and the text the
        // caller adopts cannot drift apart.
        let payload = effectiveText(text, bracketedPaste: bracketedPaste)
        let count = draft.utf16.count
        let backspace = keyboardFlags.contains(.reportAllKeys) ? kittyBackspace : legacyBackspace
        var out = Data()
        out.reserveCapacity(count * (backspace.count + deleteKey.count) + payload.utf8.count + 12)
        for _ in 0..<count { out.append(contentsOf: backspace) }
        // Canonical mode: no Delete run. See the type comment — there it would be
        // N copies of a literal `^[[3~` in the line the program is about to read.
        if !canonical {
            for _ in 0..<count { out.append(contentsOf: deleteKey) }
        }
        if bracketedPaste {
            out.append(contentsOf: pasteStart)
            out.append(contentsOf: Array(payload.utf8))
            out.append(contentsOf: pasteEnd)
        } else {
            out.append(contentsOf: Array(payload.utf8))
        }
        return out
    }
}
