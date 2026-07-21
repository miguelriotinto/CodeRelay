import Foundation
import ClaudeRelayKit

/// The outcome of evaluating an agent's manifest against a screen snapshot.
/// Mirrors herdr's `AgentDetection`.
struct AgentDetection: Equatable {
    let state: AgentDetectedState
    /// When true, the winning rule was a "viewer/menu overlay" — the arbiter
    /// must freeze the session's current state rather than adopt this one.
    let skipStateUpdate: Bool
    let visibleIdle: Bool
    let visibleBlocker: Bool
    let visibleWorking: Bool
}

/// A recursive match gate. All present fields AND together (see
/// `AgentStateRule.matches`).
struct AgentGate: Codable {
    var contains: [String]?
    var regex: [String]?
    var lineRegex: [String]?
    var all: [AgentGate]?
    var any: [AgentGate]?
    var not: [AgentGate]?
}

/// One detection rule. `state` is nil only for `skip_state_update` overlays
/// that don't assert a state (herdr's `unknown`).
struct AgentStateRule: Codable {
    let id: String
    let state: String?
    let priority: Int
    let region: String
    var skipStateUpdate: Bool?
    var visibleIdle: Bool?
    var visibleBlocker: Bool?
    var visibleWorking: Bool?
    // Top-level gate fields (a rule is itself a gate plus routing metadata).
    var contains: [String]?
    var regex: [String]?
    var lineRegex: [String]?
    var all: [AgentGate]?
    var any: [AgentGate]?
    var not: [AgentGate]?

    private enum CodingKeys: String, CodingKey {
        case id, state, priority, region
        case skipStateUpdate = "skip_state_update"
        case visibleIdle = "visible_idle"
        case visibleBlocker = "visible_blocker"
        case visibleWorking = "visible_working"
        case contains, regex
        case lineRegex = "line_regex"
        case all, any, not
    }

    /// The rule's own gate, assembled from its top-level gate fields.
    var gate: AgentGate {
        AgentGate(contains: contains, regex: regex, lineRegex: lineRegex, all: all, any: any, not: not)
    }

    var resolvedState: AgentDetectedState {
        state.flatMap(AgentDetectedState.init(rawValue:)) ?? .unknown
    }
}

/// A per-agent set of ordered rules.
struct AgentManifest: Codable {
    let id: String
    let rules: [AgentStateRule]
}
