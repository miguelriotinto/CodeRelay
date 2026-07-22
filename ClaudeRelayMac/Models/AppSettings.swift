import SwiftUI
import Combine
import ClaudeRelayClient
import ClaudeRelaySpeech

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private init() {
        migrateBedrockTokenIfNeeded()
        // Seed from the Keychain (or legacy UserDefaults if migration failed).
        self.bedrockBearerToken = loadBedrockTokenWithFallback()
        // Debounce Keychain writes so rapid keystrokes collapse into a single
        // save. `dropFirst()` skips the seed value we just wrote above.
        $bedrockBearerToken
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { token in
                try? AuthManager.shared.saveBedrockToken(token)
            }
            .store(in: &bedrockTokenSubscriptions)
    }

    /// Legacy `UserDefaults` key that held the Bedrock token before the
    /// Keychain migration. Also read as a fallback when Keychain ops fail.
    static let legacyBedrockKey = "com.clauderelay.mac.bedrockBearerToken"

    private func migrateBedrockTokenIfNeeded() {
        Self.migrateBedrockToken(
            defaults: UserDefaults.standard,
            legacyKey: Self.legacyBedrockKey,
            keychainLoad: { try AuthManager.shared.loadBedrockToken() },
            keychainSave: { try AuthManager.shared.saveBedrockToken($0) }
        )
    }

    private func loadBedrockTokenWithFallback() -> String {
        Self.loadBedrockToken(
            defaults: UserDefaults.standard,
            legacyKey: Self.legacyBedrockKey,
            keychainLoad: { try AuthManager.shared.loadBedrockToken() }
        )
    }

    /// Pure migration helper. See iOS `AppSettings.migrateBedrockToken` for
    /// the rationale — identical behaviour; only the legacy key differs.
    static func migrateBedrockToken(
        defaults: UserDefaults,
        legacyKey: String,
        keychainLoad: () throws -> String?,
        keychainSave: (String) throws -> Void
    ) {
        guard let legacy = defaults.string(forKey: legacyKey),
              !legacy.isEmpty else { return }
        if let existing = try? keychainLoad(), !existing.isEmpty {
            defaults.removeObject(forKey: legacyKey)
            return
        }
        do {
            try keychainSave(legacy)
            if let reread = try? keychainLoad(), reread == legacy {
                defaults.removeObject(forKey: legacyKey)
            }
        } catch {
            // Keep legacy copy so the user's token isn't lost.
        }
    }

    static func loadBedrockToken(
        defaults: UserDefaults,
        legacyKey: String,
        keychainLoad: () throws -> String?
    ) -> String {
        if let keychain = try? keychainLoad(), !keychain.isEmpty {
            return keychain
        }
        return defaults.string(forKey: legacyKey) ?? ""
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

    @AppStorage("com.clauderelay.mac.smartCleanupEnabled") var smartCleanupEnabled = true
    @AppStorage("com.clauderelay.mac.promptEnhancementEnabled") var promptEnhancementEnabled = false
    @AppStorage("com.clauderelay.mac.continuousListeningEnabled") var continuousListeningEnabled = false
    @AppStorage("com.clauderelay.mac.wakeWord") var wakeWord: String = "claude"
    @AppStorage("com.clauderelay.mac.bedrockRegion") var bedrockRegion = "us-east-1"

    /// Bedrock bearer token, persisted in the Keychain. Seeded at init;
    /// writes are debounced 500 ms before the Keychain save fires so rapid
    /// typing in a `SecureField` collapses into one write. Returns `""`
    /// when the Keychain is empty — callers treat empty as "not configured".
    @Published var bedrockBearerToken: String = ""

    /// Combine subscription store for the debounced Keychain save.
    private var bedrockTokenSubscriptions = Set<AnyCancellable>()

    @AppStorage("com.clauderelay.mac.terminalFontSize") var terminalFontSize: Double = 12

    /// Max scrollback lines kept by SwiftTerm per session. Lower = less RAM,
    /// higher = more scrollback history in-client. Server's ring buffer
    /// replays anything that fell off this edge on next attach.
    @AppStorage("com.clauderelay.mac.terminalScrollbackLines") var terminalScrollbackLines: Int = 5_000

    @AppStorage("com.clauderelay.mac.recordingShortcutEnabled") var recordingShortcutEnabled = true
    @AppStorage("com.clauderelay.mac.recordingShortcutModifiers")
    var recordingShortcutModifiers: Int = Int(NSEvent.ModifierFlags([.command, .option]).rawValue)
    @AppStorage("com.clauderelay.mac.recordingShortcutKey") var recordingShortcutKey = ""

    func currentSpeechOptions() -> SpeechProcessingOptions {
        SpeechProcessingOptions(
            smartCleanupEnabled: smartCleanupEnabled,
            promptEnhancementEnabled: promptEnhancementEnabled,
            bedrockBearerToken: bedrockBearerToken,
            bedrockRegion: bedrockRegion,
            wakeWord: wakeWord
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
