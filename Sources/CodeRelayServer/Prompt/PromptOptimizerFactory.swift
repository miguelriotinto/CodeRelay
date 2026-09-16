import Foundation
import NIOCore
import AsyncHTTPClient
import CodeRelayKit

/// Builds the relay's `PromptOptimizing` once at startup (spec §8).
///
/// Nil means "no capability": disabled (silent), or enabled but unusable — in
/// which case exactly one error-level line names the reason. The decision is not
/// revisited at runtime; fixing the config means restarting the relay.
enum PromptOptimizerFactory {

    enum KeyError: Error, CustomStringConvertible {
        case notRegularFile(String)
        case tooLarge(String)
        case unreadable(String)
        case empty(String)
        case invalidCharacters(String)

        var description: String {
            switch self {
            case .notRegularFile(let path): return "promptOptimizerKeyPath is not a regular file: \(path)"
            case .tooLarge(let path): return "promptOptimizerKeyPath exceeds 64 KB: \(path)"
            case .unreadable(let path): return "promptOptimizerKeyPath not readable: \(path)"
            case .empty(let path): return "promptOptimizerKeyPath is empty: \(path)"
            case .invalidCharacters(let path): return "promptOptimizerKeyPath contains whitespace or control characters: \(path)"
            }
        }
    }

    static func make(config: RelayConfig, group: EventLoopGroup,
                     out httpClient: inout HTTPClient?) -> (any PromptOptimizing)? {
        guard config.promptOptimizerEnabled else { return nil }

        guard let keyPath = config.promptOptimizerKeyPath, !keyPath.isEmpty else {
            RelayLogger.log(.error, category: "optimizer",
                "promptOptimizerEnabled is true but promptOptimizerKeyPath is not set; optimizer disabled")
            return nil
        }

        let apiKey: String
        let endpoint: MessagesEndpoint
        do {
            apiKey = try readKey(atPath: keyPath)
            endpoint = try MessagesEndpoint.resolve(provider: config.promptOptimizerProvider,
                                                    region: config.promptOptimizerRegion)
        } catch let error as OptimizerError {
            RelayLogger.log(.error, category: "optimizer", "\(error.clientMessage): \(error); optimizer disabled")
            return nil
        } catch {
            RelayLogger.log(.error, category: "optimizer", "\(PushHTTP.redact("\(error)")); optimizer disabled")
            return nil
        }

        let client = HTTPClient(eventLoopGroupProvider: .shared(group))
        httpClient = client
        // One deadline for the whole call: the request timeout is derived from
        // `PromptOptimizer.deadline`, so the two can never drift apart.
        // maxRetries 0 for the same reason — a retry would blow through it.
        let http = PushHTTP(client: client,
                            requestTimeout: .seconds(PromptOptimizer.deadline.components.seconds),
                            maxRetries: 0)
        let model = config.promptOptimizerModel ?? endpoint.defaultModel
        RelayLogger.log(category: "optimizer",
            "Prompt optimizer enabled (provider=\(config.promptOptimizerProvider) model=\(model) "
            + "shareScreen=\(config.promptOptimizerShareScreen))")
        return PromptOptimizer(
            client: HTTPMessagesClient(http: http, endpoint: endpoint, apiKey: apiKey,
                                       provider: config.promptOptimizerProvider, model: model),
            model: model,
            sharesScreen: config.promptOptimizerShareScreen)
    }

    /// Reads and trims the API key. Logs (but proceeds) when the file is
    /// readable by others. Never logs the key itself.
    static func readKey(atPath path: String) throws -> String {
        // `attributesOfItem` does not follow symlinks, so a key kept in a
        // dotfile repo and linked into place (`~/.claude-relay/key ->
        // ~/dotfiles/secrets/key`) used to be rejected as "not a regular file".
        // Resolve first and check the target: the type, size and mode that
        // matter are the file's — a symlink's own mode is 0o755 and means
        // nothing (review A-8).
        let expanded = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .resolvingSymlinksInPath().path

        // Check file type and size before reading.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expanded) else {
            throw KeyError.unreadable(path)
        }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else {
            throw KeyError.notRegularFile(path)
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= 64 * 1024 else {
            throw KeyError.tooLarge(path)
        }

        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw KeyError.unreadable(path)
        }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw KeyError.empty(path) }

        // Reject keys with interior whitespace or control characters.
        for scalar in key.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                throw KeyError.invalidCharacters(path)
            }
        }

        // Log (but proceed) when the file is readable by others. Only emitted
        // when the key is otherwise accepted.
        if let mode = (attrs[.posixPermissions] as? NSNumber)?.int16Value,
           mode & 0o077 != 0 {
            RelayLogger.log(.error, category: "optimizer",
                "promptOptimizerKeyPath \(path) is readable by others (mode \(String(mode, radix: 8))); chmod 600 it")
        }

        return key
    }
}
