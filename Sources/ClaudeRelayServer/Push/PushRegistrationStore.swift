import Foundation
import ClaudeRelayKit

/// Persists device push registrations per relay token, so a push only reaches
/// devices owned by the token that owns the session. Bounded (per-token +
/// global caps), TTL-reaped, and written atomically with `0o600` permissions
/// (device tokens are secrets). Clock is injected for deterministic TTL tests.
public actor PushRegistrationStore {
    private let directory: URL
    private let maxPerToken: Int
    private let maxTotal: Int
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    private var filePath: URL { directory.appendingPathComponent("push-tokens.json") }

    /// tokenId → its device registrations (insertion order = eviction order).
    private var byToken: [String: [PushRegistration]] = [:]
    private var loaded = false

    public init(directory: URL, maxPerToken: Int = 20, maxTotal: Int = 5000,
                ttl: TimeInterval = 90 * 24 * 3600, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.maxPerToken = max(1, maxPerToken)
        self.maxTotal = max(1, maxTotal)
        self.ttl = ttl
        self.now = now
    }

    // MARK: - Mutations

    /// Insert or replace (by `deviceId`) a registration for `tokenId`. Evicts the
    /// oldest per-token entry over `maxPerToken`; drops the globally-oldest over
    /// `maxTotal`.
    public func upsert(_ registration: PushRegistration, forTokenId tokenId: String) {
        ensureLoaded()
        var list = byToken[tokenId] ?? []
        list.removeAll { $0.deviceId == registration.deviceId }
        list.append(registration)
        // Per-token cap: drop oldest by updatedAt.
        if list.count > maxPerToken {
            list.sort { $0.updatedAt < $1.updatedAt }
            list.removeFirst(list.count - maxPerToken)
        }
        byToken[tokenId] = list
        enforceGlobalCap()
        persist()
    }

    /// Update only the delivery preferences of an existing device registration.
    public func setPreferences(deviceId: String, forTokenId tokenId: String,
                               enabled: Bool, notifyOnFinished: Bool) {
        ensureLoaded()
        guard var list = byToken[tokenId], let idx = list.firstIndex(where: { $0.deviceId == deviceId })
        else { return }
        list[idx].enabled = enabled
        list[idx].notifyOnFinished = notifyOnFinished
        list[idx].updatedAt = now()
        byToken[tokenId] = list
        persist()
    }

    /// Remove one device's registration under a specific token.
    public func remove(deviceId: String, forTokenId tokenId: String) {
        ensureLoaded()
        guard var list = byToken[tokenId] else { return }
        list.removeAll { $0.deviceId == deviceId }
        if list.isEmpty { byToken[tokenId] = nil } else { byToken[tokenId] = list }
        persist()
    }

    /// Purge a dead device token across ALL relay tokens (APNs/FCM 410 feedback).
    public func removeToken(_ token: String) {
        ensureLoaded()
        for key in byToken.keys {
            byToken[key]?.removeAll { $0.token == token }
            if byToken[key]?.isEmpty == true { byToken[key] = nil }
        }
        persist()
    }

    // MARK: - Reads

    /// Non-expired registrations for a relay token.
    public func registrations(forTokenId tokenId: String) -> [PushRegistration] {
        ensureLoaded()
        let cutoff = now().addingTimeInterval(-ttl)
        return (byToken[tokenId] ?? []).filter { $0.updatedAt >= cutoff }
    }

    /// Drop expired registrations across all tokens. Called on a timer.
    public func reap() {
        ensureLoaded()
        let cutoff = now().addingTimeInterval(-ttl)
        var changed = false
        for key in byToken.keys {
            let before = byToken[key]?.count ?? 0
            byToken[key]?.removeAll { $0.updatedAt < cutoff }
            if byToken[key]?.isEmpty == true { byToken[key] = nil }
            if (byToken[key]?.count ?? 0) != before { changed = true }
        }
        if changed { persist() }
    }

    /// Force a synchronous write (used by tests / shutdown).
    public func flush() { persist() }

    // MARK: - Internals

    private func enforceGlobalCap() {
        var total = byToken.values.reduce(0) { $0 + $1.count }
        guard total > maxTotal else { return }
        // Evict globally-oldest registrations until under the cap.
        var all: [(tokenId: String, reg: PushRegistration)] = []
        for (key, list) in byToken { for reg in list { all.append((key, reg)) } }
        all.sort { $0.reg.updatedAt < $1.reg.updatedAt }
        var idx = 0
        while total > maxTotal, idx < all.count {
            let victim = all[idx]
            byToken[victim.tokenId]?.removeAll { $0.deviceId == victim.reg.deviceId && $0.token == victim.reg.token }
            if byToken[victim.tokenId]?.isEmpty == true { byToken[victim.tokenId] = nil }
            total -= 1
            idx += 1
        }
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: filePath) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: [PushRegistration]].self, from: data) {
            byToken = decoded
        }
    }

    private func persist() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(byToken) else { return }
        try? data.write(to: filePath, options: .atomic)
        // Device tokens are secrets — restrict to owner read/write.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath.path)
    }
}
