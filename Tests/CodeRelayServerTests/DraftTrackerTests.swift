import XCTest
import Foundation
@testable import CodeRelayServer

final class DraftTrackerTests: XCTestCase {
    private let claude = InputProfile(
        newline: [.ctrlEnter, .altEnter, .shiftEnter, .backslashEnter], submit: [.enter],
        killLineAcrossLines: true, inset: 4)

    /// The profile actually shipped in `Resources/Agents/claude.json`: the live
    /// probe measured `CSI 13;5u` (`ctrl_enter`) as *no effect* and bare LF
    /// (`ctrl_j`) as the newline, so `ctrl_enter` is in neither list.
    private let bundledClaude = InputProfile(
        newline: [.shiftEnter, .altEnter, .backslashEnter, .ctrlJ], submit: [.enter],
        killLineAcrossLines: true, inset: 4)

    private func tracker(_ profile: InputProfile = .default, columns: Int = 80,
                         typing text: String = "") -> DraftTracker {
        var t = DraftTracker(profile: profile, columns: columns)
        if !text.isEmpty { t.apply(.text(text)) }
        return t
    }

    // MARK: Insertion and submission

    func testTextAndPasteInsertAtCursor() {
        var t = tracker(typing: "ac")
        t.apply(.left)
        t.apply(.text("b"))
        t.apply(.paste("XY"))
        XCTAssertEqual(t.draft, "abXYc")
        XCTAssertEqual(t.cursor, 4)
    }

    func testDefaultProfileEnterAndCtrlEnterSubmit() {
        var t = tracker(typing: "ls")
        t.apply(.enter([]))
        XCTAssertEqual(t.draft, "")
        t.apply(.text("ls"))
        t.apply(.enter([.control]))
        XCTAssertEqual(t.draft, "")
    }

    func testDefaultProfileClearsOnUnboundEnterChords() {
        // Shift+Enter is in neither list for a plain shell, so what it did to the
        // real line was never measured — the mirror cannot keep claiming "ls".
        var t = tracker(typing: "ls")
        t.apply(.enter([.shift]))
        XCTAssertEqual(t.draft, "")
    }

    func testClaudeProfileNewlineChords() {
        var t = tracker(claude, typing: "a")
        t.apply(.enter([.control])); t.apply(.text("b"))
        t.apply(.enter([.alt])); t.apply(.text("c"))
        t.apply(.enter([.shift])); t.apply(.text("d"))
        XCTAssertEqual(t.draft, "a\nb\nc\nd")
        t.apply(.enter([]))
        XCTAssertEqual(t.draft, "")
    }

    func testBackslashEnterRemovesBackslashAndInsertsNewline() {
        var t = tracker(claude, typing: "fix it\\")
        t.apply(.enter([]))
        t.apply(.text("please"))
        XCTAssertEqual(t.draft, "fix it\nplease")
    }

    func testBackslashEnterIsSubmitUnderDefaultProfile() {
        var t = tracker(typing: "echo \\")
        t.apply(.enter([]))
        XCTAssertEqual(t.draft, "")
    }

    // MARK: Simple editing

    func testBackspaceDeleteAndClampedMotion() {
        var t = tracker(typing: "abc")
        t.apply(.left); t.apply(.left); t.apply(.left); t.apply(.left)   // clamps at 0
        XCTAssertEqual(t.cursor, 0)
        t.apply(.backspace)                                              // no-op at 0
        t.apply(.delete)
        XCTAssertEqual(t.draft, "bc")
        t.apply(.right); t.apply(.right); t.apply(.right)                // clamps at end
        t.apply(.backspace)
        XCTAssertEqual(t.draft, "b")
    }

    func testHomeEndAndCtrlAEAreLineLocal() {
        var t = tracker(claude, typing: "one")
        t.apply(.enter([.control])); t.apply(.text("two"))
        t.apply(.home)
        XCTAssertEqual(t.cursor, 4)
        t.apply(.end)
        XCTAssertEqual(t.cursor, 7)
        t.apply(.control(0x01))
        XCTAssertEqual(t.cursor, 4)
        t.apply(.control(0x05))
        XCTAssertEqual(t.cursor, 7)
    }

    // MARK: Kills and yank

    func testCtrlUKillsToLineStartAndCtrlYReinserts() {
        var t = tracker(typing: "hello world")
        t.apply(.left); t.apply(.left); t.apply(.left); t.apply(.left); t.apply(.left)
        t.apply(.control(0x15))
        XCTAssertEqual(t.draft, "world")
        XCTAssertEqual(t.cursor, 0)
        t.apply(.control(0x19))
        XCTAssertEqual(t.draft, "hello world")
    }

