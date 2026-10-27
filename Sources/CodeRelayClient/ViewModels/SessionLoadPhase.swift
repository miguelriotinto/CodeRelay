import Foundation

/// Where a session is on its way to the screen, for the loading overlay.
///
/// Opening a session is connect → authenticate → list sessions → attach or
/// resume → the server replays its scrollback ring buffer (up to 512 KB) →
/// `replay_complete` → one batched paint. The terminal deliberately holds every
/// replayed byte until that paint so the user sees the final state instead of
/// history scrolling past — which on a slow link means several seconds of a
/// black pane with nothing to say why. `SharedSessionCoordinator.sessionLoadPhase`
/// walks through these cases and goes back to `nil` the instant the first
/// visible frame is delivered (`TerminalViewModel.onReplayDelivered`).
///
/// Labels and the byte formatter are duplicated verbatim in the Kotlin
/// `relay.session.SessionLoadPhase` so all four clients read the same.
public enum SessionLoadPhase: Equatable, Sendable {
    case connecting
    case authenticating
    case loadingSessions
    case attaching
    /// Scrollback bytes received so far for the session being opened.
    case loadingHistory(bytes: Int)

    public var label: String {
        switch self {
        case .connecting:      return "Connecting to server…"
        case .authenticating:  return "Authenticating…"
        case .loadingSessions: return "Loading sessions…"
        case .attaching:       return "Attaching to session…"
        case .loadingHistory:  return "Loading session history…"
        }
    }

    /// Secondary line under the label; only the replay has one.
    public var detail: String? {
        if case .loadingHistory(let bytes) = self { return Self.formatBytes(bytes) }
        return nil
    }

    /// `<1 KB`, then whole kilobytes up to a mebibyte, then one decimal of MB.
    /// Whole KB rather than decimals because the number ticks up dozens of
    /// times a second during a replay and a jittering decimal reads worse.
    public static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "<1 KB" }
        if bytes < 1024 * 1024 { return "\(Int((Double(bytes) / 1024).rounded())) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
