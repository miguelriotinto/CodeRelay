import Foundation

/// All runtime-configurable options that control how a transcript is processed
/// and how the continuous pipeline behaves. Pushed from the UI into both
/// engines; captured at the moment work kicks off so mid-session setting
/// changes take effect on the next utterance.
public struct SpeechProcessingOptions: Equatable, Sendable {
    public var smartCleanupEnabled: Bool
    public var promptEnhancementEnabled: Bool
    public var bedrockBearerToken: String
    public var bedrockRegion: String
    public var wakeWord: String
    /// Safety net: the maximum wall-clock time the turn-end classifier is
    /// allowed to run before the engine assumes it has hung and resumes
    /// recording. This is NOT a "force done" timer — when this fires we
    /// return to `.recording` and wait for the next real silence, giving
    /// the user more time to continue. Only needs tuning if the CoreML
    /// classifier runs pathologically slowly on a particular device.
    public var turnEndSilenceTimeout: TimeInterval

    public init(
        smartCleanupEnabled: Bool = true,
        promptEnhancementEnabled: Bool = false,
        bedrockBearerToken: String = "",
        bedrockRegion: String = "us-east-1",
        wakeWord: String = "claude",
        turnEndSilenceTimeout: TimeInterval = 8.0
    ) {
        self.smartCleanupEnabled = smartCleanupEnabled
        self.promptEnhancementEnabled = promptEnhancementEnabled
        self.bedrockBearerToken = bedrockBearerToken
        self.bedrockRegion = bedrockRegion
        self.wakeWord = wakeWord
        self.turnEndSilenceTimeout = turnEndSilenceTimeout
    }
}
