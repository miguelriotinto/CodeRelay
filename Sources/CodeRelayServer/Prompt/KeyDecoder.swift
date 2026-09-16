import Foundation

/// Modifiers reported with an Enter key. Bit order matches the kitty keyboard
/// protocol (shift=1, alt=2, ctrl=4, super=8) so kitty's `mods - 1` maps in.
struct KeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    static let shift = KeyModifiers(rawValue: 1 << 0)
    static let alt = KeyModifiers(rawValue: 1 << 1)
    static let control = KeyModifiers(rawValue: 1 << 2)
    static let `super` = KeyModifiers(rawValue: 1 << 3)
}

/// One editing-relevant key event decoded from the client's input bytes.
enum KeyEvent: Equatable, Sendable {
    case text(String)
    case paste(String)
    case enter(KeyModifiers)
    case backspace
    case delete
    case left, right, up, down, home, end
    /// Ctrl-<key>, carrying the C0 byte: Ctrl-A = 0x01 … Ctrl-Z = 0x1A, Ctrl-_ = 0x1F.
    case control(UInt8)
    /// Alt-<char>. `.alt("\u{7F}")` is Alt-Backspace.
    case alt(Character)
    /// Bare LF (0x0A) — Ctrl+J, and what a terminal without the kitty protocol
    /// sends for Ctrl+Enter. Kept distinct from `.enter([.control])` because the
    /// live probe found claude 2.1.270 and codex 0.154.0 insert a newline for LF
    /// and do nothing for `CSI 13;5u`; it maps to `InputKey.ctrlJ`.
    case lineFeed
    /// A sequence that is provably inert at an input line: mouse reports,
    /// DA/DSR/CPR replies, F-keys and other functional kitty codes, kitty
    /// release events, `ESC ESC`, a well-formed OSC/DCS string. The tracker
    /// leaves the draft alone.
    case ignored
    /// A sequence the decoder could not classify. The tracker treats it as a
    /// lost mirror and clears.
    case unknown
}

/// Streaming decoder from raw terminal input bytes to `KeyEvent`s. Partial
/// UTF-8, partial escape sequences and open bracketed pastes carry across
/// `decode` calls, so a WebSocket frame boundary may fall anywhere.
struct KeyDecoder: Sendable {
    private enum State: Equatable {
        case ground
        case escape                       // ESC seen
        case csi([UInt8])                 // ESC [ … parameter/intermediate bytes so far
        case ss3                          // ESC O
        case osc(sawEscape: Bool)         // ESC ] … BEL | ESC \
        case dcs(sawEscape: Bool)         // ESC P … ESC \
        case paste                        // ESC [ 200 ~ … ESC [ 201 ~
    }

    /// Longest parameter string accepted inside a CSI before it is abandoned.
    static let maxCSIParameterBytes = 64
    /// Longest OSC/DCS body accepted before the sequence is abandoned. `Alt+]`
    /// and `Alt+Shift+P` are byte-identical to the two introducers, so an
    /// unterminated string sequence is a keystroke and not a protocol error —
    /// without this cap one of them parks the decoder in `.osc`/`.dcs` for the
    /// rest of the session while the user keeps typing into it.
    static let maxStringSequenceBytes = 1_024
    /// A paste larger than this is flushed in pieces; `DraftTracker` clears
    /// past 16 384 scalars anyway.
    static let maxPasteBytes = 1_048_576
    private static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // ESC [ 2 0 1 ~
    private static let pasteStartParams: [UInt8] = [0x32, 0x30, 0x30]           // "200"

    private var state: State = .ground
    private var utf8Pending: [UInt8] = []
    private var utf8Expected = 0
    private var textRun: [Unicode.Scalar] = []
    private var pasteBuffer: [UInt8] = []
    /// Bytes consumed so far inside `.osc`/`.dcs`.
    private var stringSequenceBytes = 0
    /// The current text run overflowed `DraftTracker.maxScalars`, so the rest of
    /// it is dropped too instead of being emitted as a partial tail — one
    /// `.unknown` was already emitted for the run, and the tracker has cleared.
    /// Invalid UTF-8 is *not* dropped this way; it emits `.unknown` too.
    private var textRunDropped = false

    init() {}

    mutating func decode(_ data: Data) -> [KeyEvent] {
        var events: [KeyEvent] = []
        for byte in data {
            switch state {
            case .ground: decodeGround(byte, into: &events)
            case .escape: decodeEscape(byte, into: &events)
            case .csi(let params): decodeCSI(byte, params: params, into: &events)
            case .ss3: decodeSS3(byte, into: &events)
            case .osc(let sawEscape): decodeStringSequence(byte, sawEscape: sawEscape, isOSC: true, into: &events)
            case .dcs(let sawEscape): decodeStringSequence(byte, sawEscape: sawEscape, isOSC: false, into: &events)
            case .paste: decodePaste(byte, into: &events)
            }
        }
        flushText(into: &events)
        return events
    }