    func testCtrlUAtLineStartRemovesNewlineOnlyWhenProfileAllows() {
        var c = tracker(claude, typing: "a")
        c.apply(.enter([.control])); c.apply(.text("b")); c.apply(.home)
        c.apply(.control(0x15))
        XCTAssertEqual(c.draft, "ab")

        var d = tracker(InputProfile(newline: [.ctrlEnter], submit: [.enter]), typing: "a")
        d.apply(.enter([.control])); d.apply(.text("b")); d.apply(.home)
        d.apply(.control(0x15))
        XCTAssertEqual(d.draft, "a\nb")
    }

    func testCtrlKKillsToLineEnd() {
        var t = tracker(typing: "abc def")
        t.apply(.left); t.apply(.left); t.apply(.left)
        t.apply(.control(0x0B))
        XCTAssertEqual(t.draft, "abc ")
    }

    func testWordKillsAndMotions() {
        var t = tracker(typing: "git commit  now")
        t.apply(.control(0x17))                       // Ctrl-W
        XCTAssertEqual(t.draft, "git commit  ")
        t.apply(.alt("\u{7F}"))                       // Alt-Backspace
        XCTAssertEqual(t.draft, "git ")
        t.apply(.alt("b"))
        XCTAssertEqual(t.cursor, 0)
        t.apply(.alt("f"))
        XCTAssertEqual(t.cursor, 3)
        t.apply(.alt("b"))
        t.apply(.alt("d"))                            // Alt-D: delete to word end
        XCTAssertEqual(t.draft, " ")
    }

    func testClearingChords() {
        for event in [KeyEvent.control(0x03), .control(0x1F), .alt("y")] {
            var t = tracker(typing: "abc")
            t.apply(event)
            XCTAssertEqual(t.draft, "", "\(event) should clear")
        }
    }

    // MARK: Up / Down

    func testUpOnSingleRowClearsAsHistory() {
        var t = tracker(typing: "abc")
        t.apply(.up)
        XCTAssertEqual(t.draft, "")
        XCTAssertFalse(t.cursorUncertain)
    }

    func testUpInsideMultiRowMovesAndMarksUncertain() {
        var t = tracker(claude, typing: "first line")
        t.apply(.enter([.control])); t.apply(.text("second"))
        t.apply(.up)
        XCTAssertEqual(t.draft, "first line\nsecond")
        XCTAssertTrue(t.cursorUncertain)
        XCTAssertEqual(t.cursor, 6)                   // same column on row 0
        t.apply(.up)                                  // leaving the first row → history
        XCTAssertEqual(t.draft, "")
        XCTAssertFalse(t.cursorUncertain)
    }

    func testDownOffLastRowClears() {
        var t = tracker(claude, typing: "a")
        t.apply(.enter([.control])); t.apply(.text("b"))
        t.apply(.down)
        XCTAssertEqual(t.draft, "")
    }

    /// The row width comes from `columns - inset`, not from `columns`: at 10
    /// columns and inset 4 the box is 6 cells wide, so 12 chars fill rows 0 and 1
    /// and the trailing cursor slot sits alone on row 2 (see
    /// `testSoftWrapExactMultipleHasATrailingRow` for that phantom row).
    func testSoftWrapCountsRowsFromColumnsMinusInset() {
        var t = tracker(claude, columns: 10, typing: "abcdefghijkl")
        t.apply(.up)
        XCTAssertEqual(t.draft, "abcdefghijkl")
        XCTAssertTrue(t.cursorUncertain)
        XCTAssertEqual(t.cursor, 6)                   // row 2 col 0 → up → row 1 col 0 = index 6
    }

    /// A partly-filled last row. 6 cells per row, 13 chars → rows 0 and 1 full,
    /// one char on row 2; the cursor slot after the last scalar is (row 2, col 1).
    /// `.up` walks row 1 and stops at the first slot whose column is >= 1.
    func testSoftWrapUpFromAPartialLastRow() {
        var t = tracker(claude, columns: 10, typing: "abcdefghijklm")
        t.apply(.up)
        XCTAssertEqual(t.draft, "abcdefghijklm")
        XCTAssertEqual(t.cursor, 7)                   // row 1, col 1
        XCTAssertTrue(t.cursorUncertain)
    }

