import SwiftUI
import UIKit
import CodeRelayClient

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private init() {
        migrateShortcutIfNeeded()
        AppSettings.migrateSpeechRemoval(
            defaults: .standard,
            directories: AppSettings.legacySpeechDirectories,
            deleteBedrockToken: { try AuthManager.shared.deleteBedrockToken() }
        )
    }

    private func migrateShortcutIfNeeded() {
        let defaults = UserDefaults.standard
        // Only migrate if old format exists and new format hasn't been set
        guard defaults.string(forKey: "recordingShortcutModifier") != nil,
              defaults.object(forKey: "recordingShortcutFlags") == nil else { return }

        let oldRaw = defaults.string(forKey: "recordingShortcutModifier") ?? "commandShift"
        let flags: UIKeyModifierFlags
        switch oldRaw {
        case "commandShift": flags = [.command, .shift]
        case "commandOption": flags = [.command, .alternate]
        case "commandControl": flags = [.command, .control]
        default: flags = [.command, .shift]
        }

        recordingShortcutFlags = Int(flags.rawValue)
        defaults.removeObject(forKey: "recordingShortcutModifier")
    }

    @AppStorage("hapticFeedbackEnabled") var hapticFeedbackEnabled = true
    /// Push notifications: master toggle + whether to be notified when an agent
    /// finishes (blocked always notifies when push is on).
    @AppStorage("pushNotificationsEnabled") var pushNotificationsEnabled = true
    @AppStorage("pushNotifyOnFinished") var pushNotifyOnFinished = false
    @AppStorage("autoConnectEnabled") var autoConnectEnabled = false
    @AppStorage("lastConnectedServerId") var lastConnectedServerId: String = ""
    @AppStorage("sessionNamingTheme") var sessionNamingTheme: SessionNamingTheme = .gameOfThrones
    @AppStorage("terminalFontSize") var terminalFontSize: Double = 12

    /// Max scrollback lines kept by SwiftTerm per session. Lower = less RAM,
    /// higher = more scrollback history in-client. Server's ring buffer
    /// replays anything that fell off this edge on next attach.
    @AppStorage("terminalScrollbackLines") var terminalScrollbackLines: Int = 5_000

    @AppStorage("recordingShortcutEnabled") var recordingShortcutEnabled = true
    @AppStorage("recordingShortcutFlags") var recordingShortcutFlags: Int = Int(UIKeyModifierFlags([.command, .alternate]).rawValue)
    @AppStorage("recordingShortcutKey") var recordingShortcutKey = ""

    // MARK: - Prompt optimizer (spec §7.1)

    /// Sent as `shareScreen` on every `optimize_prompt`. Per device, default on.
    @AppStorage("shareScreenWithOptimizer") var shareScreenWithOptimizer = true

    // MARK: - Speech-removal migration (spec §7.2)

    static let speechRemovalMigrationKey = "speechRemovalMigrationDone"

    /// Every `@AppStorage` key the speech feature ever wrote on iOS, plus the
    /// old `SpeechModelStore` ready flag.
    static let legacySpeechDefaultsKeys = [
        "smartCleanupEnabled",
        "promptEnhancementEnabled",
        "bedrockRegion",
        "bedrockBearerToken",
        "continuousListeningEnabled",
        "wakeWord",
        "speechModelStore.whisperDownloaded",
    ]

    /// Where `SpeechModelStore` kept the downloaded LLM weights on iOS.
    static var legacySpeechModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Models", isDirectory: true)
    }

    /// Where the Whisper CoreML weights actually landed. `SpeechModelStore`
    /// called `WhisperKit.download(variant:progressCallback:)` with **no**
    /// `downloadBase`, and WhisperKit's HubApi defaults that to
    /// `Documents/huggingface` — not the directory above. A few hundred MB, in
    /// the user-visible `Documents` container and in backups, so the scrub has
    /// to name it explicitly.
    static var legacyWhisperHubDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("huggingface", isDirectory: true)
    }

    /// Every directory the removed speech stack could have written weights to.
    static var legacySpeechDirectories: [URL] {
        [legacySpeechModelsDirectory, legacyWhisperHubDirectory]
    }

    /// iOS wiring of the shared one-time cleanup (see `SpeechRemovalMigration`).
    @discardableResult
    static func migrateSpeechRemoval(
        defaults: UserDefaults,
        directories: [URL],
        deleteBedrockToken: () throws -> Void
    ) -> Bool {
        SpeechRemovalMigration.run(
            defaults: defaults,
            doneKey: speechRemovalMigrationKey,
            legacyKeys: legacySpeechDefaultsKeys,
            directories: directories,
            deleteBedrockToken: deleteBedrockToken
        )
    }
}

// MARK: - Keyboard Shortcut Helpers

extension UIKeyModifierFlags {
    /// Human-readable symbol string, e.g. "⌃⌥⇧⌘"
    /// Order follows Apple HIG: Control, Option, Shift, Command
    var symbolString: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.alternate) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
}

extension AppSettings {
    var shortcutModifierFlags: UIKeyModifierFlags {
        get { UIKeyModifierFlags(rawValue: Int(recordingShortcutFlags)) }
        set { recordingShortcutFlags = Int(newValue.rawValue) }
    }

    /// Display string for the current shortcut, e.g. "⌘⌥" or "⌘⌥R"
    var shortcutDisplayString: String {
        let mods = shortcutModifierFlags.symbolString
        let key = recordingShortcutKey.uppercased()
        return mods + key
    }
}

// MARK: - Session Naming Themes
//
// `SessionNamingTheme` is defined in `CodeRelayClient` so iOS and Mac share
// the same type, raw values, and name pools.
