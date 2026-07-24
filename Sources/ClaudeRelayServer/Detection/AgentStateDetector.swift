import Foundation
import ClaudeRelayKit

/// Evaluates a screen snapshot against an agent's manifest and returns the
/// winning detection. Ported from herdr's `evaluate_loaded_manifest` +
/// `compiled_gate_matches`. Regexes are compiled once at init.
final class AgentStateDetector {

    private let manifests: [String: AgentManifest]
    /// Cache: "<pattern>" -> compiled NSRegularExpression (dotMatchesLineSeparators
    /// on so `.` spans the joined multi-line region, matching Rust's default).
    private var regexCache: [String: NSRegularExpression] = [:]

    init(manifests: [String: AgentManifest]) {
        self.manifests = manifests
        // Warm the cache so the hot detect() path never compiles.
        for manifest in manifests.values {
            for rule in manifest.rules {
                warm(rule.gate)
            }
        }
    }

    /// Detect the agent's state. Returns nil for an unknown agent id (herdr's
    /// "nil agent → Unknown"; callers treat nil as "no manifest, skip").
    func detect(agentId: String, snapshot: ScreenSnapshot) -> AgentDetection? {
        guard let manifest = manifests[agentId] else { return nil }

        var winner: AgentStateRule?
        for rule in manifest.rules {
            let region = ScreenRegion.slice(rule.region, snapshot: snapshot)
            guard matches(rule.gate, text: region) else { continue }
            if let current = winner {
                if current.priority < rule.priority { winner = rule }
            } else {
                winner = rule
            }
        }

        guard let rule = winner else {
            // No rule matched: known agent falls back to Idle, all flags off.
            return AgentDetection(state: .idle, skipStateUpdate: false,
                                  visibleIdle: false, visibleBlocker: false, visibleWorking: false)
        }

        let state = rule.resolvedState
        return AgentDetection(
            state: state,
            skipStateUpdate: rule.skipStateUpdate ?? false,
            visibleIdle: (rule.visibleIdle ?? false) && state == .idle,
            visibleBlocker: (rule.visibleBlocker ?? false) && state == .blocked,
            visibleWorking: (rule.visibleWorking ?? false) && state == .working
        )
    }

    // MARK: - Gate matching (herdr compiled_gate_matches)

    private func matches(_ gate: AgentGate, text: String) -> Bool {
        let lower = text.lowercased()

        if let contains = gate.contains, !contains.allSatisfy({ lower.contains($0.lowercased()) }) {
            return false
        }
        if let patterns = gate.regex, !patterns.allSatisfy({ regexMatches($0, in: text) }) {
            return false
        }
        if let patterns = gate.lineRegex {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let allMatch = patterns.allSatisfy { pattern in
                lines.contains { regexMatches(pattern, in: $0) }
            }
            if !allMatch { return false }
        }
        if let all = gate.all, !all.allSatisfy({ matches($0, text: text) }) {
            return false
        }
        if let any = gate.any, !any.isEmpty, !any.contains(where: { matches($0, text: text) }) {
            return false
        }
        if let not = gate.not, not.contains(where: { matches($0, text: text) }) {
            return false
        }
        return true
    }

    // MARK: - Regex cache

    private func warm(_ gate: AgentGate) {
        (gate.regex ?? []).forEach { _ = compiled($0) }
        (gate.lineRegex ?? []).forEach { _ = compiled($0) }
        (gate.all ?? []).forEach(warm)
        (gate.any ?? []).forEach(warm)
        (gate.not ?? []).forEach(warm)
    }

    private func compiled(_ pattern: String) -> NSRegularExpression? {
        if let cached = regexCache[pattern] { return cached }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            RelayLogger.log(.error, category: "detection", "Bad manifest regex: \(pattern)")
            return nil
        }
        regexCache[pattern] = re
        return re
    }

    private func regexMatches(_ pattern: String, in text: String) -> Bool {
        guard let re = compiled(pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }

    // MARK: - Bundled manifest loading

    /// Load the bundled JSON manifests from the target's resource bundle, then
    /// overlay any user override in `~/.claude-relay/agents/<id>.json`. The set
    /// of ids is derived from `CodingAgent.all` so registering a new agent (and
    /// shipping its `<id>.json`) is all that's needed — no second list to edit.
    /// An agent without a bundled manifest is simply skipped (no error): it is
    /// still detected/labeled, it just has no screen-state rules.
    static func loadBundled() -> [String: AgentManifest] {
        var result: [String: AgentManifest] = [:]
        let decoder = JSONDecoder()

        for id in CodingAgent.all.map(\.id) {
            guard let url = Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "Agents") else {
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? decoder.decode(AgentManifest.self, from: data) else {
                RelayLogger.log(.error, category: "detection", "Failed to load bundled manifest: \(id)")
                continue
            }
            result[id] = manifest
        }

        // User overrides shadow bundled manifests by agent id.
        let overrideDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-relay/agents", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(at: overrideDir, includingPropertiesForKeys: nil) {
            for url in entries where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let manifest = try? decoder.decode(AgentManifest.self, from: data) else {
                    RelayLogger.log(.error, category: "detection", "Bad override manifest: \(url.lastPathComponent)")
                    continue
                }
                result[manifest.id] = manifest
            }
        }

        return result
    }
}
