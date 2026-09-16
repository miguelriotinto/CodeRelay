import Foundation

// MARK: - OptimizerBudget

/// Per-token budget on `optimize_prompt`, the one request in this server that
/// spends the operator's money (review B-3).
///
/// `optimizeInFlight` is a *concurrency* guard, not a budget: it is per
/// connection and cleared before the reply is even written, so a retry-looping
/// client — or a device token lifted off a lost phone — can bill a
/// Sonnet-class call per round trip, on as many sockets as it likes.
/// `maxSessionsPerToken` bounds sessions, not sockets. This bounds the token.
///
/// Shape borrowed wholesale from `RateLimiter`: a rolling window per key, an
/// LRU cap on how many keys are tracked at all, and no persistence (a restart
/// forgives everyone, which is the right failure mode for a cost bound). Two
/// deliberate differences:
///
/// - **Synchronous, `NSLock`-guarded, not an actor.** The check has to sit
///   between the `optimizer != nil` guard and `optimizeInFlight = true`, and
///   both of those are event-loop state. An `await` there would hand two
///   frames that arrive in the same read a window where neither has set the
///   in-flight flag yet — the check meant to *stop* a second paid call would
///   have created one. `LogStore` uses `NSLock` for the same reason.
/// - **No per-key retention bound is needed.** A timestamp is only appended
///   when the window holds fewer than `maxPerWindow`, so the array is capped
///   by construction — `RateLimiter.recordFailure` has to drop its oldest
///   entry because it records failures it has already decided to block on.
public final class OptimizerBudget: @unchecked Sendable {
    private struct Entry {
        var timestamps: [Date]
        var lastAccess: Date
    }

    /// The shipped bound: 20 optimizes per token per rolling minute. Lives here
    /// rather than on `RelayMessageHandler` (which names it as
    /// `maxOptimizesPerMinutePerToken`, next to `maxPushMutations`) only because a
    /// `public` initialiser's default argument cannot reference an internal type.
    public static let defaultMaxPerWindow = 20

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let maxPerWindow: Int
    private let windowSeconds: TimeInterval
    private let maxTrackedTokens: Int

    // MARK: - Init

    /// - Parameters:
    ///   - maxPerWindow: allowed calls per window per token.
    ///   - windowSeconds: the rolling window.
    ///   - maxTrackedTokens: LRU cap on tracked tokens, mirroring
    ///     `RateLimiter.maxTrackedIPs` — a token id is client-supplied in the
    ///     sense that a bad one is never authenticated, but the map still must
    ///     not grow with connection churn.
    public init(maxPerWindow: Int = OptimizerBudget.defaultMaxPerWindow,
                windowSeconds: TimeInterval = 60,
                maxTrackedTokens: Int = 10_000) {
        self.maxPerWindow = maxPerWindow
        self.windowSeconds = windowSeconds
        self.maxTrackedTokens = maxTrackedTokens
    }

    // MARK: - Public API

    /// Charge one optimize to `tokenId`. Returns `false` — and charges nothing —
    /// when the token has already spent `maxPerWindow` inside the window, so a
    /// refused client cannot push its own window forward by retrying.
    public func allow(tokenId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let cutoff = now.addingTimeInterval(-windowSeconds)
        var entry = entries[tokenId] ?? Entry(timestamps: [], lastAccess: now)
        // Appended chronologically, so the expired ones are a prefix.
        entry.timestamps.removeAll { $0 < cutoff }
        entry.lastAccess = now
        guard entry.timestamps.count < maxPerWindow else {
            entries[tokenId] = entry
            return false
        }
        entry.timestamps.append(now)
        entries[tokenId] = entry
        evictIfNeeded()
        return true
    }

    // MARK: - Private

    /// Drop the oldest 10% by `lastAccess` once we are 10% past the cap, so the
    /// sort amortizes over ~`maxTrackedTokens / 10` insertions instead of firing
    /// on every call past the soft cap (same arithmetic as `RateLimiter`).
    private func evictIfNeeded() {
        let evictCount = max(1, maxTrackedTokens / 10)
        guard entries.count > maxTrackedTokens + evictCount else { return }
        let sorted = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (token, _) in sorted.prefix(evictCount) {
            entries.removeValue(forKey: token)
        }
    }

    // MARK: - Test Hooks

    /// Exposed only for tests. Do not call from production code.
    public var _testOnly_trackedTokenCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
