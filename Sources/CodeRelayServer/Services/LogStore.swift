import Foundation

/// Thread-safe in-memory log store for the admin API `/logs` endpoint.
/// Uses NSLock for synchronous access from NIO event loops without requiring `await`.
public final class LogStore: @unchecked Sendable {
    private var entries: [String] = []
    private var dropCount = 0
    private let maxEntries: Int
    private let lock = NSLock()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    public init(maxEntries: Int = 2000) {
        self.maxEntries = maxEntries
    }

    /// Append a log entry with automatic timestamp prefix.
    public func append(level: String = "info", category: String, message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let entry = "[\(timestamp)] [\(level.uppercased())] [\(category)] \(message)"
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            dropCount += 1
            // Compact when overshoot exceeds 5% of capacity (capped at 100).
            // Keeps the live array within ~1.05× maxEntries without the O(n)
            // shift cost on every append.
            let overshootThreshold = min(100, max(10, maxEntries / 20))
            if dropCount >= overshootThreshold {
                entries.removeFirst(dropCount)
                dropCount = 0
            }
        }
        lock.unlock()
    }

    /// Return the most recent `count` entries.
    public func recent(count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let live = entries.dropFirst(dropCount)
        return Array(live.suffix(count))
    }
}
