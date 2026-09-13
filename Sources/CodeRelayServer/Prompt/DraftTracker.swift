import Foundation

/// Mirrors the agent's input line from the client's keystrokes so the server
/// knows which draft to replace. Pure value type; `PTYSession` owns one per
/// session and feeds it every `write`. Anything it cannot model (history
/// navigation, unknown chords) clears the draft rather than guessing — an
/// empty draft is a `no_draft` reply, a wrong one would be typed over.
struct DraftTracker: Sendable {
    static let maxScalars = 16_384

    private(set) var scalars: [Unicode.Scalar] = []
    private(set) var cursor = 0
    /// Set after Up/Down inside a multi-row draft. The row model is an
    /// approximation, so the next *edit* clears instead of applying; motion
    /// and submission still behave normally.
    private(set) var cursorUncertain = false
    private(set) var profile: InputProfile
    private var columns: Int
    private var killBuffer: [Unicode.Scalar] = []

    init(profile: InputProfile, columns: Int) {
        self.profile = profile
        self.columns = max(1, columns)
    }

    var draft: String { String(String.UnicodeScalarView(scalars)) }

    mutating func clear() {
        scalars.removeAll(keepingCapacity: true)
        cursor = 0
        cursorUncertain = false
    }

    /// Foreground agent changed: drop the draft and adopt its chords.
    mutating func reset(profile: InputProfile) {
        clear()
        killBuffer.removeAll()
        self.profile = profile
    }

    mutating func setColumns(_ cols: Int) {
        columns = max(1, cols)
    }

    mutating func apply(contentsOf events: [KeyEvent]) {
        for event in events { apply(event) }
    }

    mutating func apply(_ event: KeyEvent) {
        if cursorUncertain, Self.isEdit(event) {
            clear()
            return
        }
        switch event {
        case .text(let s): insert(Array(s.unicodeScalars))
        case .paste(let s): insert(Array(s.unicodeScalars))
        case .enter(let mods): handleEnter(mods)
        case .backspace:
            guard cursor > 0 else { return }
            scalars.remove(at: cursor - 1)
            cursor -= 1
        case .delete:
            guard cursor < scalars.count else { return }
            scalars.remove(at: cursor)
        case .left: cursor = max(0, cursor - 1)
        case .right: cursor = min(scalars.count, cursor + 1)
        case .home: cursor = lineStart()
        case .end: cursor = lineEnd()
        case .up: moveRow(by: -1)
        case .down: moveRow(by: 1)
        case .control(let byte): handleControl(byte)
        case .alt(let ch): handleAlt(ch)
        // Provably inert at an input line (mouse reports, terminal replies,
        // F-keys, key releases) — the draft is untouched.
        case .ignored: break
        // Unclassifiable: the mirror can no longer be trusted. Under-counting
        // the draft is the one destructive direction (the replacer would erase
        // too little and paste into the residue), so drop it.
        case .unknown: clear()
        case .lineFeed: applyEnterKey(.ctrlJ)
        }
    }

    // MARK: - Classification

    /// Events that change text and therefore cannot be applied at an uncertain cursor.
    private static func isEdit(_ event: KeyEvent) -> Bool {
        switch event {
        case .text, .paste, .backspace, .delete: return true
        case .control(let c): return c == 0x15 || c == 0x0B || c == 0x17 || c == 0x19   // U K W Y
        case .alt(let ch): return ch == "d" || ch == "\u{7F}"
        default: return false
        }
    }

    // MARK: - Enter

    private mutating func handleEnter(_ mods: KeyModifiers) {
        if mods.isEmpty, profile.newline.contains(.backslashEnter),
           cursor > 0, scalars[cursor - 1] == "\\" {
            scalars.remove(at: cursor - 1)
            cursor -= 1
            insertNewline()
            return
        }
        guard let key = InputKey.forEnter(mods) else { clear(); return }
        applyEnterKey(key)
    }

    /// An Enter-family key resolved to a manifest symbol. A key in neither list
    /// is a chord this agent's behaviour was never measured for — it may well
    /// have inserted a newline or submitted, so the mirror is no longer sound.
    private mutating func applyEnterKey(_ key: InputKey) {
        if profile.newline.contains(key) {
            insertNewline()
        } else if profile.submit.contains(key) {
            clear()
        } else {
            clear()
        }
    }

    private mutating func insertNewline() {
        if cursorUncertain { clear(); return }
        insert(["\n"])
    }

