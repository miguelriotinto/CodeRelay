import Foundation
import ClaudeRelayKit

/// Manages token CRUD operations with JSON file persistence (serialized via
/// actor isolation; writes are atomic).
public actor TokenStore {

    // MARK: - Properties

    private let directory: URL
    private var filePath: URL { directory.appendingPathComponent("tokens.json") }
    private var tokens: [TokenInfo]?
    private var lastUsedDirty = false
    private var flushTask: Task<Void, Never>?
    private static let flushInterval: Duration = .seconds(30)

    // MARK: - Errors

    public enum TokenStoreError: Error, LocalizedError {
        case tokenNotFound(id: String)
        case tokenExpired(id: String)

        public var errorDescription: String? {
            switch self {
            case .tokenNotFound(let id):
                return "Token with id '\(id)' not found."
            case .tokenExpired(let id):
                return "Token with id '\(id)' has expired."
            }
        }
    }

    // MARK: - Init

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Public API

    // Invariant for `create`/`delete`/`rotate`/`rename`: mutate a LOCAL copy
    // first, `try save(...)`, and only assign `self.tokens = ...` after the
    // save succeeds. If `save` throws, the in-memory cache stays consistent
    // with disk. Never write `self.tokens` before `save` — a silent disk
    // failure would otherwise leave the cache ahead of the persisted state,
    // which is recovered on next restart.

    /// Generate a new token, persist it, and return the plaintext + info.
    public func create(label: String?, expiryDays: Int? = nil) throws -> (plaintext: String, info: TokenInfo) {
        let loaded = try ensureLoaded()
        let (plaintext, info) = TokenGenerator.generate(label: label, expiryDays: expiryDays)
        var mutable = loaded
        mutable.append(info)
        try save(mutable)
        tokens = mutable
        clearDirtyState()
        return (plaintext, info)
    }

    /// Validate a plaintext token against stored hashes. Updates `lastUsedAt` in memory
    /// and defers the disk write to avoid I/O on every authentication.
    /// Returns `nil` if the token is not found or has expired.
    public func validate(token: String) -> TokenInfo? {
        let loaded = (try? ensureLoaded()) ?? []
        let hash = TokenGenerator.hash(token)
        guard let index = loaded.firstIndex(where: { $0.tokenHash == hash }) else {
            return nil
        }
        if loaded[index].isExpired {
            return nil
        }
        var mutable = loaded
        mutable[index].lastUsedAt = Date()
        tokens = mutable
        scheduleDirtyFlush()
        return mutable[index]
    }

    /// Return all stored token infos.
    public func list() -> [TokenInfo] {
        (try? ensureLoaded()) ?? []
    }

    /// Remove a token by id.
    public func delete(id: String) throws {
        var loaded = try ensureLoaded()
        guard let index = loaded.firstIndex(where: { $0.id == id }) else {
            throw TokenStoreError.tokenNotFound(id: id)
        }
        loaded.remove(at: index)
        try save(loaded)
        tokens = loaded
        clearDirtyState()
    }

    /// Rotate a token: generate new plaintext/hash but keep id, label, createdAt.
    public func rotate(id: String) throws -> (plaintext: String, info: TokenInfo) {
        var loaded = try ensureLoaded()
        guard let index = loaded.firstIndex(where: { $0.id == id }) else {
            throw TokenStoreError.tokenNotFound(id: id)
        }
        let existing = loaded[index]
        let (newPlaintext, generated) = TokenGenerator.generate(label: existing.label)

        let rotated = TokenInfo(
            id: existing.id,
            tokenHash: generated.tokenHash,
            label: existing.label,
            createdAt: existing.createdAt,
            lastUsedAt: nil,
            expiresAt: existing.expiresAt
        )

        loaded[index] = rotated
        try save(loaded)
        tokens = loaded
        clearDirtyState()
        return (newPlaintext, rotated)
    }

    /// Rename a token's label.
    public func rename(id: String, label: String) throws -> TokenInfo {
        var loaded = try ensureLoaded()
        guard let index = loaded.firstIndex(where: { $0.id == id }) else {
            throw TokenStoreError.tokenNotFound(id: id)
        }
        loaded[index].label = label
        try save(loaded)
        tokens = loaded
        clearDirtyState()
        return loaded[index]
    }

    /// Return a single token info by id.
    public func inspect(id: String) throws -> TokenInfo {
        let loaded = try ensureLoaded()
        guard let info = loaded.first(where: { $0.id == id }) else {
            throw TokenStoreError.tokenNotFound(id: id)
        }
        return info
    }

    /// Flush any pending lastUsedAt changes to disk. Call on server shutdown.
    /// Cancels the scheduled dirty-flush task up-front so it cannot race us
    /// or outlive the actor after shutdownGracefully returns.
    ///
    /// If the save throws (disk full, permission flip), the dirty flag STAYS
    /// set — the next successful mutation will re-attempt. Silently clearing
    /// the dirty flag on failure would strand unsaved lastUsedAt updates
    /// until the next explicit write to the store.
    public func flushIfDirty() {
        flushTask?.cancel()
        flushTask = nil
        guard lastUsedDirty, let tokens = tokens else { return }
        do {
            try save(tokens)
            lastUsedDirty = false
        } catch {
            RelayLogger.log(.error, category: "tokens",
                "flushIfDirty: save failed, keeping dirty flag: \(error)")
        }
    }

    // MARK: - Private Helpers

    private func scheduleDirtyFlush() {
        lastUsedDirty = true
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            guard !Task.isCancelled else { return }
            await self?.performDirtyFlush()
        }
    }

    /// Background flush path. Same rule as `flushIfDirty`: on save failure,
    /// we keep the dirty flag set so a subsequent mutation or `flushIfDirty`
    /// call gets another chance to persist. `flushTask` is cleared either way
    /// so a new dirty write can schedule a fresh sleep window.
    private func performDirtyFlush() {
        guard lastUsedDirty, let tokens = tokens else { return }
        do {
            try save(tokens)
            lastUsedDirty = false
        } catch {
            RelayLogger.log(.error, category: "tokens",
                "performDirtyFlush: save failed, will retry on next write: \(error)")
        }
        flushTask = nil
    }

    /// Called after a full save — cancels any pending dirty flush since the data is already on disk.
    private func clearDirtyState() {
        lastUsedDirty = false
        flushTask?.cancel()
        flushTask = nil
    }

    /// Lazy-load tokens from disk on first access.
    private func ensureLoaded() throws -> [TokenInfo] {
        if let tokens = tokens {
            return tokens
        }
        let loaded = try loadFromDisk()
        tokens = loaded
        return loaded
    }

    /// Read tokens from disk. Actor isolation guarantees single-threaded access.
    private func loadFromDisk() throws -> [TokenInfo] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard fm.fileExists(atPath: filePath.path) else {
            return []
        }
        let data = try Data(contentsOf: filePath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([TokenInfo].self, from: data)
    }

    /// Write tokens to disk atomically. Actor isolation guarantees single-threaded access.
    private func save(_ infos: [TokenInfo]) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(infos)
        try data.write(to: filePath, options: .atomic)
    }

    // MARK: - Test Hooks

    /// Exposed only for tests. Reads the internal dirty flag so tests can
    /// verify flushIfDirty clears it synchronously. Do not call from production.
    public var _testOnly_isDirty: Bool { lastUsedDirty }
}