    /// An exact multiple wraps to a *phantom* empty row: 12 chars at 6 cells is
    /// rows 0 and 1 full plus the trailing cursor slot alone on row 2. So two
    /// `.up`s stay inside the draft and only the third reads as history.
    func testSoftWrapExactMultipleHasATrailingRow() {
        var t = tracker(claude, columns: 10, typing: "abcdefghijkl")
        t.apply(.up)
        XCTAssertEqual(t.cursor, 6)                   // row 1, col 0
        XCTAssertEqual(t.draft, "abcdefghijkl")
        t.apply(.up)
        XCTAssertEqual(t.cursor, 0)                   // row 0, col 0
        XCTAssertEqual(t.draft, "abcdefghijkl")
        t.apply(.up)
        XCTAssertEqual(t.draft, "")                   // off the top: history recall
    }

    func testEditWhileUncertainClears() {
        var t = tracker(claude, typing: "a")
        t.apply(.enter([.control])); t.apply(.text("b"))
        t.apply(.up)
        t.apply(.text("x"))
        XCTAssertEqual(t.draft, "")
        XCTAssertFalse(t.cursorUncertain)
    }

    func testMotionWhileUncertainIsHarmless() {
        var t = tracker(claude, typing: "a")
        t.apply(.enter([.control])); t.apply(.text("b"))
        t.apply(.up)
        t.apply(.left); t.apply(.end)
        XCTAssertEqual(t.draft, "a\nb")
        XCTAssertTrue(t.cursorUncertain)
    }

    /// A replacement (BS×N, DEL×N, paste) arrives as ordinary input, so at an
    /// *uncertain* cursor its first backspace is an edit the row model cannot
    /// place — the mirror is invalidated and the paste that follows is a no-op.
    /// Before D1 this rebuilt the mirror as "new text"; it is now empty until the
    /// user submits. The trade is deliberate: the same relaxation that let this
    /// paste land also let a user's next keystroke rebuild a short mirror over a
    /// real line, which is the under-count the replacer cannot survive. The
    /// certain-cursor path — the one an optimize normally takes — still round
    /// trips exactly (`DraftReplacerTests.testReplacementRoundTripsThroughDecoderAndTracker`).
    func testReplacementSequenceAtAnUncertainCursorLosesTheMirror() {
        var t = tracker(claude, typing: "a")
        t.apply(.enter([.control])); t.apply(.text("b"))
        t.apply(.up)
        XCTAssertTrue(t.cursorUncertain)
        for _ in 0..<3 { t.apply(.backspace) }
        for _ in 0..<3 { t.apply(.delete) }
        t.apply(.paste("new text"))
        XCTAssertEqual(t.draft, "")
        XCTAssertTrue(t.mirrorLost)
        XCTAssertFalse(t.cursorUncertain)
    }

    // MARK: Lifecycle

    func testResetClearsAndSwapsProfile() {
        var t = tracker(typing: "abc")
        t.reset(profile: claude)
        XCTAssertEqual(t.draft, "")
        XCTAssertEqual(t.profile, claude)
        t.apply(.text("x")); t.apply(.enter([.control]))
        XCTAssertEqual(t.draft, "x\n")
    }

    func testCapClearsDraft() {
        var t = tracker()
        t.apply(.paste(String(repeating: "x", count: DraftTracker.maxScalars)))
        XCTAssertEqual(t.draft.unicodeScalars.count, DraftTracker.maxScalars)
        t.apply(.text("y"))
        XCTAssertEqual(t.draft, "")
    }

    // MARK: C2 — clear on anything unmodelled

    func testOnlyProvablyInertEventsLeaveTheDraftAlone() {
        var t = tracker(typing: "abc")
        t.apply(.ignored)                             // mouse report, DA/CPR reply, F-key…
        t.apply(.control(0x0C))                       // Ctrl-L: redraws, never edits
        XCTAssertEqual(t.draft, "abc")
        XCTAssertEqual(t.cursor, 3)
    }

