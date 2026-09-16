import Foundation

/// Client-side view of `optimize_prompt_result` (spec §6). Unknown statuses
/// collapse into `.failed` so a newer server can never crash an older client.
public enum OptimizeOutcome: Equatable, Sendable {
    /// The relay replaced the draft. `original` is what it replaced, for Undo;
    /// the relay may omit it (nil) when it was not tracking the draft.
    case ok(original: String?)
    case noDraft
    case passthrough
    case unconfigured
    case failed(message: String)
}

/// Client-side view of `replace_prompt_result` (spec §6).
public enum ReplaceOutcome: Equatable, Sendable {
    case ok
    case failed(message: String)
}

/// Every user-facing string of the prompt-optimizer feature, byte-exact per
/// spec §7.1 / §9 / §10. Both apps read these; nothing retypes them.
public enum OptimizerStrings {
    public static let configHint = "Enable on the relay: claude-relay config set promptOptimizerEnabled true"
    public static let updateRelayHint = "Update the relay to use the prompt optimizer"
    public static let noDraft = "Type or dictate a prompt first"
    public static let passthrough = "Nothing to optimize"
    public static let couldNotRewrite = "Optimizer could not rewrite this prompt"
    public static let optimized = "Optimized"
    public static let undo = "Undo"
    public static let wandLabel = "Optimize Prompt"
    public static let shareScreenToggle = "Share terminal screen with the optimizer"
    public static let shareScreenFooter = "With this on, the relay also sends the last 40 lines of the terminal screen to the optimizer model. The draft and its working directory are always sent."
}

public extension Notification.Name {
    /// Posted by the hardware-keyboard shortcut (iOS `RelayTerminalView`,
    /// macOS `RecordingShortcutMonitor`); `WandButton` observes it and taps
    /// itself. Replaces the removed `toggleSpeechRecording`.
    static let optimizePromptShortcut = Notification.Name("optimizePromptShortcut")
}
