import Foundation

/// Resolves a working-directory path to its enclosing git repository root, so
/// sessions group by repo rather than by every distinct subdirectory
/// (`/repo`, `/repo/Sources`, `/repo/Tests` → one group `/repo`).
///
/// Walks up from the path looking for a `.git` entry (no subprocess — plain
/// `FileManager` checks), normalizes symlinks, and falls back to the input
/// path when no repo is found. Results are LRU-cached (bounded) so the
/// server's foreground poll doesn't re-walk the tree every tick.
public actor GitRootResolver {
    private let maxCacheEntries: Int
    private var cache: [String: String] = [:]
    private var order: [String] = []   // simple LRU: most-recent at the end

    public init(maxCacheEntries: Int = 256) {
        self.maxCacheEntries = maxCacheEntries
    }

    /// The git root for `path`, or a normalized fallback. Empty/whitespace →
    /// `"~"` (the "Other" bucket). Never throws.
    public func root(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "~" }

        if let cached = cache[trimmed] {
            touch(trimmed)
            return cached
        }

        let resolved = computeRoot(for: trimmed)
        store(key: trimmed, value: resolved)
        return resolved
    }

    private func computeRoot(for path: String) -> String {
        let fileManager = FileManager.default
        var current = URL(fileURLWithPath: path).resolvingSymlinksInPath()

        // Walk up until a `.git` entry is found or we hit the filesystem root.
        while true {
            let gitPath = current.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitPath.path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            // deletingLastPathComponent() on "/" yields "/" — stop then.
            if parent.path == current.path { break }
            current = parent
        }
        // No repo found: return the normalized input path as its own group.
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func touch(_ key: String) {
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        order.append(key)
    }

    private func store(key: String, value: String) {
        cache[key] = value
        touch(key)
        while order.count > maxCacheEntries {
            let evict = order.removeFirst()
            cache.removeValue(forKey: evict)
        }
    }
}