    func testEverythingUnmodelledClearsTheMirror() {
        let cases: [(String, KeyEvent)] = [
            ("Tab (completion rewrites the line)", .control(0x09)),
            ("Ctrl-P (history)", .control(0x10)),
            ("Ctrl-B (unmodelled motion)", .control(0x02)),
            ("Ctrl-R (reverse search)", .control(0x12)),
            ("Alt-Q (unmodelled chord)", .alt("q")),
            ("an unclassifiable sequence", .unknown),
            ("Ctrl+Shift+Enter (no InputKey)", .enter([.control, .shift])),
        ]
        for (name, event) in cases {
            var t = tracker(typing: "abc")
            t.apply(event)
            XCTAssertEqual(t.draft, "", "\(name) should clear the mirror")
        }
        // ctrl_enter is in neither list in the shipped claude profile — the
        // probe measured "no effect" — so it clears rather than being ignored.
        var claudeTracker = tracker(bundledClaude, typing: "abc")
        claudeTracker.apply(.enter([.control]))
        XCTAssertEqual(claudeTracker.draft, "")
    }

    // MARK: C3 — bounded insert

    func testOversizedInsertClearsInsteadOfGrowing() {
        var t = tracker(typing: "abc")
        t.apply(.text(String(repeating: "x", count: 20_000)))
        XCTAssertEqual(t.draft, "")
        XCTAssertEqual(t.cursor, 0)

        var p = tracker(typing: "abc")
        p.apply(.paste(String(repeating: "y", count: 20_000)))
        XCTAssertEqual(p.draft, "")
    }

    // MARK: Kill-buffer lifecycle

    /// A resize does NOT drop the kill buffer — only the row model changes, and
    /// the killed text is still what Ctrl-Y would put back. Pinned because the
    /// asymmetry with `reset(profile:)` below is easy to "tidy" the wrong way.
    func testSetColumnsKeepsTheKillBuffer() {
        var t = tracker(typing: "abc def")
        t.apply(.left); t.apply(.left); t.apply(.left)
        t.apply(.control(0x0B))                       // Ctrl-K: kills "def"
        XCTAssertEqual(t.draft, "abc ")
        t.setColumns(40)
        t.apply(.control(0x19))                       // Ctrl-Y
        XCTAssertEqual(t.draft, "abc def")
    }

    /// A new foreground agent does: its kill buffer is not ours, and yanking
    /// the previous agent's text would invent a draft the user never typed.
    func testResetDropsTheKillBuffer() {
        var t = tracker(typing: "abc def")
        t.apply(.left); t.apply(.left); t.apply(.left)
        t.apply(.control(0x0B))
        t.reset(profile: claude)
        t.apply(.control(0x19))
        XCTAssertEqual(t.draft, "")
    }

    // MARK: D1 — mirror loss is sticky

    /// The wave-C hazard this closes: a bare `clear()` let the very next
    /// keystroke rebuild a 1-scalar mirror over a real line that still held
    /// everything typed before the clear, and `DraftReplacer` would then erase
    /// one character and paste the optimized prompt into the surviving residue.
    func testUnknownThenTypingStaysEmpty() {
        var t = tracker(bundledClaude, typing: "fix the bug")
        t.apply(.unknown)                             // e.g. Ctrl+Left = CSI 1;5D
        t.apply(.text("s"))
        XCTAssertEqual(t.draft, "")
        XCTAssertTrue(t.mirrorLost)
    }

    /// A submit is the one Enter that proves the real box is empty.
    func testSubmitRecoversLostMirror() {
        var t = tracker(bundledClaude, typing: "fix the bug")
        t.apply(.unknown)
        t.apply(.text("s"))
        t.apply(.enter([]))                           // claude submits on plain Enter
        XCTAssertFalse(t.mirrorLost)
        t.apply(.text("new"))
        XCTAssertEqual(t.draft, "new")
    }

    func testResetRecoversLostMirror() {
        var t = tracker(bundledClaude, typing: "fix the bug")
        t.apply(.unknown)
        t.reset(profile: .default)
        XCTAssertFalse(t.mirrorLost)
        t.apply(.text("x"))
        XCTAssertEqual(t.draft, "x")
    }

    func testCtrlCRecoversLostMirror() {
        var t = tracker(bundledClaude, typing: "fix the bug")
        t.apply(.unknown)
        t.apply(.control(0x03))
        XCTAssertFalse(t.mirrorLost)
        t.apply(.text("x"))
        XCTAssertEqual(t.draft, "x")
    }

    /// Ctrl-C empties the box; Ctrl-_ (undo) restores unknown text into it, so
    /// the two cannot share a branch even though both leave the mirror empty.
    func testCtrlUnderscoreLosesTheMirrorButCtrlCDoesNot() {
        var undo = tracker(typing: "abc")
        undo.apply(.control(0x1F))
        XCTAssertEqual(undo.draft, "")
        XCTAssertTrue(undo.mirrorLost)

        var interrupt = tracker(typing: "abc")
        interrupt.apply(.control(0x03))
        XCTAssertEqual(interrupt.draft, "")
        XCTAssertFalse(interrupt.mirrorLost)
    }

