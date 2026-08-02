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
    /// Answers "is there something at this path?" — `FileManager` in production.
    public typealias ExistenceCheck = @Sendable (String) -> Bool

    private let maxCacheEntries: Int
    private let exists: ExistenceCheck
    private var cache: [String: String] = [:]
    private var order: [String] = []   // simple LRU: most-recent at the end

    public init(maxCacheEntries: Int = 256) {
        self.init(maxCacheEntries: maxCacheEntries) { path in
            FileManager.default.fileExists(atPath: path)
        }
    }

    /// Injects the existence check so a test can observe *which* paths a resolution
    /// probes while still calling `root(for:)` — the one entry point production uses.
    ///
    /// Driving a static helper instead observes a *sibling* of production: `root(for:)`
    /// reaches the filesystem through private hops, so a test calling a hop below the
    /// top leaves a rewrite of an upper hop unobserved. An earlier version of this
    /// seam was a static `computeRoot(for:exists:)` and had exactly that hole —
    /// restoring the pre-fix `deletingLastPathComponent()` walk in the private
    /// instance method above it left all eight tests green.
    ///
    /// **This closes the routing hole, not the platform one.** With probes now
    /// observed through `root(for:)`, that same mutant *still* survives on this
    /// machine, and no probe assertion can change that: for every input production
    /// can supply, the pre-fix walk probes a byte-identical trail here (verified —
    /// `/a/b/c`, `/`, and the normalized forms of `/a/../b` and `/a//b` all match).
    /// The two implementations are observationally identical on a Foundation whose
    /// `deletingLastPathComponent()` reaches its fixed point immediately; they differ
    /// only on inputs like `///a`, which `resolvingSymlinksInPath()` removes before
    /// the search sees them. What this seam buys is that a *routing* change — some
    /// future rewrite that stops calling `gitRoot(of:exists:)` — now fails a test.
    /// Termination itself is pinned structurally by
    /// `testAncestorWalkIsFiniteAndEndsAtRoot`, which is platform-independent
    /// because it asserts on the list rather than on a walk's behaviour.
    ///
    /// This is deliberately not on the public `init`: the seam exists for a test, so
    /// it should not appear at production construction sites. The cost is a stored
    /// property the actor would not otherwise need, which is the price of the
    /// routing boundary actually being closed rather than moved up a level.
    init(maxCacheEntries: Int = 256, exists: @escaping ExistenceCheck) {
        // Clamp: a non-positive cap would let `store`'s eviction loop call
        // removeFirst() on an empty order array.
        self.maxCacheEntries = max(1, maxCacheEntries)
        self.exists = exists
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

    /// Normalizes `path`, then searches its ancestors — the whole resolution step.
    ///
    /// Reached only from `root(for:)`, and it probes through the injected `exists`,
    /// so a test driving `root(for:)` sees every probe this makes. There is no
    /// separate static twin to drive instead: one existed and was the defect the
    /// injected check replaced — see `init(maxCacheEntries:exists:)`.
    ///
    /// The return value cannot substitute for observing the probes.
    /// `resolvingSymlinksInPath()` collapses exactly the inputs (`..`, `//`) on which
    /// a divergent walk would return something different, so past this point the two
    /// implementations are distinguishable only by which paths they touch.
    private func computeRoot(for path: String) -> String {
        let normalized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return Self.gitRoot(of: normalized, exists: exists)
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
    /// `testProbesExactlyTheFiniteAncestorList` narrows that gap without closing it,
    /// and the distinction matters enough to state plainly: it pins the probe sequence
    /// through `root(for:)` (via the `exists` injected on
    /// `init(maxCacheEntries:exists:)`), so it fails if production stops routing
    /// through this function, or probes a path outside the ancestor list. It does
    /// *not* fail against the old walk on this machine, because there the walk probes
    /// the identical sequence for every normalized input — the mutation survives, and
    /// the test's own doc comment says so.
    ///
    /// Termination is therefore pinned by `testAncestorWalkIsFiniteAndEndsAtRoot`
    /// asserting on the list itself, which holds on any Foundation. The probe test
    /// contributes the other half — that this search consults that list and nothing
    /// else — and would have caught the CI hang, since a diverging walk exceeds
    /// `probeLimit` and fails by name rather than parking the suite.
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
    /// interpreted.
    ///
    /// In practice neither reaches here, because `computeRoot` normalizes first —
    /// `testProbesExactlyTheFiniteAncestorList` asserts that for the inputs it
    /// covers. Note what that does and does not establish: it is a claim about
    /// `resolvingSymlinksInPath()` stripping `..`/`.`/`//`, which is observed on the
    /// inputs tried, not documented for all of them — the same species of assumption
    /// as the `deletingLastPathComponent()` fixed point this file exists to avoid
    /// trusting. Relying on it is acceptable only because nothing here depends on it
    /// for termination: `ancestorPaths` is finite by construction whatever it is
    /// handed, so an unnormalized input yields a slightly odd group, never a hang.
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
