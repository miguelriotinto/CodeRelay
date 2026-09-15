import Foundation

/// One-time first-launch cleanup after voice transcription was removed from
/// the apps (spec §7.2). Each app passes its own `@AppStorage` key list, done
/// flag, and `SpeechModelStore` directory; the keychain delete is injected so
/// tests never touch the real keychain.
///
/// Returns `true` when the migration ran to completion in this call; `false`
/// when it had already run, or when a step failed — in which case the done
/// flag stays unset so the next launch retries. Removing defaults and deleting
/// the directory are best-effort and happen regardless of the keychain result.
public enum SpeechRemovalMigration {
    @discardableResult
    public static func run(
        defaults: UserDefaults,
        doneKey: String,
        legacyKeys: [String],
        modelsDirectory: URL,
        fileManager: FileManager = .default,
        deleteBedrockToken: () throws -> Void
    ) -> Bool {
        guard !defaults.bool(forKey: doneKey) else { return false }
        for key in legacyKeys { defaults.removeObject(forKey: key) }

        var succeeded = true
        if fileManager.fileExists(atPath: modelsDirectory.path) {
            do { try fileManager.removeItem(at: modelsDirectory) } catch { succeeded = false }
        }
        do { try deleteBedrockToken() } catch { succeeded = false }

        if succeeded { defaults.set(true, forKey: doneKey) }
        return succeeded
    }
}