    // MARK: - Editing primitives

    private mutating func insert(_ new: [Unicode.Scalar]) {
        guard !new.isEmpty else { return }
        // Checked *before* inserting: a client frame may carry 10 MB, and the
        // mirror would be cleared straight afterwards anyway.
        guard scalars.count + new.count <= Self.maxScalars else { clear(); return }
        scalars.insert(contentsOf: new, at: cursor)
        cursor += new.count
    }

    private mutating func kill(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        killBuffer = Array(scalars[range])
        scalars.removeSubrange(range)
        cursor = range.lowerBound
    }

    private func lineStart() -> Int {
        var i = cursor
        while i > 0, scalars[i - 1] != "\n" { i -= 1 }
        return i
    }

    private func lineEnd() -> Int {
        var i = cursor
        while i < scalars.count, scalars[i] != "\n" { i += 1 }
        return i
    }

    private static func isSpace(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\n" || s == "\t" }

    private func wordStart() -> Int {
        var i = cursor
        while i > 0, Self.isSpace(scalars[i - 1]) { i -= 1 }
        while i > 0, !Self.isSpace(scalars[i - 1]) { i -= 1 }
        return i
    }

    private func wordEnd() -> Int {
        var i = cursor
        while i < scalars.count, Self.isSpace(scalars[i]) { i += 1 }
        while i < scalars.count, !Self.isSpace(scalars[i]) { i += 1 }
        return i
    }

    // MARK: - Ctrl / Alt chords

    private mutating func handleControl(_ byte: UInt8) {
        switch byte {
        case 0x01: cursor = lineStart()                       // Ctrl-A
        case 0x05: cursor = lineEnd()                         // Ctrl-E
        case 0x15: killToLineStart()                          // Ctrl-U
        case 0x0B: kill(cursor..<lineEnd())                   // Ctrl-K
        case 0x17: kill(wordStart()..<cursor)                 // Ctrl-W
        case 0x19: insert(killBuffer)                         // Ctrl-Y
        case 0x03, 0x1F: clear()                              // Ctrl-C, Ctrl-_
        case 0x09: clear()                                    // Tab: completion rewrites the line
        case 0x0C: break                                      // Ctrl-L: redraw only, draft intact
        // Ctrl-P/N (history), Ctrl-R (search), Ctrl-T (transpose), Ctrl-O, …
        // every one of them can change the line in a way this does not model.
        default: clear()
        }
    }

    private mutating func handleAlt(_ ch: Character) {
        switch ch {
        case "b": cursor = wordStart()
        case "f": cursor = wordEnd()
        case "d": kill(cursor..<wordEnd())
        case "\u{7F}": kill(wordStart()..<cursor)
        case "y": clear()
        default: clear()      // Alt-<anything else> is an unmodelled agent binding
        }
    }

    private mutating func killToLineStart() {
        let start = lineStart()
        if cursor > start {
            kill(start..<cursor)
        } else if cursor > 0, profile.killLineAcrossLines, scalars[cursor - 1] == "\n" {
            kill((cursor - 1)..<cursor)
        }
    }

    // MARK: - Rows

    /// Row/column of every cursor slot under soft wrapping at
    /// `columns - inset` cells. Each scalar is one cell — wide glyphs are
    /// approximated, which is why Up/Down marks the cursor uncertain.
    private func layout() -> (slots: [(row: Int, col: Int)], rows: Int) {
        let width = max(1, columns - profile.inset)
        var slots: [(row: Int, col: Int)] = []
        slots.reserveCapacity(scalars.count + 1)
        var row = 0
        var col = 0
        for scalar in scalars {
            slots.append((row, col))
            if scalar == "\n" {
                row += 1
                col = 0
            } else {
                col += 1
                if col == width { row += 1; col = 0 }
            }
        }
        slots.append((row, col))   // the slot after the last scalar
        return (slots, row + 1)
    }

    private mutating func moveRow(by delta: Int) {
        let (slots, rows) = layout()
        guard rows > 1 else { clear(); return }        // single row: Up/Down is history
        let current = slots[cursor]
        let target = current.row + delta
        guard target >= 0, target < rows else { clear(); return }
        var best = cursor
        for (index, slot) in slots.enumerated() where slot.row == target {
            best = index
            if slot.col >= current.col { break }
        }
        cursor = best
        cursorUncertain = true
    }
}