    // MARK: - Ground

    private mutating func decodeGround(_ byte: UInt8, into events: inout [KeyEvent]) {
        if utf8Expected > 0 {
            if byte & 0xC0 == 0x80 {
                utf8Pending.append(byte)
                if utf8Pending.count == utf8Expected {
                    if let s = String(bytes: utf8Pending, encoding: .utf8) {
                        textRun.append(contentsOf: s.unicodeScalars)
                        capTextRun(into: &events)
                    } else {
                        // Invalid-but-complete (overlong, surrogate, out-of-range): fail loud (see rationale below).
                        flushText(into: &events)
                        events.append(.unknown)
                    }
                    utf8Pending.removeAll()
                    utf8Expected = 0
                }
                return
            }
            // Broken sequence. Fail *loud*, not quiet (review A-3): the
            // foreground program does not necessarily drop these bytes — a
            // permissive input box may render a replacement character or the raw
            // byte — so silently dropping them leaves the mirror holding fewer
            // units than the real line and the next erase too short, the one
            // destructive direction (spec §9). `.unknown` costs one optimize on a
            // malformed frame; a short erase pastes into surviving residue.
            flushText(into: &events)
            events.append(.unknown)
            utf8Pending.removeAll()
            utf8Expected = 0
        }
        switch byte {
        case 0x1B:
            flushText(into: &events)
            state = .escape
        case 0x0D:
            flushText(into: &events)
            events.append(.enter([]))
        case 0x0A:
            flushText(into: &events)
            events.append(.lineFeed)
        case 0x7F, 0x08:
            flushText(into: &events)
            events.append(.backspace)
        case 0x00, 0x1C, 0x1D, 0x1E:
            // NUL (Ctrl+Space) and FS/GS/RS are chords nothing here models.
            flushText(into: &events)
            events.append(.unknown)
        case 0x01...0x1A, 0x1F:
            flushText(into: &events)
            events.append(.control(byte))
        case 0x20...0x7E:
            textRun.append(Unicode.Scalar(byte))
            capTextRun(into: &events)
        case 0xC2...0xDF:
            utf8Expected = 2
            utf8Pending = [byte]
        case 0xE0...0xEF:
            utf8Expected = 3
            utf8Pending = [byte]
        case 0xF0...0xF4:
            utf8Expected = 4
            utf8Pending = [byte]
        default:
            // Stray continuation byte / invalid lead (0x80–0xC1, 0xF5–0xFF).
            // Same reasoning as the broken-sequence path above: unclassifiable,
            // so `.unknown` rather than a silent drop.
            flushText(into: &events)
            events.append(.unknown)
        }
    }

    /// A single client frame may carry 10 MB of printable bytes. The tracker
    /// cannot hold more than `DraftTracker.maxScalars` anyway, so an over-long
    /// run is reported once as unclassifiable and never materialised as a huge
    /// `String`. The *whole* run is then dropped, not just the excess: emitting
    /// the tail would leave the mirror holding the last few thousand scalars of
    /// a much longer real line, which is the one destructive direction
    /// (under-counting). One `.unknown` clears the mirror instead.
    private mutating func capTextRun(into events: inout [KeyEvent]) {
        guard textRun.count > DraftTracker.maxScalars else { return }
        textRun.removeAll(keepingCapacity: true)
        if !textRunDropped {
            textRunDropped = true
            events.append(.unknown)
        }
    }

    private mutating func flushText(into events: inout [KeyEvent]) {
        if textRunDropped {
            textRun.removeAll(keepingCapacity: true)
            textRunDropped = false
            return
        }
        guard !textRun.isEmpty else { return }
        events.append(.text(String(String.UnicodeScalarView(textRun))))
        textRun.removeAll(keepingCapacity: true)
    }

    // MARK: - Escape prefix

    private mutating func decodeEscape(_ byte: UInt8, into events: inout [KeyEvent]) {
        switch byte {
        case 0x5B: state = .csi([])                          // '['
        case 0x4F: state = .ss3                              // 'O'
        case 0x5D: stringSequenceBytes = 0; state = .osc(sawEscape: false)   // ']'
        case 0x50: stringSequenceBytes = 0; state = .dcs(sawEscape: false)   // 'P'
        case 0x1B: events.append(.ignored)                   // ESC ESC: stay armed
        case 0x0D: state = .ground; events.append(.enter([.alt]))
        case 0x0A: state = .ground; events.append(.enter([.alt, .control]))
        case 0x7F: state = .ground; events.append(.alt("\u{7F}"))
        case 0x20...0x7E: state = .ground; events.append(.alt(Character(Unicode.Scalar(byte))))
        default: state = .ground; events.append(.unknown)
        }
    }

