import Foundation

/// Strips terminal *queries* out of PTY output before it leaves the server, so
/// the device never answers one.
///
/// A query travels host→device like any other output, and an emulator that sees
/// one answers it as input. On a local terminal that answer is instantaneous, so
/// the program that asked reads it. Across the relay it costs a WebSocket round
/// trip, by which time the asking program has usually stopped reading (short read
/// timeout, or it already exited) — so the shell's line editor receives it as
/// keystrokes and echoes the payload at the prompt. That is the reported
/// `11;rgb:0000/0000/0000` garbage, minted by the device's own SwiftTerm from the
/// background colour the app forces to black.
///
/// The server answers instead, from the emulator it already feeds
/// (`TerminalScreenModel.feed`), which costs no round trip — the tmux/mosh model.
/// Because both ends run the *same* SwiftTerm, the server's answer is exactly the
/// answer the device would have given, so nothing is lost by stripping these.
///
/// Related, and pointed the other way: `EscapeResponseFilter` strips stale
/// *replies* out of a scrollback replay. That filter exists because queries used
/// to rot unanswered in the ring buffer of a detached session and get answered on
/// reattach — the same root cause, treated at the symptom. It stays as defence in
/// depth for buffers recorded before this fix.
///
/// Only sequences that are unambiguously queries *and* render nothing are
/// stripped. Sequences that merely share a final byte with one (SCORC `CSI u`,
/// DECSTR `CSI ! p`, title-stack `CSI 22 t`) are forwarded byte-exact.
enum TerminalQueryFilter {

    /// CSI final bytes that only ever introduce a query:
    ///   0x63 'c' — DA1/DA2/DA3 (Device Attributes request)
    ///   0x6E 'n' — DSR/DECDSR  (Device Status Report request)
    private static let queryFinalBytes: Set<UInt8> = [0x63, 0x6E]

    /// XTWINOPS parameters that ask for a *report*. The rest of the `t` ops are
    /// real commands (1 de-iconify, 22/23 push/pop title, …) and must survive.
    private static let windowReportOps: Set<Int> = [13, 14, 15, 16, 18, 19, 20, 21]

    /// Return `data` with query sequences removed. Pure; allocates nothing when
    /// the chunk holds no query, which is the overwhelmingly common case on the
    /// hot output path.
    static func strip(_ data: Data) -> Data {
        guard data.count >= 2 else { return data }

        let bytes = [UInt8](data)
        // Built lazily: stays nil until the first strip, so a chunk with no
        // query is returned as-is.
        var filtered: [UInt8]?

        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x1B, i + 1 < bytes.count,
                  let end = queryRange(bytes, from: i) else {
                filtered?.append(bytes[i])
                i += 1
                continue
            }
            if filtered == nil {
                filtered = Array(bytes[0..<i])
                filtered?.reserveCapacity(bytes.count)
            }
            i = end
        }
        guard let filtered else { return data }
        return Data(filtered)
    }

    /// If a query starts at `start` (an ESC), return the index just past it.
    /// `nil` means "not a query" — including a sequence truncated by the end of
    /// the chunk, which must be forwarded rather than held back: withholding it
    /// would stall the render whenever a read happens to end mid-escape.
    private static func queryRange(_ bytes: [UInt8], from start: Int) -> Int? {
        switch bytes[start + 1] {
        case 0x5B: return csiQueryRange(bytes, from: start)   // ESC [
        case 0x5D: return oscQueryRange(bytes, from: start)   // ESC ]
        case 0x50: return dcsQueryRange(bytes, from: start)   // ESC P
        default: return nil
        }
    }

    private static func csiQueryRange(_ bytes: [UInt8], from start: Int) -> Int? {
        var j = start + 2
        var hasPrivateMarker = false     // '?' — kitty's query, vs SCORC
        var hasDollarIntermediate = false // '$' — DECRQM, vs DECSTR
        // Only the FIRST parameter selects the operation (XTWINOPS `14t` vs
        // `22t`); later ones are arguments, so digits stop counting at the ';'.
        var firstParam: Int?
        var inFirstParam = true

        // Parameter bytes (0x30–0x3F) then intermediates (0x20–0x2F).
        while j < bytes.count,
              (bytes[j] >= 0x30 && bytes[j] <= 0x3F) || (bytes[j] >= 0x20 && bytes[j] <= 0x2F) {
            switch bytes[j] {
            case 0x3F: hasPrivateMarker = true
            case 0x24: hasDollarIntermediate = true
            case 0x3B: inFirstParam = false
            case 0x30...0x39 where inFirstParam:
                firstParam = (firstParam ?? 0) * 10 + Int(bytes[j] - 0x30)
            default: break
            }
            j += 1
        }

        guard j < bytes.count, bytes[j] >= 0x40, bytes[j] <= 0x7E else { return nil }

        let isQuery: Bool
        switch bytes[j] {
        case let final where queryFinalBytes.contains(final):
            isQuery = true
        case 0x70:  // 'p' — DECRQM only with the '$' intermediate (else DECSTR/DECSCL)
            isQuery = hasDollarIntermediate
        case 0x75:  // 'u' — kitty keyboard query only with '?' (else SCORC)
            isQuery = hasPrivateMarker
        case 0x74:  // 't' — XTWINOPS: reports only, never the window commands
            isQuery = firstParam.map(windowReportOps.contains) ?? false
        default:
            isQuery = false
        }
        return isQuery ? j + 1 : nil
    }

    /// OSC is a query when its LAST `;`-separated field is a lone `?`:
    /// `OSC 11 ; ?` (background), `OSC 4 ; 1 ; ?` (palette), `OSC 52 ; c ; ?`
    /// (clipboard read). A `?` merely *inside* a payload — a window title ending
    /// in a question mark — is not.
    private static func oscQueryRange(_ bytes: [UInt8], from start: Int) -> Int? {
        var j = start + 2
        let payloadStart = j
        while j < bytes.count {
            let terminatorLength: Int
            if bytes[j] == 0x07 {
                terminatorLength = 1
            } else if bytes[j] == 0x1B, j + 1 < bytes.count, bytes[j + 1] == 0x5C {
                terminatorLength = 2
            } else {
                j += 1
                continue
            }
            // A lone '?' as the final field: the byte before the terminator is
            // '?' and the one before that is the ';' that opened the field.
            guard j - payloadStart >= 2, bytes[j - 1] == 0x3F, bytes[j - 2] == 0x3B else {
                return nil
            }
            return j + terminatorLength
        }
        return nil  // unterminated — forward it; the rest may arrive next read
    }

    /// DCS requests: DECRQSS (`ESC P $ q … ST`) and XTGETTCAP (`ESC P + q … ST`).
    private static func dcsQueryRange(_ bytes: [UInt8], from start: Int) -> Int? {
        let j = start + 2
        guard j + 1 < bytes.count, bytes[j] == 0x24 || bytes[j] == 0x2B, bytes[j + 1] == 0x71 else {
            return nil  // not `$q` / `+q`
        }
        var k = j + 2
        while k < bytes.count {
            if bytes[k] == 0x07 { return k + 1 }
            if bytes[k] == 0x1B, k + 1 < bytes.count, bytes[k + 1] == 0x5C { return k + 2 }
            k += 1
        }
        return nil  // unterminated — forward it
    }
}
