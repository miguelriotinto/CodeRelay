import Foundation
import CodeRelayKit

/// Mints and persists the relay's `ServerIdentity` (multi-server spec §6.1).
///
/// The id lives in `instance.json` next to `config.json` and `tokens.json`;
/// it is created on first start and reused forever after. The name is **not**
/// persisted: it is resolved at every startup from the `serverName` config key
/// (sanitised like a pairing label) or, when unset, the host name — so renaming
/// a machine renames the relay without touching its identity.
///
/// `load` never throws. Like `ConfigManager.load()`, a corrupt file is worse
/// to die on than to replace: the old id is lost (clients re-learn it on their
/// next handshake), an error is logged, and a fresh id is written in its place.
enum ServerIdentityStore {

    private struct Persisted: Codable {
        let id: UUID
        let createdAt: Date
    }

    static let fileName = "instance.json"
    static let fallbackName = "CodeRelay"

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load(directory: URL = RelayConfig.configDirectory,
                     configuredName: String?,
                     hostName: String = ProcessInfo.processInfo.hostName) -> ServerIdentity {
        let file = directory.appendingPathComponent(fileName)
        let name = resolveName(configured: configuredName, hostName: hostName)
        let fm = FileManager.default

        if fm.fileExists(atPath: file.path) {
            do {
                let persisted = try decoder.decode(Persisted.self, from: Data(contentsOf: file))
                return ServerIdentity(id: persisted.id, name: name)
            } catch {
                RelayLogger.log(.error, category: "server",
                    "instance.json at \(file.path) is unreadable (\(error)); minting a new server id")
            }
        }

        let minted = Persisted(id: UUID(), createdAt: Date())
        do {
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try encoder.encode(minted).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            RelayLogger.log(category: "server", "Minted server id \(minted.id.uuidString)")
        } catch {
            // Still return a usable identity for this process; the next start
            // will try to persist again.
            RelayLogger.log(.error, category: "server",
                "Could not persist instance.json at \(file.path): \(error)")
        }
        return ServerIdentity(id: minted.id, name: name)
    }

    /// `serverName` when it survives sanitising, else the host name without a
    /// trailing `.local`, else `"CodeRelay"`.
    static func resolveName(configured: String?, hostName: String) -> String {
        if let configured {
            let clean = LabelSanitizer.sanitize(configured)
            if !clean.isEmpty { return clean }
        }
        var host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasSuffix(".local") { host.removeLast(".local".count) }
        let clean = LabelSanitizer.sanitize(host)
        return clean.isEmpty ? fallbackName : clean
    }
}