    // MARK: - CSI

    private mutating func decodeCSI(_ byte: UInt8, params: [UInt8], into events: inout [KeyEvent]) {
        switch byte {
        case 0x20...0x3F:
            var next = params
            next.append(byte)
            if next.count > Self.maxCSIParameterBytes {
                state = .ground
                events.append(.unknown)
            } else {
                state = .csi(next)
            }
        case 0x40...0x7E:
            state = .ground
            if byte == 0x7E, params == Self.pasteStartParams {
                pasteBuffer.removeAll()
                state = .paste
                return
            }
            events.append(Self.csiEvent(final: byte, params: String(decoding: params, as: UTF8.self)))
        default:
            state = .ground
            events.append(.unknown)
        }
    }

    private static func csiEvent(final: UInt8, params: String) -> KeyEvent {
        // Private-parameter sequences (CSI ? … / CSI < … / CSI > … / CSI = …) are
        // modes, mouse reports and replies, never keys.
        if let first = params.first, "?<>=".contains(first) { return .ignored }
        let fields = params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        switch final {
        case 0x75: return kittyEvent(fields: fields)            // 'u'
        case 0x7E: return tildeEvent(fields: fields)            // '~'
        case 0x41, 0x42, 0x43, 0x44, 0x48, 0x46:
            // A *modified* arrow / Home / End is a word jump or a selection
            // drag; the tracker models neither, so clear instead of moving one
            // cell. `CSI 1;1X` encodes "no modifiers" and stays a plain motion.
            guard trailingModifiers(fields).isEmpty else { return .unknown }
            switch final {
            case 0x41: return .up
            case 0x42: return .down
            case 0x43: return .right
            case 0x44: return .left
            case 0x48: return .home                             // 'H'
            default: return .end                                // 'F'
            }
        case 0x52: return .ignored                              // 'R': CPR/DSR reply, never a key
        default: return .unknown
        }
    }

    /// The `CSI <n>;<mods> X` modifier field, or `[]` when absent.
    private static func trailingModifiers(_ fields: [String]) -> KeyModifiers {
        guard fields.count >= 2, let raw = Int(fields[1]) else { return [] }
        return modifiers(fromEncoded: raw)
    }

    private static func tildeEvent(fields: [String]) -> KeyEvent {
        guard let first = fields.first, let code = Int(first) else { return .unknown }
        switch code {
        case 1, 7, 4, 8, 3:
            // Modified Home/End/Delete are word jumps and word deletes — same
            // reasoning as the modified arrows above.
            guard trailingModifiers(fields).isEmpty else { return .unknown }
            switch code {
            case 1, 7: return .home
            case 4, 8: return .end
            default: return .delete
            }
        case 27:
            // xterm modifyOtherKeys: CSI 27 ; mods ; keycode ~ — a keycode, not a
            // function key, which is why 27 is matched before the ranges below.
            guard fields.count >= 3, let mods = Int(fields[1]), let key = Int(fields[2]) else { return .unknown }
            return key == 13 ? .enter(modifiers(fromEncoded: mods)) : .unknown
        // PageUp/PageDown scroll the transcript and F1…F20 do nothing at an input
        // line in both measured agents, so all of them are provably inert. No
        // `trailingModifiers` guard: Shift+PageUp (`CSI 5;2~`) is the same scroll,
        // and a modified F-key is still an F-key. Insert (`CSI 2~`) is *not* here —
        // it toggles overwrite mode, which the tracker does not model.
        case 5, 6, 11...24, 25...26, 28...34: return .ignored
        default: return .unknown                                // Insert, unrecognised codes, …
        }
    }

    /// kitty / xterm encode modifiers as `1 + bitmask`; absent or 0 means none.
    private static func modifiers(fromEncoded value: Int) -> KeyModifiers {
        guard value >= 1 else { return [] }
        return KeyModifiers(rawValue: UInt8(truncatingIfNeeded: value - 1))
            .intersection([.shift, .alt, .control, .super])
    }

    // MARK: - kitty CSI u

