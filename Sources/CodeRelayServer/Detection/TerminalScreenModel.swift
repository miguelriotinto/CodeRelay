import Foundation
import SwiftTerm

/// An immutable snapshot of the emulated screen at a point in time, plus the
/// two out-of-band OSC signals herdr's rules can key on.
struct ScreenSnapshot: Equatable {
    /// The visible grid rendered to text, one row per line, trailing blanks trimmed.
    let text: String
    /// The most recent OSC 0/2 window title, or "".
    let oscTitle: String
    /// The most recent OSC 9;4 progress payload rendered as "4;<state>[;<pct>]", or "".
    let oscProgress: String
}

/// Headless SwiftTerm emulator fed the same PTY byte stream the client sees, so
/// the server can read the *rendered* screen (not the raw escape soup) for
/// agent-state detection. One per PTY session; lives inside the PTYSession
/// actor's isolation domain (never touched concurrently).
final class TerminalScreenModel {

    /// Captures the terminal's title / progress callbacks. Retained STRONGLY
    /// because `Terminal.tdel` is a weak reference — a delegate that only the
    /// terminal held weakly would be released immediately and never fire.
    private final class Delegate: NSObject, TerminalDelegate {
        var oscTitle = ""
        var oscProgress = ""
        /// Answers this emulator produced during the current `feed`, drained by
        /// it. Capped so a stream packed with queries (a binary file `cat`ed to
        /// the tty) can't turn one read into an unbounded PTY write.
        var pendingResponse = [UInt8]()

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            // NOT read-only any more: these are the answers to terminal queries
            // in the PTY stream (cursor position, device attributes, colours).
            // The server owes them to the program that asked — see
            // `TerminalQueryFilter` for why the device must not answer instead.
            guard pendingResponse.count + data.count <= TerminalScreenModel.maxResponseBytesPerFeed else { return }
            pendingResponse.append(contentsOf: data)
        }

        func setTerminalTitle(source: Terminal, title: String) {
            oscTitle = title
        }

        func progressReport(source: Terminal, report: Terminal.ProgressReport) {
            switch report.state {
            case .remove:
                oscProgress = "4;0"
            case .set:
                oscProgress = "4;1;\(report.progress ?? 0)"
            case .error:
                oscProgress = "4;2;\(report.progress ?? 0)"
            case .indeterminate:
                oscProgress = "4;3"
            case .pause:
                oscProgress = "4;4;\(report.progress ?? 0)"
            }
        }
    }

    /// Ceiling on the answers one `feed` may generate. 4 KB is far above any
    /// legitimate burst (the longest single answer is a few dozen bytes) and far
    /// below the PTY's 4 MB write queue, so a flood is dropped here rather than
    /// evicting a user's real keystrokes from that queue.
    static let maxResponseBytesPerFeed = 4096

    private let delegate = Delegate()
    private let terminal: Terminal

    init(cols: UInt16, rows: UInt16) {
        // Detection reads only the visible viewport (see snapshot()), so keep
        // the emulator's scrollback minimal — no need to retain history buffers
        // across up to maxSessionsPerToken concurrent sessions.
        let options = TerminalOptions(cols: Int(cols), rows: Int(rows), scrollback: Int(rows))
        terminal = Terminal(delegate: delegate, options: options)
    }

    /// Feed a chunk of raw PTY output into the emulator, returning whatever the
    /// emulator wants to answer upstream (empty for the vast majority of chunks).
    ///
    /// Deliberately NOT `@discardableResult`: silently dropping these answers is
    /// the defect this returns them to fix — a query then goes unanswered here
    /// and is answered a round trip later by the device, landing as typed text at
    /// the user's prompt. Every caller must decide where they go.
    func feed(_ data: Data) -> Data {
        delegate.pendingResponse.removeAll(keepingCapacity: true)
        terminal.feed(byteArray: [UInt8](data))
        guard !delegate.pendingResponse.isEmpty else { return Data() }
        return Data(delegate.pendingResponse)
    }

    /// Resize the emulated grid to match a client resize.
    func resize(cols: UInt16, rows: UInt16) {
        terminal.resize(cols: Int(cols), rows: Int(rows))
    }

    /// Render the current visible grid + latest OSC signals into a snapshot.
    func snapshot() -> ScreenSnapshot {
        var lines: [String] = []
        lines.reserveCapacity(terminal.rows)
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else {
                lines.append("")
                continue
            }
            lines.append(line.translateToString(trimRight: true))
        }
        return ScreenSnapshot(
            text: lines.joined(separator: "\n"),
            oscTitle: delegate.oscTitle,
            oscProgress: delegate.oscProgress
        )
    }
}
