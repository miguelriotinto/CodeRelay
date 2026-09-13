import Foundation

/// A chord the agent's input line reacts to, spelled as in the manifest.
enum InputKey: String, Codable, CaseIterable, Sendable {
    case enter
    case ctrlEnter = "ctrl_enter"
    case altEnter = "alt_enter"
    case shiftEnter = "shift_enter"
    /// A literal backslash immediately followed by plain Enter (Claude Code's `\⏎`).
    case backslashEnter = "backslash_enter"

    /// The chord an Enter event carries, or nil for combinations no agent
    /// binds (Ctrl+Alt+Enter, Super+Enter, …).
    static func forEnter(_ mods: KeyModifiers) -> InputKey? {
        switch mods {
        case []: return .enter
        case [.control]: return .ctrlEnter
        case [.alt]: return .altEnter
        case [.shift]: return .shiftEnter
        default: return nil
        }
    }
}

/// How an agent's input line interprets the chords `DraftTracker` models.
/// Comes from the optional `"input"` object of the agent manifest; every
/// field is optional and defaults to the plain-shell behaviour below.
struct InputProfile: Codable, Equatable, Sendable {
    /// Chords that insert a newline into the draft.
    var newline: [InputKey]
    /// Chords that submit (and therefore clear) the draft.
    var submit: [InputKey]
    /// Ctrl-U at the start of a line also removes the preceding newline.
    var killLineAcrossLines: Bool
    /// Columns the input box is indented from the PTY's left edge; used to
    /// approximate soft-wrapped rows (Claude Code draws a 4-column gutter).
    var inset: Int
    /// Free-form note of the agent build these values were probed against.
    var probedWith: String?

    static let `default` = InputProfile()

    init(newline: [InputKey] = [], submit: [InputKey] = [.enter, .ctrlEnter],
         killLineAcrossLines: Bool = false, inset: Int = 0, probedWith: String? = nil) {
        self.newline = newline
        self.submit = submit
        self.killLineAcrossLines = killLineAcrossLines
        self.inset = inset
        self.probedWith = probedWith
    }

    private enum CodingKeys: String, CodingKey {
        case newline, submit, killLineAcrossLines, inset, probedWith
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        newline = try c.decodeIfPresent([InputKey].self, forKey: .newline) ?? []
        submit = try c.decodeIfPresent([InputKey].self, forKey: .submit) ?? [.enter, .ctrlEnter]
        killLineAcrossLines = try c.decodeIfPresent(Bool.self, forKey: .killLineAcrossLines) ?? false
        inset = try c.decodeIfPresent(Int.self, forKey: .inset) ?? 0
        probedWith = try c.decodeIfPresent(String.self, forKey: .probedWith)
        guard inset >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .inset, in: c, debugDescription: "inset must be >= 0")
        }
    }
}
