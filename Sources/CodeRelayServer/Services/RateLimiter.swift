import Foundation

// MARK: - RateLimiter

/// Tracks failed authentication attempts per IP address and blocks IPs that
/// exceed the threshold within a rolling time window. Capped at
/// `maxTrackedIPs` with LRU eviction to prevent unbounded memory growth
/// under sustained scanning traffic.
/// In-memory only; all state resets on process restart.
public actor RateLimiter {
    private struct Entry {
        var timestamps: [Date]
        var lastAccess: Date
    }

    private var attempts: [String: Entry] = [:]
    private let maxAttempts: Int
    private let windowSeconds: TimeInterval
    private let maxTrackedIPs: Int

    // MARK: - Init

    public init(maxAttempts: Int = 5,
                windowSeconds: TimeInterval = 60,
                maxTrackedIPs: Int = 10_000) {
        self.maxAttempts = maxAttempts
        self.windowSeconds = windowSeconds
        self.maxTrackedIPs = maxTrackedIPs
    }

    // MARK: - Public API

    /// Record a failed authentication attempt for the given IP.
    /// Returns `true` if the IP should now be blocked (threshold reached).
    ///
    /// NOTE: `recordFailure(ip:)` may return `true` and a subsequent
    /// `isBlocked(ip:)` may return `false` if enough time passes for
    /// failures to age out of the rolling window between the two calls.
    /// This is by design — the window is rolling. Callers that need a
    /// stable block verdict for a single request should consult
    /// `isBlocked` only; `recordFailure`'s return value is a fast-path
    /// for "you've just crossed the threshold right now."
    @discardableResult
    public func recordFailure(ip: String) -> Bool {
        cleanup(ip: ip)
        var entry = attempts[ip] ?? Entry(timestamps: [], lastAccess: Date())
        // Retain only the `maxAttempts` most recent failures. Every decision
        // this type makes is `count >= maxAttempts`, so a further timestamp
        // carries no information — but an unbounded array does carry cost:
        // `maxTrackedIPs` bounds how many IPs we track, not how many failures
        // each one accumulates, and `cleanup`'s `removeFirst()` loop is O(n²)
        // in that length. A single IP failing in a tight loop would otherwise
        // grow this array for the whole window, on an actor that serializes
        // every other caller behind it.
        //
        // Dropping the OLDEST (not refusing the newest) is what preserves the
        // semantics: the window keeps sliding forward with the attack, so a
        // sustained attacker stays blocked. Refusing to append once full would
        // instead let the block lapse `windowSeconds` after the first burst
        // no matter how long the attack continued.
        //
        // `max(1, …)` keeps the arithmetic below in range for a degenerate
        // `maxAttempts: 0`, where `count - 0 + 1` would ask an empty array to
        // drop one element and trap.
        let retain = max(1, maxAttempts)
        if entry.timestamps.count >= retain {
            entry.timestamps.removeFirst(entry.timestamps.count - retain + 1)
        }
        entry.timestamps.append(Date())
        entry.lastAccess = Date()
        attempts[ip] = entry
        evictIfNeeded()
        return entry.timestamps.count >= maxAttempts
    }

    /// Check whether the given IP is currently blocked. Touches `lastAccess`
    /// as a side effect so actively-checked IPs don't get LRU-evicted out
    /// from under an ongoing auth attempt.
    public func isBlocked(ip: String) -> Bool {
        cleanup(ip: ip)
        if var entry = attempts[ip] {
            entry.lastAccess = Date()
            attempts[ip] = entry
            return entry.timestamps.count >= maxAttempts
        }
        return false
    }

    /// Reset tracking for an IP (e.g. after a successful auth).
    public func reset(ip: String) {
        attempts.removeValue(forKey: ip)
    }

    // MARK: - Private

    /// Remove timestamps outside the current rolling window.
    private func cleanup(ip: String) {
        guard var entry = attempts[ip] else { return }
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        // Timestamps are appended chronologically, so drop from the front.
        while let first = entry.timestamps.first, first < cutoff {
            entry.timestamps.removeFirst()
        }
        if entry.timestamps.isEmpty {
            attempts.removeValue(forKey: ip)
        } else {
            attempts[ip] = entry
        }
    }

    /// If we're at or above the eviction threshold, drop the oldest 10% by
    /// `lastAccess`. The threshold is `maxTrackedIPs * 1.1` (10% headroom) so
    /// each sort+evict amortizes over ~maxTrackedIPs/10 insertions instead of
    /// firing on every single failure past the soft cap.
    private func evictIfNeeded() {
        let evictCount = max(1, maxTrackedIPs / 10)
        guard attempts.count > maxTrackedIPs + evictCount else { return }
        let sorted = attempts.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (ip, _) in sorted.prefix(evictCount) {
            attempts.removeValue(forKey: ip)
        }
    }

    // MARK: - Test Hooks

    /// Exposed only for tests. Do not call from production code.
    public var _testOnly_trackedIPCount: Int { attempts.count }

    /// Exposed only for tests. Number of failure timestamps retained for an IP,
    /// so the `maxAttempts` retention bound in `recordFailure` can be asserted
    /// directly rather than inferred from blocking behaviour.
    /// Do not call from production code.
    public func _testOnly_retainedFailureCount(ip: String) -> Int {
        attempts[ip]?.timestamps.count ?? 0
    }
}
