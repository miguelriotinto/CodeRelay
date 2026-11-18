import Foundation
import SwiftTerm
import CodeRelayKit

/// A link found under a screen cell, with what the policy needs to judge it.
public struct TerminalLinkHit: Equatable, Sendable {
    public let target: String
    public let source: TerminalLinkSource
    /// For an explicit (OSC 8) link: the text of the cells that carry it.
    public let visibleText: String?

    public var decision: TerminalLinkDecision {
        TerminalLinkPolicy.decide(target, source: source, visibleText: visibleText)
    }
}

/// Finds the link under a screen cell in a SwiftTerm `Terminal`, for both
/// apps. SwiftTerm already detects links (OSC 8 first, then URL-shaped text,
/// following soft-wrapped rows), but its own activation paths do not fit:
/// on iOS a tap only opens a link that is hover-highlighted, which a finger
/// never is; on macOS `requestOpenLink` hands over the target alone, so an
/// explicit link's visible text — which decides `open` vs `confirm` — is lost.
public enum TerminalLinkResolver {
    /// - Parameters: `col`/`row` are **screen** coordinates (0-based, the
    ///   visible grid), the same frame `Terminal.getCharacter(col:row:)` uses.
    public static func link(in terminal: Terminal, col: Int, row: Int) -> TerminalLinkHit? {
        guard col >= 0, col < terminal.cols, row >= 0, row < terminal.rows else { return nil }
        let position = Position(col: col, row: row)
        if let explicit = terminal.link(at: .screen(position), mode: .explicitOnly) {
            return TerminalLinkHit(target: explicit, source: .explicit,
                                   visibleText: visibleText(of: explicit, around: position, in: terminal))
        }
        if let implicit = terminal.link(at: .screen(position), mode: .explicitAndImplicit) {
            return TerminalLinkHit(target: implicit, source: .implicit, visibleText: nil)
        }
        return nil
    }

    /// For a link SwiftTerm already resolved and handed over by target alone
    /// (macOS `requestOpenLink`): explicit if some on-screen cell carries it as
    /// an OSC 8 link, implicit otherwise. Needs no pointer geometry.
    ///
    /// Without the click position we cannot tell WHICH run was clicked, so the
    /// answer fails closed: every run carrying the target is judged, and any
    /// run whose text does not show the target makes the whole answer `confirm`.
    /// Otherwise a program could print the target once in plain sight and also
    /// hang it on a label ("your bank"), and a click on the label would open
    /// without asking.
    public static func hit(forTarget target: String, in terminal: Terminal) -> TerminalLinkHit {
        let cols = terminal.cols
        func carries(_ i: Int) -> Bool {
            terminal.link(at: .screen(Position(col: i % cols, row: i / cols)), mode: .explicitOnly) == target
        }
        var chosen: TerminalLinkHit?
        for i in 0..<(terminal.rows * cols) where carries(i) && (i == 0 || !carries(i - 1)) {
            let start = Position(col: i % cols, row: i / cols)
            let run = TerminalLinkHit(target: target, source: .explicit,
                                      visibleText: visibleText(of: target, around: start, in: terminal))
            guard case .open = run.decision else { return run }   // a deceptive run decides
            chosen = chosen ?? run
        }
        if let chosen { return chosen }
        // No OSC 8 run carries it: implicit only if the text is on screen (what
        // you see is the target); otherwise unknown text, which confirms.
        return screenText(of: terminal).contains(target)
            ? TerminalLinkHit(target: target, source: .implicit, visibleText: nil)
            : TerminalLinkHit(target: target, source: .explicit, visibleText: nil)
    }

    /// The visible grid as text, rows joined with newlines.
    static func screenText(of terminal: Terminal) -> String {
        (0..<terminal.rows).map { row in
            String((0..<terminal.cols).map { col -> Character in
                guard let ch = terminal.getCharacter(col: col, row: row), ch != "\u{0}" else { return " " }
                return ch
            })
        }.joined(separator: "\n")
    }

    /// The contiguous run of on-screen cells carrying `target`, read in order —
    /// it can span rows when the program wrapped the link.
    static func visibleText(of target: String, around start: Position, in terminal: Terminal) -> String {
        let cols = terminal.cols
        func index(_ p: Position) -> Int { p.row * cols + p.col }
        func position(_ i: Int) -> Position { Position(col: i % cols, row: i / cols) }
        func carries(_ i: Int) -> Bool {
            terminal.link(at: .screen(position(i)), mode: .explicitOnly) == target
        }

        let last = terminal.rows * cols - 1
        var first = index(start)
        while first > 0, carries(first - 1) { first -= 1 }
        var end = index(start)
        while end < last, carries(end + 1) { end += 1 }

        var text = ""
        for i in first...end {
            let p = position(i)
            // A wide glyph's trailing cell holds no character of its own.
            if let ch = terminal.getCharacter(col: p.col, row: p.row), ch != "\u{0}" {
                text.append(ch)
            }
        }
        return text
    }
}
