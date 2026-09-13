import Foundation

/// Mirrors the agent's input line from the client's keystrokes so the server
/// knows which draft to replace. Pure value type; `PTYSession` owns one per
/// session and feeds it every `write`. Anything it cannot model (history
/// navigation, unknown chords) clears the draft rather than guessing — an
/// empty draft is a `no_draft` reply, a wrong one would be typed over. That
/// doubt is **sticky**: `mirrorLost` holds until an event proves the real box
/// is empty (a submit-Enter, Ctrl-C) or the agent changes (`reset`), because
/// re-accumulating from the next keystroke onwards would under-count a real
/// line that still holds everything typed before the clear.
struct DraftTracker: Sendable {
    static let maxScalars = 16_384

    private(set) var scalars: [Unicode.Scalar] = []
    private(set) var cursor = 0
    /// Set after Up/Down inside a multi-row draft. The row model is an
    /// approximation, so the next *edit* clears instead of applying; motion
    /// and submission still behave normally.
    private(set) var cursorUncertain = false
    /// Set when the mirror can no longer be trusted. While set, `draft` is
    /// empty and every event except recovery is a no-op, because re-accumulating
    /// over an unknown real line produces exactly the under-count the replacer
    /// cannot survive. Recovery: a submit-Enter (the box is empty for real),
    /// Ctrl-C (both modelled agents clear the input box), or `reset(profile:)`
    /// (agent changed).
    private(set) var mirrorLost = false
    private(set) var profile: InputProfile
    private var columns: Int
    private var killBuffer: [Unicode.Scalar] = []

    init(profile: InputProfile, columns: Int) {
        self.profile = profile
        self.columns = max(1, columns)
    }

    /// Empty whenever `mirrorLost` — `invalidate()` empties `scalars` and the
    /// gate in `apply` refuses every event that could refill it.
    var draft: String {
        assert(!mirrorLost || scalars.isEmpty, "a lost mirror must expose an empty draft")
        return String(String.UnicodeScalarView(scalars))
    }

    /// Empties the mirror without saying anything about the real input line.
    /// Callers pick `invalidate()` or `knownEmpty()` instead — nothing outside
    /// this type calls it (`PTYSession` uses only `reset`, `setColumns`,
    /// `apply`, `draft`).
    private mutating func clear() {
        scalars.removeAll(keepingCapacity: true)
        cursor = 0
        cursorUncertain = false
    }

    /// The mirror no longer matches the real line and we cannot say what the
    /// line holds. Sticky: every later event is a no-op until a recovery event.
    private mutating func invalidate() {
        clear()
        mirrorLost = true
    }

    /// The real input line is empty for certain (submitted, or Ctrl-C'd), so an
    /// empty mirror is *correct* and accumulation can resume immediately.
    private mutating func knownEmpty() {
        clear()
        mirrorLost = false
    }

    /// Foreground agent changed: drop the draft and adopt its chords. The new
    /// agent draws its own (empty) input box, so this is a recovery point.
    mutating func reset(profile: InputProfile) {
        knownEmpty()
        killBuffer.removeAll()
        self.profile = profile
    }

    /// The server just erased the mirrored line and pasted `draft`; the line is
    /// now exactly `draft` with the cursor at its end. Only the two server write
    /// sites call this — client keystrokes never do.
    ///
    /// This is a recovery point for the same reason a submit is: the server knows
    /// what the line holds, so accumulating from here cannot under-count. The
    /// erase keystrokes it wrote have already passed through `apply` and may have
    /// left the mirror uncertain or lost — this overrides that.
    mutating func adopt(_ draft: String) {
        let new = Array(draft.unicodeScalars)
        // Same doubt as an overflowing paste: the real line now holds more than
        // the mirror is allowed to model, so nothing can be said about it.
        guard new.count <= Self.maxScalars else { invalidate(); return }
        scalars = new
        cursor = new.count
        cursorUncertain = false
        mirrorLost = false
    }

    mutating func setColumns(_ cols: Int) {
        columns = max(1, cols)
    }

    mutating func apply(contentsOf events: [KeyEvent]) {
        for event in events { apply(event) }
    }

    mutating func apply(_ event: KeyEvent) {
        // While the mirror is lost only the Enter family and Ctrl-C can restore
        // it (they are the events that can prove the box is empty). Everything
        // else — text, paste, edits, motion, other chords — is a no-op: applying
        // it would start rebuilding a short mirror over an unknown real line.
        if mirrorLost {
            switch event {
            case .enter, .lineFeed, .control(0x03): break
            default: return
            }
        }
        if cursorUncertain, Self.isEdit(event) {
            invalidate()
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
        // too little and paste into the residue), so drop it and stay lost.
        case .unknown: invalidate()
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
        guard let key = InputKey.forEnter(mods) else { invalidate(); return }
        applyEnterKey(key)
    }

    /// An Enter-family key resolved to a manifest symbol. The three branches do
    /// genuinely different things now: a newline keeps the draft, a submit is the
    /// one event that proves the real box is empty, and a key in neither list is
    /// a chord this agent was never measured for — it may have inserted a newline
    /// or submitted, so the mirror is unsound and stays that way.
    private mutating func applyEnterKey(_ key: InputKey) {
        if profile.newline.contains(key) {
            insertNewline()
        } else if profile.submit.contains(key) {
            knownEmpty()
        } else {
            invalidate()
        }
    }

    private mutating func insertNewline() {
        // Reached from the `mirrorLost` gate above for a newline-Enter: the real
        // box still holds an unknown line, so there is nothing to append to.
        if mirrorLost { return }
        if cursorUncertain { invalidate(); return }
        insert(["\n"])
    }

    // MARK: - Editing primitives

    private mutating func insert(_ new: [Unicode.Scalar]) {
        guard !new.isEmpty else { return }
        // Checked *before* inserting: a client frame may carry 10 MB, and the
        // mirror would be cleared straight afterwards anyway.
        guard scalars.count + new.count <= Self.maxScalars else { invalidate(); return }
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
        case 0x03: knownEmpty()                               // Ctrl-C: both modelled agents empty the box
        case 0x1F: invalidate()                               // Ctrl-_: undo puts unknown text back
        case 0x09: invalidate()                               // Tab: completion rewrites the line
        case 0x0C: break                                      // Ctrl-L: redraw only, draft intact
        // Ctrl-P/N (history), Ctrl-R (search), Ctrl-T (transpose), Ctrl-O, …
        // every one of them can change the line in a way this does not model.
        default: invalidate()
        }
    }

    private mutating func handleAlt(_ ch: Character) {
        switch ch {
        case "b": cursor = wordStart()
        case "f": cursor = wordEnd()
        case "d": kill(cursor..<wordEnd())
        case "\u{7F}": kill(wordStart()..<cursor)
        case "y": invalidate()   // yank-pop: the previous yank is replaced by unknown text
        default: invalidate()    // Alt-<anything else> is an unmodelled agent binding
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
        guard rows > 1 else { invalidate(); return }   // single row: Up/Down is history
        let current = slots[cursor]
        let target = current.row + delta
        guard target >= 0, target < rows else { invalidate(); return }
        var best = cursor
        for (index, slot) in slots.enumerated() where slot.row == target {
            best = index
            if slot.col >= current.col { break }
        }
        cursor = best
        cursorUncertain = true
    }
}
