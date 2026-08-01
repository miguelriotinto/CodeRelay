import Foundation
import ClaudeRelayKit

/// A grant issued by `PairingCodeStore.mint` and returned by a successful
/// `redeem`.
public struct PairingGrant: Sendable, Equatable {
    public let code: String
    public let label: String?
    public let expiresAt: Date
}

/// Holds the short-lived, single-use pairing codes that a device exchanges for
/// a real auth token.
///
/// **In-memory by design.** Codes live ~5 minutes; persisting them would keep a
/// credential on disk for no benefit and let one survive a restart. A
/// consequence is that this store must be created **once** in `main.swift` and
/// injected into both the admin route (which mints) and every WebSocket handler
/// (which redeems) — a per-connection instance would never see a minted code.
public actor PairingCodeStore {

    private struct Entry {
        let label: String?
        let expiresAt: Date
        /// Mint order, used to evict the oldest when at capacity.
        let sequence: UInt64
    }

    private let ttl: TimeInterval
    private let maxPending: Int
    private let now: @Sendable () -> Date

    private var entries: [String: Entry] = [:]
    private var nextSequence: UInt64 = 0

    public init(
        ttl: TimeInterval = 300,
        maxPending: Int = 8,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.ttl = ttl
        self.maxPending = maxPending
        self.now = now
    }

    /// Mints a fresh code. Sweeps expired entries first, then evicts the oldest
    /// if still at capacity.
    public func mint(label: String?) -> PairingGrant {
        sweepExpired()

        while entries.count >= maxPending {
            guard let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key else { break }
            entries.removeValue(forKey: oldest)
        }

        var code = PairingCode.generate()
        // Astronomically unlikely, but a collision would silently overwrite a
        // pending grant, so re-roll instead.
        while entries[code] != nil { code = PairingCode.generate() }

        let expiresAt = now().addingTimeInterval(ttl)
        entries[code] = Entry(label: label, expiresAt: expiresAt, sequence: nextSequence)
        nextSequence += 1
        return PairingGrant(code: code, label: label, expiresAt: expiresAt)
    }

    /// Redeems a code, removing it. Returns nil if the code is malformed,
    /// unknown, or expired. Accepts hyphenated/lowercase user input.
    public func redeem(_ input: String) -> PairingGrant? {
        guard let code = PairingCode.normalize(input) else { return nil }
        guard let entry = entries[code] else { return nil }
        entries.removeValue(forKey: code)
        guard entry.expiresAt > now() else { return nil }
        return PairingGrant(code: code, label: entry.label, expiresAt: entry.expiresAt)
    }

    public func pendingCount() -> Int {
        sweepExpired()
        return entries.count
    }

    private func sweepExpired() {
        let cutoff = now()
        entries = entries.filter { $0.value.expiresAt > cutoff }
    }
}
