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
        return Self.computeRoot(for: path) { fileManager.fileExists(atPath: $0) }
    }

    /// Normalizes `path`, then searches its ancestors — the whole production
    /// resolution step, with only the filesystem lifted out.
    ///
    /// This exists so a test can drive the *production* path and still see which
    /// paths get probed. Asserting on `gitRoot(of:exists:)` alone does not do that:
    /// it pins the helper's behaviour, but nothing pins `computeRoot` to the helper,
    /// so a rewrite that walks the tree some other way leaves those assertions
    /// green. Nor can the return value close the gap here — `resolvingSymlinksInPath()`
    /// collapses exactly the inputs (`..`, `//`) on which a divergent walk would
    /// return something different, so through this seam the two are distinguishable
    /// only by their probes.
    ///
    /// The filesystem is a closure parameter rather than a stored dependency
    /// deliberately: the actor has no other injectable collaborator, and adding an
    /// initializer parameter to make one function observable would put a production
    /// seam in every construction site for a test's benefit.
    static func computeRoot(for path: String, exists: (String) -> Bool) -> String {
        let normalized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return gitRoot(of: normalized, exists: exists)
    }

    /// The nearest ancestor of `normalized` (inclusive) holding a `.git` entry, or
    /// `normalized` itself when there is none.
    ///
    /// `exists` is a parameter rather than a direct `FileManager` call so a test can
    /// observe *which* paths the search probes. Nothing about the return value can:
    /// with no `.git` anywhere the result is the input regardless of how the search
    /// got there, and when one is found the search stops well below the root, where
    /// the divergence `ancestorPaths` exists to avoid lives. Reverting that fix
    /// therefore left the whole suite green (verified by mutation) — the defect was
    /// unobservable through this type's surface, not merely unobserved.
    ///
    /// `testProbesExactlyTheFiniteAncestorList` closes that gap by pinning the probe
    /// sequence, which composes with `testAncestorWalkIsFiniteAndEndsAtRoot` into the
    /// termination guarantee neither test gives alone: the list is finite, and the
    /// search probes exactly that list and nothing else.
    ///
    /// Neither of those reaches production, though — both call these statics
    /// directly, so a correct helper that `computeRoot` had stopped calling would
    /// leave both green. That is what `computeRoot(for:exists:)` is for; the probe
    /// assertions go through it.
    static func gitRoot(of normalized: String, exists: (String) -> Bool) -> String {
        // Over a list that is finite by construction — see `ancestorPaths` for why
        // this is not a `deletingLastPathComponent()` loop.
        for ancestor in ancestorPaths(of: normalized) {
            let gitPath = ancestor == "/" ? "/.git" : "\(ancestor)/.git"
            if exists(gitPath) {
                return ancestor
            }
        }
        // No repo found: return the normalized input path as its own group.
        return normalized
    }

    /// `path` and all of its ancestor directories, nearest first, ending at `"/"`.
    ///
    /// Derived by dropping trailing path components off the string rather than by
    /// calling `deletingLastPathComponent()` until it reaches a fixed point.
    /// Foundation does not document that a fixed point exists, and in practice it
    /// depends on the Foundation implementation in play: the `NSURL`-backed path
    /// maps `"/"` to `"/.."`, then `"/../.."`, accumulating without converging, so
    /// a `parent == current` guard never fires and the walk spins doing a
    /// filesystem probe per iteration. That is what hung `swift test` on GitHub's
    /// `macos-15` runner for ~10 min while the same code converged locally —
    /// `sample` put all 2235 samples inside
    /// `-[NSURL URLByAppendingPathComponent:]`, a spinning loop rather than a
    /// parked `await`.
    ///
    /// No single factor is claimed to select the behaviour. Varying only the
    /// linked SDK on one machine flips it (an SDK-15-linked binary takes a `"/.."`
    /// step where an SDK-26-linked one does not), yet CI's binary was also
    /// SDK-15-linked and diverged *without* converging, so the runtime Foundation
    /// participates as well. This walk therefore relies on neither: splitting the
    /// string is finite by construction everywhere.
    ///
    /// Splits on Unicode *scalars*, not `Character`s: a path component may begin
    /// with a combining mark, which grapheme-cluster splitting fuses onto the
    /// preceding `"/"` — the separator then isn't equal to `"/"` any more, so it
    /// is missed and an ancestor level is silently dropped. `U+002F` is a single
    /// scalar that never participates in a larger one, so splitting the scalar view
    /// finds every separator the kernel would (it splits the UTF-8 byte 0x2F, and
    /// UTF-8 is self-synchronizing).
    ///
    /// Component *semantics* match only for the paths this actually receives.
    /// Dropping empty subsequences collapses `//` the way the kernel does, but that
    /// also rewrites the input, so `ancestorPaths(of: "/tmp//x")` starts at
    /// `"/tmp/x"`; and `.` / `..` are returned as ordinary components rather than
    /// interpreted. Neither reaches here — `computeRoot` normalizes first — which is
    /// the property `testProbesExactlyTheFiniteAncestorList` asserts.
    static func ancestorPaths(of path: String) -> [String] {
        var components = path.unicodeScalars
            .split(separator: "/")
            .map(String.init)
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