    /// A newline-Enter while lost says nothing about the real box — it is still
    /// holding whatever was there, plus a newline.
    func testNewlineEnterWhileLostStaysLost() {
        var t = tracker(bundledClaude, typing: "fix the bug")
        t.apply(.unknown)
        t.apply(.enter([.shift]))                     // newline under claude
        t.apply(.text("y"))
        XCTAssertEqual(t.draft, "")
        XCTAssertTrue(t.mirrorLost)
    }

    func testTabThenTypingStaysEmpty() {
        var t = tracker(bundledClaude, typing: "fix the bu")
        t.apply(.control(0x09))                       // completion rewrites the line
        t.apply(.text("s"))
        XCTAssertEqual(t.draft, "")
        XCTAssertTrue(t.mirrorLost)
    }

    func testOverflowThenTypingStaysEmpty() {
        var t = tracker(typing: "abc")
        t.apply(.text(String(repeating: "x", count: 20_000)))
        t.apply(.text("z"))
        XCTAssertEqual(t.draft, "")
        XCTAssertTrue(t.mirrorLost)
    }

    /// End to end through the decoder: an abandoned OSC (C1's byte cap) emits
    /// `.unknown` and the trailing bytes of the same frame must not re-seed the
    /// mirror — before D1 this left the mirror holding 77 scalars of a ~1100
    /// character real line.
    func testOscAbandonThenTypingStaysEmpty() {
        var decoder = KeyDecoder()
        var t = tracker(bundledClaude, typing: "fix the bug")
        var bytes = Data("\u{1B}]".utf8)
        bytes.append(Data(repeating: 0x61, count: 1_100))
        bytes.append(Data("hi".utf8))
        t.apply(contentsOf: decoder.decode(bytes))
        XCTAssertEqual(t.draft, "")
        XCTAssertTrue(t.mirrorLost)
    }

    // MARK: E3 — the server adopts what it pasted

    /// The optimize/replace path erases and pastes at an *uncertain* cursor when
    /// the user has pressed Up/Down inside a multi-row draft. Those keystrokes
    /// invalidate the mirror on their way through the decoder (see
    /// `testReplacementSequenceAtAnUncertainCursorLosesTheMirror`), and `adopt`
    /// is the server stating the outcome it knows: the line is now exactly the
    /// text it pasted.
    func testAdoptRestoresCertaintyAfterUncertainCursor() {
        var t = tracker(claude, typing: "a")
        t.apply(.enter([.control])); t.apply(.text("b"))
        t.apply(.up)
        XCTAssertTrue(t.cursorUncertain)
        t.adopt("new prompt")
        XCTAssertEqual(t.draft, "new prompt")
        XCTAssertFalse(t.cursorUncertain)
        XCTAssertFalse(t.mirrorLost)
        t.apply(.text("!"))
        XCTAssertEqual(t.draft, "new prompt!")
    }

    /// A lost mirror swallows the replacement's own keystrokes, so only `adopt`
    /// can state the result — and it is a recovery point like a submit, because
    /// the server knows byte-for-byte what the line now holds.
    func testAdoptRecoversLostMirror() {
        var t = tracker(bundledClaude, typing: "fix the bug")
        t.apply(.unknown)
        XCTAssertTrue(t.mirrorLost)
        for _ in 0..<11 { t.apply(.backspace) }
        t.apply(.paste("optimized prompt"))
        XCTAssertEqual(t.draft, "")
        t.adopt("optimized prompt")
        XCTAssertEqual(t.draft, "optimized prompt")
        XCTAssertFalse(t.mirrorLost)
        t.apply(.text(" now"))
        XCTAssertEqual(t.draft, "optimized prompt now")
    }

    /// A replacement longer than the mirror can hold leaves the same doubt as an
    /// overflowing paste: the real line holds text nobody can count.
    func testAdoptOverCapInvalidates() {
        var t = tracker(typing: "abc")
        t.adopt(String(repeating: "x", count: DraftTracker.maxScalars + 1))
        XCTAssertEqual(t.draft, "")
        XCTAssertTrue(t.mirrorLost)
        t.apply(.text("z"))
        XCTAssertEqual(t.draft, "")
    }
}
