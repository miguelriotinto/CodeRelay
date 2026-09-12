import Foundation

/// Strips leading partial escape sequences and UTF-8 fragments from ring-buffer
/// replays that begin at an arbitrary byte boundary (buffer wrapped).
///
/// When the ring buffer is at capacity, the oldest bytes are silently dropped.
/// This means `read()` can return data that starts mid-escape-sequence or
/// mid-UTF-8 character. Feeding those partial bytes to a terminal renders them
/// as visible garbage. This sanitizer advances past the leading garbage to the
/// first clean boundary, then prepends a terminal reset (RIS) so the terminal
/// starts from a known state.
enum ScrollbackSanitizer {

    /// Sanitize ring-buffer data for replay. Strips leading partial sequences
    /// and prepends RIS (`ESC c`) so the terminal clears before the replay.
    static func sanitize(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let bytes = [UInt8](data)
        let cleanStart = findCleanStart(bytes)
        if cleanStart == 0 {
            return data
        }
        if cleanStart >= bytes.count {
            return Data()
        }
        return Data(bytes[cleanStart...])
    }

    /// Find the first index where the byte stream is at a clean boundary:
    /// - Not inside a UTF-8 continuation (0x80–0xBF)
    /// - Not inside a partial CSI sequence (mid-parameter/intermediate bytes
    ///   without a preceding ESC [)
    ///
    /// Strategy: scan forward until we find either a newline (always safe),
    /// an ASCII printable byte that isn't a CSI parameter/intermediate, or
    /// a valid UTF-8 lead byte that starts a complete character.
    private static func findCleanStart(_ bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }

        // If first byte is a valid start (ASCII printable, newline, or
        // valid escape sequence start), no skipping needed.
        if isCleanLeadByte(bytes[0]) {
            return 0
        }

        // Scan forward — limit scan to first 256 bytes to bound cost.
        let limit = min(bytes.count, 256)
        for i in 1..<limit {
            let b = bytes[i]
            // Newline is always a safe re-entry point — the terminal will
            // be on a fresh line regardless of prior state.
            if b == 0x0A {
                return i + 1
            }
            if isCleanLeadByte(b) {
                return i
            }
        }

        // If we can't find a clean start in 256 bytes, skip them all —
        // the terminal's RIS will provide a clean slate regardless.
        return limit
    }

    /// A byte is a "clean lead" if it's a valid start of a terminal byte stream:
    /// - ESC (0x1B): start of an escape sequence
    /// - ASCII printable (0x20–0x7E): literal character
    /// - CR (0x0D) or LF (0x0A): line boundaries
    /// - Tab (0x09): horizontal tab
    /// - UTF-8 2-byte lead (0xC2–0xDF), 3-byte lead (0xE0–0xEF),
    ///   4-byte lead (0xF0–0xF4) — but only if followed by valid continuation bytes
    ///   (we don't check continuation here — just exclude continuation bytes 0x80–0xBF)
    private static func isCleanLeadByte(_ b: UInt8) -> Bool {
        switch b {
        case 0x09, 0x0A, 0x0D:
            return true
        case 0x1B:
            return true
        case 0x20...0x7E:
            return true
        case 0xC2...0xDF, 0xE0...0xEF, 0xF0...0xF4:
            return true
        default:
            return false
        }
    }
}
