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
    /// A sequence we recognise but do not model (mouse, DA replies, Tab, …).
    case ignored
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
    private static let maxCSIParameterBytes = 64
    /// A paste larger than this is flushed in pieces; `DraftTracker` clears
    /// past 16 384 scalars anyway.
    private static let maxPasteBytes = 1_048_576
    private static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // ESC [ 2 0 1 ~
    private static let pasteStartParams: [UInt8] = [0x32, 0x30, 0x30]           // "200"

    private var state: State = .ground
    private var utf8Pending: [UInt8] = []
    private var utf8Expected = 0
    private var textRun: [Unicode.Scalar] = []
    private var pasteBuffer: [UInt8] = []

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
                    }
                    utf8Pending.removeAll()
                    utf8Expected = 0
                }
                return
            }
            // Broken sequence: drop the partial scalar and reprocess this byte.
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
            events.append(.enter([.control]))
        case 0x7F, 0x08:
            flushText(into: &events)
            events.append(.backspace)
        case 0x09, 0x00, 0x1C, 0x1D, 0x1E:
            flushText(into: &events)
            events.append(.ignored)
        case 0x01...0x1A, 0x1F:
            flushText(into: &events)
            events.append(.control(byte))
        case 0x20...0x7E:
            textRun.append(Unicode.Scalar(byte))
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
            break   // stray continuation byte / invalid lead: drop
        }
    }

    private mutating func flushText(into events: inout [KeyEvent]) {
        guard !textRun.isEmpty else { return }
        events.append(.text(String(String.UnicodeScalarView(textRun))))
        textRun.removeAll(keepingCapacity: true)
    }

    // MARK: - Escape prefix

    private mutating func decodeEscape(_ byte: UInt8, into events: inout [KeyEvent]) {
        switch byte {
        case 0x5B: state = .csi([])                          // '['
        case 0x4F: state = .ss3                              // 'O'
        case 0x5D: state = .osc(sawEscape: false)            // ']'
        case 0x50: state = .dcs(sawEscape: false)            // 'P'
        case 0x1B: events.append(.ignored)                   // ESC ESC: stay armed
        case 0x0D: state = .ground; events.append(.enter([.alt]))
        case 0x0A: state = .ground; events.append(.enter([.alt, .control]))
        case 0x7F: state = .ground; events.append(.alt("\u{7F}"))
        case 0x20...0x7E: state = .ground; events.append(.alt(Character(Unicode.Scalar(byte))))
        default: state = .ground; events.append(.ignored)
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
                events.append(.ignored)
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
            events.append(.ignored)
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
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        case 0x48: return .home                                 // 'H'
        case 0x46: return .end                                  // 'F'
        default: return .ignored
        }
    }

    private static func tildeEvent(fields: [String]) -> KeyEvent {
        guard let first = fields.first, let code = Int(first) else { return .ignored }
        switch code {
        case 1, 7: return .home
        case 4, 8: return .end
        case 3: return .delete
        case 27:
            // xterm modifyOtherKeys: CSI 27 ; mods ; keycode ~
            guard fields.count >= 3, let mods = Int(fields[1]), let key = Int(fields[2]) else { return .ignored }
            return key == 13 ? .enter(modifiers(fromEncoded: mods)) : .ignored
        default: return .ignored
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
        guard let keyCode = UInt32(keyParts[0]) else { return .ignored }
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
        case 9, 27: return .ignored
        default: break
        }
        if keyCode >= 57344 { return .ignored }  // functional keys (F1…, modifiers, keypad)
        if fields.count > 2 {
            let text = fields[2].split(separator: ":").compactMap { UInt32($0).flatMap(Unicode.Scalar.init) }
            if !text.isEmpty { return .text(String(String.UnicodeScalarView(text))) }
        }
        var scalarValue = keyCode
        if mods.contains(.shift), keyParts.count > 1, let shifted = UInt32(keyParts[1]) { scalarValue = shifted }
        guard let scalar = Unicode.Scalar(scalarValue) else { return .ignored }
        if mods.contains(.control) {
            switch scalar {
            case "a"..."z": return .control(UInt8(scalar.value - 96))
            case "A"..."Z": return .control(UInt8(scalar.value - 64))
            case "_": return .control(0x1F)
            case "-" where mods.contains(.shift): return .control(0x1F)
            default: return .ignored
            }
        }
        if mods.contains(.alt) { return .alt(Character(scalar)) }
        if mods.contains(.super) { return .ignored }
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
        default: events.append(.ignored)
        }
    }

    // MARK: - OSC / DCS

    private mutating func decodeStringSequence(_ byte: UInt8, sawEscape: Bool, isOSC: Bool,
                                               into events: inout [KeyEvent]) {
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
            events.append(.paste(String(decoding: pasteBuffer, as: UTF8.self)))
            pasteBuffer.removeAll()
        }
    }
}
