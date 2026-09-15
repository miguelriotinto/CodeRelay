import Foundation

/// One-time first-launch cleanup after voice transcription was removed from
/// the apps (spec §7.2). Each app passes its own `@AppStorage` key list, done
/// flag, and the directories the old speech stack downloaded weights into; the
/// keychain delete is injected so tests never touch the real keychain.
///
/// `directories` is a list, not one path, because the two model families did
/// not share a home: the LLM weights sat in `SpeechModelStore`'s own directory,
/// while WhisperKit put the Whisper CoreML weights under its HubApi default
/// (`Documents/huggingface`). Deleting only the first left the larger of the two
/// behind forever, since this migration is now the only code path that can
/// remove either.
///
/// Returns `true` when the migration ran to completion in this call; `false`
/// when it had already run, or when a step failed — in which case the done
/// flag stays unset so the next launch retries. Removing defaults and deleting
/// the directories are best-effort and happen regardless of the keychain
/// result; a directory that is not present is not a failure.
public enum SpeechRemovalMigration {
    @discardableResult
    public static func run(
        defaults: UserDefaults,
        doneKey: String,
        legacyKeys: [String],
        directories: [URL],
        fileManager: FileManager = .default,
        deleteBedrockToken: () throws -> Void
    ) -> Bool {
        guard !defaults.bool(forKey: doneKey) else { return false }
        for key in legacyKeys { defaults.removeObject(forKey: key) }

        var succeeded = true
        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            do { try fileManager.removeItem(at: directory) } catch { succeeded = false }
        }
        do { try deleteBedrockToken() } catch { succeeded = false }

        if succeeded { defaults.set(true, forKey: doneKey) }
        return succeeded
    }
}