    private static func kittyEvent(fields: [String]) -> KeyEvent {
        // CSI keycode[:shifted[:base]] ; mods[:event] ; text-codepoints u
        let keyParts = fields[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let keyCode = UInt32(keyParts[0]) else { return .unknown }
        var mods = KeyModifiers()
        var eventType = 1
        if fields.count > 1 {
            let modParts = fields[1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if let raw = Int(modParts[0]) { mods = modifiers(fromEncoded: raw) }
            if modParts.count > 1, let e = Int(modParts[1]) { eventType = e }
        }
        if eventType == 3 { return .ignored }   // release
        switch keyCode {
        case 13: return .enter(mods.intersection([.shift, .alt, .control]))
        case 127: return .backspace
        case 9: return .control(0x09)            // Tab: completion rewrites the line
        case 27: return .unknown                 // Escape: agents bind it to clearing the box
        default: break
        }
        // The associated-text field is evaluated *before* the functional-key
        // guard: a keypad digit reports a code above 57344 and carries the digit
        // it typed as text, and that text is what reached the input line.
        if fields.count > 2 {
            let text = fields[2].split(separator: ":").compactMap { UInt32($0).flatMap(Unicode.Scalar.init) }
            if !text.isEmpty { return .text(String(String.UnicodeScalarView(text))) }
        }
        if keyCode >= 57344 { return .ignored }  // functional keys (F1…, modifiers, keypad)
        var scalarValue = keyCode
        if mods.contains(.shift), keyParts.count > 1, let shifted = UInt32(keyParts[1]) { scalarValue = shifted }
        guard let scalar = Unicode.Scalar(scalarValue) else { return .unknown }
        if mods.contains(.control) {
            switch scalar {
            case "a"..."z": return .control(UInt8(scalar.value - 96))
            case "A"..."Z": return .control(UInt8(scalar.value - 64))
            case "_": return .control(0x1F)
            case "-" where mods.contains(.shift): return .control(0x1F)
            default: return .unknown
            }
        }
        if mods.contains(.alt) { return .alt(Character(scalar)) }
        if mods.contains(.super) { return .unknown }
        return .text(String(Character(scalar)))
    }

    // MARK: - SS3

    private mutating func decodeSS3(_ byte: UInt8, into events: inout [KeyEvent]) {
        state = .ground
        switch byte {
        case 0x41: events.append(.up)
        case 0x42: events.append(.down)
        case 0x43: events.append(.right)
        case 0x44: events.append(.left)
        case 0x48: events.append(.home)
        case 0x46: events.append(.end)
        case 0x50, 0x51, 0x52, 0x53:
            // SS3 P/Q/R/S = F1–F4 in application mode. SwiftTerm sends these for
            // the bare function keys; they cannot edit the line so must not cost
            // the user the mirror (spec §5.1, review A-2). The CSI `1;<mod>P..S`
            // modifier dialect falls to `.unknown` (mirror lost, safe direction),
            // and the `~` dialect is handled separately in `tildeEvent`.
            events.append(.ignored)
        default: events.append(.unknown)
        }
    }

    // MARK: - OSC / DCS

    private mutating func decodeStringSequence(_ byte: UInt8, sawEscape: Bool, isOSC: Bool,
                                               into events: inout [KeyEvent]) {
        stringSequenceBytes += 1
        if stringSequenceBytes > Self.maxStringSequenceBytes {
            state = .ground
            events.append(.unknown)
            return
        }
        if sawEscape {
            if byte == 0x5C {                                   // ESC \
                state = .ground
                events.append(.ignored)
            } else {
                state = isOSC ? .osc(sawEscape: false) : .dcs(sawEscape: false)
            }
            return
        }
        if byte == 0x1B {
            state = isOSC ? .osc(sawEscape: true) : .dcs(sawEscape: true)
        } else if isOSC, byte == 0x07 {                         // BEL
            state = .ground
            events.append(.ignored)
        }
    }

    // MARK: - Bracketed paste

    private mutating func decodePaste(_ byte: UInt8, into events: inout [KeyEvent]) {
        pasteBuffer.append(byte)
        if pasteBuffer.count >= Self.pasteEnd.count,
           Array(pasteBuffer.suffix(Self.pasteEnd.count)) == Self.pasteEnd {
            pasteBuffer.removeLast(Self.pasteEnd.count)
            events.append(.paste(String(decoding: pasteBuffer, as: UTF8.self)))
            pasteBuffer.removeAll()
            state = .ground
        } else if pasteBuffer.count > Self.maxPasteBytes {
            let keep = min(Self.pasteEnd.count - 1, pasteBuffer.count)
            let flushEnd = pasteBuffer.count - keep
            events.append(.paste(String(decoding: pasteBuffer[..<flushEnd], as: UTF8.self)))
            pasteBuffer.removeFirst(flushEnd)
        }
    }
}
