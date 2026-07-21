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

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            // Detection is read-only: the emulator never needs to reply upstream.
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

    private let delegate = Delegate()
    private let terminal: Terminal

    init(cols: UInt16, rows: UInt16) {
        let options = TerminalOptions(cols: Int(cols), rows: Int(rows))
        terminal = Terminal(delegate: delegate, options: options)
    }

    /// Feed a chunk of raw PTY output into the emulator.
    func feed(_ data: Data) {
        terminal.feed(byteArray: [UInt8](data))
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
