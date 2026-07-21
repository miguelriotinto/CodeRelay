import Foundation

/// Describes a coding agent CLI that Claude Relay can detect running inside a PTY session.
///
/// The server's foreground-process poller walks the process tree looking for
/// process names matching any registered agent. OSC title sequences provide
/// a fallback detection path.
public struct CodingAgent: Codable, Equatable, Hashable, Sendable {
    /// Stable identifier used on the wire protocol and in persisted state.
    public let id: String
    /// Human-readable name shown in UI where space permits.
    public let displayName: String
    /// Lowercase executable names to match. A process matches if its name
    /// equals an entry or starts with `"<entry>-"` (e.g. "claude-code" matches "claude").
    public let processNames: [String]
    /// Case-insensitive substrings to match against OSC title sequences.
    public let titleKeywords: [String]

    /// Pre-lowercased copy of `processNames`. Populated at init time so the
    /// hot-path poll doesn't re-lowercase every call.
    private let normalizedProcessNames: [String]

    public init(id: String, displayName: String, processNames: [String], titleKeywords: [String]) {
        self.id = id
        self.displayName = displayName
        self.processNames = processNames
        self.titleKeywords = titleKeywords
        self.normalizedProcessNames = processNames.map { $0.lowercased() }
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, processNames, titleKeywords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.processNames = try container.decode([String].self, forKey: .processNames)
        self.titleKeywords = try container.decode([String].self, forKey: .titleKeywords)
        self.normalizedProcessNames = self.processNames.map { $0.lowercased() }
    }

    public static func == (lhs: CodingAgent, rhs: CodingAgent) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.processNames == rhs.processNames
            && lhs.titleKeywords == rhs.titleKeywords
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(displayName)
        hasher.combine(processNames)
        hasher.combine(titleKeywords)
    }

    public func matchesProcessName(_ name: String) -> Bool {
        let lower = name.lowercased()
        // Dot-separated: macOS bundles appear as `name.app` in process tree
        return normalizedProcessNames.contains { lower == $0 || lower.hasPrefix($0 + "-") || lower.hasPrefix($0 + ".") }
    }

    public func matchesTitle(_ title: String) -> Bool {
        titleKeywords.contains { title.localizedCaseInsensitiveContains($0) }
    }

    // MARK: - Registry

    public static let claude = CodingAgent(
        id: "claude", displayName: "Claude Code",
        processNames: ["claude"], titleKeywords: ["claude"]
    )

    public static let codex = CodingAgent(
        id: "codex", displayName: "Codex",
        processNames: ["codex"], titleKeywords: ["codex"]
    )

    public static let opencode = CodingAgent(
        id: "opencode", displayName: "opencode",
        processNames: ["opencode"], titleKeywords: ["opencode"]
    )

    public static let all: [CodingAgent] = [.claude, .codex, .opencode]

    /// Look up an agent by its wire-protocol ID.
    public static func find(id: String) -> CodingAgent? {
        all.first { $0.id == id }
    }

    /// Find the first agent whose process name matches.
    public static func matching(processName: String) -> CodingAgent? {
        all.first { $0.matchesProcessName(processName) }
    }

    /// Find the first agent whose title keyword matches.
    public static func matching(title: String) -> CodingAgent? {
        all.first { $0.matchesTitle(title) }
    }
}
