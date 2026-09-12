import Foundation

/// Strips stale escape-sequence *responses* out of ring-buffer replays before
/// we hand them to the client.
///
/// Background: while a session is detached, anything the server's `fd` asked
/// of the tty (Device Attributes, cursor position, color queries, etc.) got
/// answered into the PTY's output stream and stored in the scrollback ring
/// buffer. On reattach, replaying those bytes verbatim would deliver stale
/// replies as input to the new terminal, which renders them as visible garbage
/// instead of consuming them. This filter drops the reply bytes; the live
/// terminal can issue fresh queries if it needs them.
///
/// Handles two classes of responses:
/// - **CSI** (`ESC [`) — DA, CPR, DSR, DECRPM, kitty keyboard protocol
/// - **OSC** (`ESC ]`) — color palette (4), foreground (10), background (11),
///   cursor color (12), highlight color (17), highlight foreground (19),
///   and kitty graphics (Gi) responses
enum EscapeResponseFilter {

    /// Final bytes of CSI responses we strip unconditionally:
    ///   0x63 'c' — DA   (Device Attributes)
    ///   0x52 'R' — CPR  (Cursor Position Report)
    ///   0x6E 'n' — DSR  (Device Status Report)
    ///   0x79 'y' — DECRPM (DEC Private Mode Report)
    private static let strippedFinalBytes: Set<UInt8> = [
        0x63, 0x52, 0x6E, 0x79
    ]

    /// Final bytes we strip ONLY when the CSI contains private-mode '?':
    ///   0x74 't' — XTWINOPS response (ESC[?…t), NOT title stack (ESC[Ps t)
    ///   0x75 'u' — Kitty keyboard response (ESC[?…u), NOT SCORC (ESC[u)
    private static let privateOnlyFinalBytes: Set<UInt8> = [
        0x74, 0x75
    ]

    /// OSC codes whose responses we strip. These are terminal query responses
    /// that render as garbage on replay.
    private static let strippedOSCCodes: Set<Int> = [
        4,   // color palette
        10,  // foreground color
        11,  // background color
        12,  // cursor color
        17,  // highlight color
        19,  // highlight foreground
    ]

    /// Return `data` with stale CSI and OSC response sequences removed. Pure
    /// function; safe to call from any context.
    static func filter(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }

        let bytes = [UInt8](data)
        var filtered = [UInt8]()
        filtered.reserveCapacity(bytes.count)

        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x1B, i + 1 < bytes.count else {
                filtered.append(bytes[i])
                i += 1
                continue
            }

            let next = bytes[i + 1]

            // CSI: ESC [
            if next == 0x5B {
                var j = i + 2
                var hasPrivateMarker = false
                while j < bytes.count && (
                    (bytes[j] >= 0x30 && bytes[j] <= 0x3F) ||
                    (bytes[j] >= 0x20 && bytes[j] <= 0x2F)
                ) {
                    if bytes[j] == 0x3F { hasPrivateMarker = true }
                    j += 1
                }
                if j < bytes.count && bytes[j] >= 0x40 && bytes[j] <= 0x7E {
                    let finalByte = bytes[j]
                    if strippedFinalBytes.contains(finalByte) ||
                       (hasPrivateMarker && privateOnlyFinalBytes.contains(finalByte)) {
                        i = j + 1
                        continue
                    }
                }
                filtered.append(bytes[i])
                i += 1
                continue
            }

            // OSC: ESC ]
            if next == 0x5D {
                if let end = skipOSCResponse(bytes, from: i) {
                    i = end
                    continue
                }
                filtered.append(bytes[i])
                i += 1
                continue
            }

            filtered.append(bytes[i])
            i += 1
        }
        return Data(filtered)
    }

    /// If the OSC starting at `from` is a response we should strip, returns the
    /// index past the string terminator. Otherwise returns nil.
    private static func skipOSCResponse(_ bytes: [UInt8], from start: Int) -> Int? {
        // ESC ] already confirmed at start, start+1
        var j = start + 2

        // Parse the numeric OSC code (e.g., "4", "10", "11")
        var code = 0
        var hasCode = false
        while j < bytes.count && bytes[j] >= 0x30 && bytes[j] <= 0x39 {
            code = code * 10 + Int(bytes[j] - 0x30)
            hasCode = true
            j += 1
        }

        // Check for kitty graphics response: ESC ] ... G ... ST
        let isKittyGraphics = !hasCode && j < bytes.count && bytes[j] == 0x47 // 'G'

        let shouldStrip = (hasCode && strippedOSCCodes.contains(code)) || isKittyGraphics

        guard shouldStrip else { return nil }

        // Scan to string terminator: BEL (0x07) or ST (ESC \)
        while j < bytes.count {
            if bytes[j] == 0x07 {
                return j + 1
            }
            if bytes[j] == 0x1B && j + 1 < bytes.count && bytes[j + 1] == 0x5C {
                return j + 2
            }
            j += 1
        }
        // Unterminated OSC — strip to end (incomplete response in buffer)
        return bytes.count
    }
}
