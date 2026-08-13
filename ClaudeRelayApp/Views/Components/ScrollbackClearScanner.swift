import Foundation

/// Spots `CSI 3 J` — xterm's "erase saved lines", i.e. clear the scrollback — in
/// a stream of terminal output.
///
/// SwiftTerm handles that sequence by trimming the buffer's history and lowering
/// `yBase`/`yDisp` **without telling the view** (`Terminal.cmdEraseInDisplay`
/// case 3 falls straight through to `break`), so the scroll view is left
/// describing lines that no longer exist. `RelayTerminalView` uses this scanner
/// to notice the sequence go past and ask SwiftTerm to recompute its own scroll
/// geometry afterwards.
///
/// State persists across calls because output arrives in frames of arbitrary
/// length: `ESC [ 3` can end one frame and `J` begin the next.
///
/// Deliberately narrow: only a bare `3` parameter counts. `CSI 2 J` (clear
/// screen) and `CSI J` (clear to end) leave the history — and therefore the
/// scroll geometry — alone.
struct ScrollbackClearScanner {

    /// Where the parser is inside an escape sequence.
    private enum State {
        /// Ordinary text.
        case ground
        /// Saw `ESC`, waiting to see whether `[` follows.
        case escape
        /// Inside a CSI sequence, collecting parameters until the final byte.
        case csi
    }

    /// What has been collected in the current CSI's parameter position. Only the
    /// bare-`3` case matters, so the parameter bytes themselves aren't kept.
    private enum Parameters {
        case empty
        case three
        case other
    }

    private var state: State = .ground
    private var parameters: Parameters = .empty

    /// Feeds `bytes` through the parser and reports whether they completed at
    /// least one `CSI 3 J`.
    ///
    /// The whole chunk is always scanned — a frame may hold several sequences,
    /// and stopping early would strand the parser mid-sequence.
    mutating func scan(_ bytes: ArraySlice<UInt8>) -> Bool {
        var didClearScrollback = false
        for byte in bytes {
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape }

            case .escape:
                switch byte {
                case 0x5B:              // '[' → CSI
                    state = .csi
                    parameters = .empty
                case 0x1B:              // ESC ESC → restart on the second one
                    break
                default:                // some other two-byte escape (e.g. RIS)
                    state = .ground
                }

            case .csi:
                switch byte {
                case 0x30...0x3F:       // parameter bytes: 0-9 : ; < = > ?
                    parameters = (parameters == .empty && byte == 0x33) ? .three : .other
                case 0x20...0x2F:       // intermediate bytes
                    parameters = .other
                case 0x40...0x7E:       // final byte — the sequence ends here
                    if byte == 0x4A, parameters == .three {   // 'J'
                        didClearScrollback = true
                    }
                    state = .ground
                default:
                    // A control byte inside the sequence. A real parser would
                    // execute it and keep going; abandoning the sequence is
                    // enough here, because a missed resync only costs us the
                    // stale-geometry repair — it can never wedge the view.
                    state = byte == 0x1B ? .escape : .ground
                }
            }
        }
        return didClearScrollback
    }
}
