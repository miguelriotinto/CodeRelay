import Foundation

/// Parses OSC 52 clipboard-write sequences out of a PTY output stream (F11).
///
/// OSC 52 is the terminal-native "set clipboard" protocol used by tmux, vim,
/// kitty, and others — `ESC ] 52 ; <selection> ; <base64> BEL` (or an
/// `ESC \` string-terminator). The `<selection>` field is one or more of
/// `c`/`p`/`s`/`0`-`7` (clipboard/primary/select/cut-buffers); we accept any
/// non-empty selection and treat it as a clipboard write. A payload of `?` is a
/// clipboard *read request* (the app asking the terminal for the current
/// clipboard) — we ignore those, since honoring a read would leak the device
/// clipboard into the session, which the user didn't ask for.
///
/// Pure value type so the byte-level state machine is unit-testable without a
/// PTY. Mirrors the OSC-title scan in `SessionActivityMonitor` but decodes the
/// base64 payload and enforces a size cap.
struct OSC52Parser {
    /// Cap on the decoded clipboard text (defensive: a malicious/huge OSC 52
    /// payload must not balloon memory or the outbound frame). 1 MB of text is
    /// far beyond any real copy; larger writes are dropped.
    static let maxDecodedBytes = 1_000_000

    /// Scan `data` for OSC 52 clipboard writes and return the decoded UTF-8
    /// clipboard strings, in order. Empty when there are none. A chunk with no
    /// ESC byte can't contain a sequence — cheap short-circuit on the hot path.
    static func parse(_ data: Data) -> [String] {
        guard data.firstIndex(of: 0x1B) != nil else { return [] }
        let bytes = [UInt8](data)
        var results: [String] = []
        var i = 0
        // Need at least: ESC ] 5 2 ; <sel> ; <payload> BEL
        while i + 5 < bytes.count {
            // ESC ]
            guard bytes[i] == 0x1B, bytes[i + 1] == 0x5D else { i += 1; continue }
            // "52;"  ('5'=0x35, '2'=0x32, ';'=0x3B)
            guard bytes[i + 2] == 0x35, bytes[i + 3] == 0x32, bytes[i + 4] == 0x3B else { i += 1; continue }

            // Selection field: bytes up to the next ';'. Bounded so a malformed
            // sequence with no second ';' doesn't scan to end-of-buffer.
            var selEnd = i + 5
            while selEnd < bytes.count, bytes[selEnd] != 0x3B,
                  bytes[selEnd] != 0x07, bytes[selEnd] != 0x1B {
                selEnd += 1
            }
            guard selEnd < bytes.count, bytes[selEnd] == 0x3B else { i += 1; continue }

            // Payload: from after the second ';' to the terminator (BEL or ESC \).
            let payloadStart = selEnd + 1
            var payloadEnd = payloadStart
            var terminated = false
            while payloadEnd < bytes.count {
                if bytes[payloadEnd] == 0x07 { terminated = true; break }            // BEL
                if bytes[payloadEnd] == 0x1B, payloadEnd + 1 < bytes.count,
                   bytes[payloadEnd + 1] == 0x5C { terminated = true; break }         // ESC \ (ST)
                payloadEnd += 1
            }
            // Unterminated (sequence split across chunks): stop — don't emit a
            // partial. A future chunk carrying the rest won't re-match here, so
            // split OSC 52 across reads is intentionally dropped rather than
            // mis-decoded. Real writes arrive in a single PTY read.
            guard terminated else { break }

            if let text = decodePayload(bytes[payloadStart..<payloadEnd]) {
                results.append(text)
            }
            // Advance past the terminator (BEL = 1 byte, ESC \ = 2).
            i = (bytes[payloadEnd] == 0x07) ? payloadEnd + 1 : payloadEnd + 2
        }
        return results
    }

    /// Decode a base64 OSC 52 payload to UTF-8, rejecting read-requests (`?`),
    /// oversize payloads, and undecodable/non-UTF-8 data.
    private static func decodePayload(_ slice: ArraySlice<UInt8>) -> String? {
        // A single '?' is a clipboard read request — ignore (see type doc).
        if slice.count == 1, slice.first == 0x3F { return nil }
        guard !slice.isEmpty,
              let b64 = String(bytes: slice, encoding: .ascii),
              let decoded = Data(base64Encoded: b64),
              decoded.count <= maxDecodedBytes,
              let text = String(data: decoded, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }
        return text
    }
}
