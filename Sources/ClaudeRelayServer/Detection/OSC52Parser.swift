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
/// **Stateful across reads.** PTY output arrives in arbitrary chunks capped at
/// 64 KB, so a single OSC 52 sequence — especially a large clipboard payload —
/// can and does span multiple reads. `feed(_:)` retains an in-progress sequence
/// in `pending` until its terminator arrives in a later chunk. A runaway
/// sequence that never terminates is abandoned once `pending` exceeds
/// `maxPendingBytes`, so a malformed stream can't grow the buffer unbounded.
///
/// Not thread-safe; owned by (and confined to) the `PTYSession` actor via
/// `SessionActivityMonitor`-style single-isolation access.
struct OSC52Parser {
    /// Cap on the decoded clipboard text. 1 MB of text is far beyond any real
    /// copy; larger writes are dropped.
    static let maxDecodedBytes = 1_000_000
    /// Cap on buffered in-progress sequence bytes across reads. Generous enough
    /// for a 1 MB decoded payload (~1.34 MB base64) plus the envelope, but
    /// bounded so an unterminated `ESC ] 52 ;…` can't grow memory forever.
    static let maxPendingBytes = 2_000_000

    /// Bytes of an OSC 52 sequence seen so far but not yet terminated, carried
    /// from a previous `feed`. Empty in steady state.
    private var pending: [UInt8] = []

    /// Feed a PTY output chunk; returns decoded clipboard writes completed by
    /// this chunk (usually empty). Retains a split sequence for the next call.
    mutating func feed(_ data: Data) -> [String] {
        // Fast path: nothing pending and no ESC in this chunk → can't contain
        // or start a sequence.
        if pending.isEmpty, data.firstIndex(of: 0x1B) == nil { return [] }

        var bytes = pending
        bytes.append(contentsOf: data)
        pending = []

        var results: [String] = []
        var consumedUpTo = 0   // index in `bytes` past the last fully-handled region
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x1B else { i += 1; continue }
            // Try to match an OSC 52 sequence starting at `i`. Three outcomes:
            // matched+terminated, matched-but-incomplete (retain from i), or
            // not-an-OSC52 (skip this ESC).
            switch matchAt(i, in: bytes) {
            case .completed(let text, let nextIndex):
                if let text { results.append(text) }
                i = nextIndex
                consumedUpTo = nextIndex
            case .incomplete:
                // Sequence started but no terminator yet — retain from `i` for
                // the next feed, unless it's grown past the cap (abandon it).
                let tail = Array(bytes[i...])
                pending = tail.count <= Self.maxPendingBytes ? tail : []
                return results
            case .notOSC52:
                i += 1
            }
        }
        _ = consumedUpTo
        return results
    }

    private enum MatchResult {
        case completed(text: String?, nextIndex: Int)   // text nil = ignored (read-req/invalid)
        case incomplete                                  // started, awaiting terminator
        case notOSC52                                    // ESC here isn't an OSC 52 intro
    }

    /// Attempt to parse an OSC 52 sequence at `start` (which is an ESC byte).
    private func matchAt(_ start: Int, in bytes: [UInt8]) -> MatchResult {
        // Need "ESC ] 5 2 ;" = 5 bytes. If the buffer ends mid-prefix, we can't
        // yet tell whether it's OSC 52 — treat as incomplete only if the bytes
        // seen so far are a viable prefix.
        let prefix: [UInt8] = [0x1B, 0x5D, 0x35, 0x32, 0x3B]  // ESC ] 5 2 ;
        var p = 0
        while p < prefix.count {
            let idx = start + p
            if idx >= bytes.count { return .incomplete }       // buffer ended mid-prefix
            if bytes[idx] != prefix[p] { return .notOSC52 }    // diverged → not OSC 52
            p += 1
        }

        // Selection field up to the next ';'. Bounded by a terminator so a
        // malformed sequence with no ';' isn't scanned forever.
        var selEnd = start + prefix.count
        while selEnd < bytes.count, bytes[selEnd] != 0x3B,
              bytes[selEnd] != 0x07, bytes[selEnd] != 0x1B {
            selEnd += 1
        }
        if selEnd >= bytes.count { return .incomplete }        // selection not finished
        guard bytes[selEnd] == 0x3B else { return .notOSC52 }  // hit BEL/ESC before ';'

        // Payload to terminator (BEL or ESC \).
        let payloadStart = selEnd + 1
        var payloadEnd = payloadStart
        while payloadEnd < bytes.count {
            if bytes[payloadEnd] == 0x07 {                     // BEL
                return .completed(text: decodePayload(bytes[payloadStart..<payloadEnd]),
                                  nextIndex: payloadEnd + 1)
            }
            if bytes[payloadEnd] == 0x1B {                     // ESC — maybe ST (ESC \)
                if payloadEnd + 1 >= bytes.count { return .incomplete }  // need next byte
                if bytes[payloadEnd + 1] == 0x5C {
                    return .completed(text: decodePayload(bytes[payloadStart..<payloadEnd]),
                                      nextIndex: payloadEnd + 2)
                }
                // A bare ESC that isn't ST cancels this OSC — not a clipboard write.
                return .notOSC52
            }
            payloadEnd += 1
        }
        return .incomplete                                     // no terminator yet
    }

    /// Decode a base64 OSC 52 payload to UTF-8, rejecting read-requests (`?`),
    /// oversize payloads, and undecodable/non-UTF-8 data.
    private func decodePayload(_ slice: ArraySlice<UInt8>) -> String? {
        if slice.count == 1, slice.first == 0x3F { return nil }   // '?' read request
        guard !slice.isEmpty,
              let b64 = String(bytes: slice, encoding: .ascii),
              let decoded = Data(base64Encoded: b64),
              decoded.count <= Self.maxDecodedBytes,
              let text = String(data: decoded, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    // MARK: - Pure convenience

    /// One-shot parse of a self-contained chunk (used by tests). Equivalent to a
    /// fresh parser fed once.
    static func parse(_ data: Data) -> [String] {
        var parser = OSC52Parser()
        return parser.feed(data)
    }
}
