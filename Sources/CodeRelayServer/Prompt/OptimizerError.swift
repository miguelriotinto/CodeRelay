import Foundation

/// Every way an optimize request can fail, with the fixed user-facing string
/// for each. The client shows `clientMessage` verbatim in its toast, so these
/// strings are part of the wire contract — change them together with the
/// client specs.
enum OptimizerError: Error, Equatable, Sendable {
    /// Transport failure, 429/5xx, or the 12 s deadline.
    case unavailable
    /// 401/403 from the provider — the operator's key is wrong or expired.
    case keyRejected
    /// The model refused (`stop_reason == "refusal"`).
    case refused
    /// Reply parsed but did not carry a usable `deliver_prompt` call.
    case malformed
    /// Draft exceeded `PromptOptimizer.maxDraftBytes`.
    case draftTooLong
    /// Startup-time misconfiguration; the detail is logged, never sent.
    case configuration(String)

    var clientMessage: String {
        switch self {
        case .unavailable: return "Optimizer unavailable, try again"
        case .keyRejected: return "Optimizer key rejected on the relay"
        case .refused: return "Optimizer could not rewrite this prompt"
        case .malformed: return "Optimizer could not rewrite this prompt"
        case .draftTooLong: return "Prompt too long to optimize"
        case .configuration: return "Optimizer not configured on the relay"
        }
    }
}
