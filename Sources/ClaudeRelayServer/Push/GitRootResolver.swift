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
        // Clamp: a non-positive cap would let `store`'s eviction loop call
        // removeFirst() on an empty order array.
        self.maxCacheEntries = max(1, maxCacheEntries)
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
        let normalized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        // Walk up until a `.git` entry is found, over a list that is finite by
        // construction. See `ancestorPaths` for why the walk is not driven by
        // repeated `deletingLastPathComponent()` calls.
        for ancestor in Self.ancestorPaths(of: normalized) {
            let gitPath = ancestor == "/" ? "/.git" : "\(ancestor)/.git"
            if fileManager.fileExists(atPath: gitPath) {
                return ancestor
            }
        }
        // No repo found: return the normalized input path as its own group.
        return normalized
    }

    /// `path` and all of its ancestor directories, nearest first, ending at `"/"`.
    ///
    /// Derived by dropping trailing path components off the string rather than by
    /// calling `deletingLastPathComponent()` until it reaches a fixed point. That
    /// fixed point is not guaranteed: which implementation backs `URL` is chosen
    /// by the Foundation the process links against at *runtime* — not by the
    /// Swift toolchain or the deployment target — and the `NSURL`-backed one maps
    /// `"/"` to `"/.."`, then `"/../.."`, without ever converging. A
    /// `parent == current` guard therefore never fires and the walk spins
    /// forever, doing a filesystem probe per iteration. Observed: it diverged on
    /// GitHub's `macos-15` runner and converged on macOS 26 locally, which is why
    /// it only ever hung on CI. Neither behaviour is a documented contract, so
    /// this walk depends on neither — splitting the string is finite by
    /// construction on every platform.
    ///
    /// Splits on Unicode *scalars*, not `Character`s: a path component may begin
    /// with a combining mark, which grapheme-cluster splitting fuses onto the
    /// preceding `"/"` — the separator then isn't equal to `"/"` any more, so it
    /// is missed and an ancestor level is silently dropped. `U+002F` is a single
    /// scalar that never participates in a larger one, so splitting the scalar
    /// view is exactly the kernel's own notion of a path component (it splits
    /// the UTF-8 byte 0x2F, and UTF-8 is self-synchronizing).
    static func ancestorPaths(of path: String) -> [String] {
        var components = path.unicodeScalars
            .split(separator: "/")
            .map { String(String.UnicodeScalarView($0)) }
        var result: [String] = []
        while !components.isEmpty {
            result.append("/" + components.joined(separator: "/"))
            components.removeLast()
        }
        result.append("/")
        return result
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
