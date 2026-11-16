import SwiftUI
import UIKit
import CodeRelayClient

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private init() {
        AppSettings.removeOptimizerSettings(defaults: .standard)
        AppSettings.migrateSpeechRemoval(
            defaults: .standard,
            directories: AppSettings.legacySpeechDirectories,
            deleteBedrockToken: { try AuthManager.shared.deleteBedrockToken() }
        )
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

    // MARK: - Prompt-optimizer removal

    /// Every key the removed prompt optimizer wrote on iOS: its screen-sharing
    /// toggle and its hardware-keyboard shortcut (which kept the older
    /// `recordingShortcut*` names from the speech feature before it, including
    /// the pre-flags `recordingShortcutModifier`).
    static let legacyOptimizerDefaultsKeys = [
        "shareScreenWithOptimizer",
        "recordingShortcutEnabled",
        "recordingShortcutFlags",
        "recordingShortcutKey",
        "recordingShortcutModifier",
    ]

    /// Drops the optimizer's stored settings. Runs on every launch: removing an
    /// absent key is a no-op, so there is nothing to retry and no done flag.
    static func removeOptimizerSettings(defaults: UserDefaults) {
        for key in legacyOptimizerDefaultsKeys { defaults.removeObject(forKey: key) }
    }

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

// MARK: - Session Naming Themes
//
// `SessionNamingTheme` is defined in `CodeRelayClient` so iOS and Mac share
// the same type, raw values, and name pools.
