import Foundation
import SwiftTerm

/// Everything the optimizer and the replacer need about one session at one
/// instant. Built on the `PTYSession` actor by `promptContext(includeScreen:)`.
public struct PromptContext: Equatable, Sendable {
    public static let maxScreenLines = 40
    public static let maxScreenBytes = 4096

    /// The tracked draft; empty means "nothing to optimize".
    public let draft: String
    public let agentId: String?
    public let agentDisplayName: String?
    public let workingDirectory: String?
    /// Trailing non-empty rendered rows, oldest first. Empty when the screen
    /// is not being shared.
    public let screenLines: [String]
    /// The foreground program enabled bracketed paste (`CSI ?2004h`).
    public let bracketedPaste: Bool
    /// `KittyKeyboardFlags.rawValue`. Stored raw because SwiftTerm's option
    /// set is not `Sendable` and this value crosses the actor boundary.
    public let keyboardFlagsRawValue: Int
    /// False while the tracker's mirror is lost (see `DraftTracker.mirrorLost`):
    /// the real input line holds text the server cannot count, so nothing may be
    /// erased or pasted. `draft` is always `""` when this is false; the converse
    /// does not hold — a genuinely empty line is empty *and* known, and an Undo
    /// onto it is legitimate (erase nothing, paste the original back).
    public let draftKnown: Bool

    public init(draft: String, agentId: String?, agentDisplayName: String?, workingDirectory: String?,
                screenLines: [String], bracketedPaste: Bool, keyboardFlagsRawValue: Int,
                draftKnown: Bool = true) {
        self.draft = draft
        self.agentId = agentId
        self.agentDisplayName = agentDisplayName
        self.workingDirectory = workingDirectory
        self.screenLines = screenLines
        self.bracketedPaste = bracketedPaste
        self.keyboardFlagsRawValue = keyboardFlagsRawValue
        self.draftKnown = draftKnown
    }

    public var keyboardFlags: KittyKeyboardFlags { KittyKeyboardFlags(rawValue: keyboardFlagsRawValue) }

    /// The last `maxScreenLines` non-blank lines of a rendered screen, trimmed
    /// from the top until they fit in `maxScreenBytes` of UTF-8 (+1 per newline).
    public static func trailingScreenLines(_ screenText: String) -> [String] {
        var lines = screenText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.allSatisfy(\.isWhitespace) }
        if lines.count > maxScreenLines { lines.removeFirst(lines.count - maxScreenLines) }
        var bytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        while bytes > maxScreenBytes, !lines.isEmpty {
            bytes -= lines.removeFirst().utf8.count + 1
        }
        return lines
    }
}
