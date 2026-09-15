import SwiftUI
import Combine
import CodeRelayClient

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private init() {
        AppSettings.migrateSpeechRemoval(
            defaults: .standard,
            modelsDirectory: AppSettings.legacySpeechModelsDirectory,
            deleteBedrockToken: { try AuthManager.shared.deleteBedrockToken() }
        )
    }

    /// UUID string of the last-used server, for auto-reconnect on launch.
    @AppStorage("com.clauderelay.mac.lastServerId") var lastServerId: String = ""

    /// Haptic feedback is iOS-only; flag kept for cross-platform ViewModel parity.
    /// On Mac this is a no-op.
    @AppStorage("com.clauderelay.mac.hapticFeedbackEnabled") var hapticFeedbackEnabled = false

    /// Show main window on launch (false when launched-at-login with menu-bar-only mode).
    @AppStorage("com.clauderelay.mac.showWindowOnLaunch") var showWindowOnLaunch = true

    @AppStorage("com.clauderelay.mac.sessionNamingTheme") var sessionNamingTheme: SessionNamingTheme = .gameOfThrones

    @AppStorage("com.clauderelay.mac.launchAtLogin") var launchAtLoginEnabled = false

    @AppStorage("com.clauderelay.mac.autoConnectEnabled") var autoConnectEnabled = false
    @AppStorage("com.clauderelay.mac.pushNotificationsEnabled") var pushNotificationsEnabled = true
    @AppStorage("com.clauderelay.mac.pushNotifyOnFinished") var pushNotifyOnFinished = false


    @AppStorage("com.clauderelay.mac.terminalFontSize") var terminalFontSize: Double = 12

    /// Max scrollback lines kept by SwiftTerm per session. Lower = less RAM,
    /// higher = more scrollback history in-client. Server's ring buffer
    /// replays anything that fell off this edge on next attach.
    @AppStorage("com.clauderelay.mac.terminalScrollbackLines") var terminalScrollbackLines: Int = 5_000

    @AppStorage("com.clauderelay.mac.recordingShortcutEnabled") var recordingShortcutEnabled = true
    @AppStorage("com.clauderelay.mac.recordingShortcutModifiers")
    var recordingShortcutModifiers: Int = Int(NSEvent.ModifierFlags([.command, .option]).rawValue)
    @AppStorage("com.clauderelay.mac.recordingShortcutKey") var recordingShortcutKey = ""

    // MARK: - Prompt optimizer (spec §7.1)

    /// Sent as `shareScreen` on every `optimize_prompt`. Per device, default on.
    @AppStorage("com.clauderelay.mac.shareScreenWithOptimizer") var shareScreenWithOptimizer = true

    // MARK: - Speech-removal migration (spec §7.2)

    static let speechRemovalMigrationKey = "com.clauderelay.mac.speechRemovalMigrationDone"

    /// Every `@AppStorage` key the speech feature ever wrote on macOS, plus the
    /// old `SpeechModelStore` ready flag.
    static let legacySpeechDefaultsKeys = [
        "com.clauderelay.mac.smartCleanupEnabled",
        "com.clauderelay.mac.promptEnhancementEnabled",
        "com.clauderelay.mac.continuousListeningEnabled",
        "com.clauderelay.mac.wakeWord",
        "com.clauderelay.mac.bedrockRegion",
        "com.clauderelay.mac.bedrockBearerToken",
        "com.clauderelay.mac.whisperDownloaded",
    ]

    /// Where `SpeechModelStore` kept downloaded weights on macOS.
    static var legacySpeechModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClaudeRelay", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// macOS wiring of the shared one-time cleanup (see `SpeechRemovalMigration`).
    @discardableResult
    static func migrateSpeechRemoval(
        defaults: UserDefaults,
        modelsDirectory: URL,
        deleteBedrockToken: () throws -> Void
    ) -> Bool {
        SpeechRemovalMigration.run(
            defaults: defaults,
            doneKey: speechRemovalMigrationKey,
            legacyKeys: legacySpeechDefaultsKeys,
            modelsDirectory: modelsDirectory,
            deleteBedrockToken: deleteBedrockToken
        )
    }
}

extension NSEvent.ModifierFlags {
    var symbolString: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
}

extension AppSettings {
    var shortcutModifierFlags: NSEvent.ModifierFlags {
        get { NSEvent.ModifierFlags(rawValue: UInt(recordingShortcutModifiers)) }
        set { recordingShortcutModifiers = Int(newValue.rawValue) }
    }

    var shortcutDisplayString: String {
        let mods = shortcutModifierFlags.symbolString
        let key = recordingShortcutKey.uppercased()
        return mods + key
    }
}
