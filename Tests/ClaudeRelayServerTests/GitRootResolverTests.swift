import XCTest
import Foundation
@testable import ClaudeRelayServer

final class GitRootResolverTests: XCTestCase {
    private func tmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `resolver.root(for: path)`, failing the test if it does not return within
    /// `timeout` instead of parking the suite.
    ///
    /// Every `root(for:)` call in this suite goes through here, and that is the
    /// point: `swift test` applies no per-test time limit, so a non-terminating
    /// ancestor walk hangs the whole run until the CI job cap with no failing test
    /// named — the month-long misdiagnosis this regression already cost once.
    ///
    /// Bounding a single *test method* does not achieve that, because the guard has
    /// to survive being shadowed by whichever divergent test runs first — and which
    /// one that is isn't ours to choose. XCTest happens to run methods in
    /// alphabetical order, but that is observed default behaviour, not a documented
    /// contract, and a test plan can randomize it. Under the alphabetical default
    /// `testFallsBackToNormalizedInputWhenNoGit` runs before
    /// `testRootPathResolvesWithoutHanging`, and it resolves `/private/tmp`
    /// (normalizing to `/tmp`), which has no `.git` at `/tmp` or `/` — so it walks to
    /// the root, the same divergent case. A regression would park it and the later
    /// deadline would never be reached. Bounding the *operation* keeps the
    /// attribution wherever it happens to strike first, under any order.
    private func resolvedRoot(
        for path: String,
        using resolver: GitRootResolver = GitRootResolver(),
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        let done = expectation(description: "root(for: \(path)) returned")
        let box = ResultBox()
        Task {
            box.value = await resolver.root(for: path)
            done.fulfill()
        }
        guard XCTWaiter.wait(for: [done], timeout: timeout) == .completed else {
            XCTFail("root(for: \(path)) did not return within \(timeout)s — the ancestor walk did not terminate",
                    file: file, line: line)
            return nil
        }
        return box.value
    }

    /// Carries the result out of the task. A captured `var` would not compile:
    /// the closure is `@Sendable` and escaping.
    private final class ResultBox: @unchecked Sendable {
        var value: String?
    }

    /// Records the paths an existence check is asked about, answering `true` only for
    /// `hit`.
    ///
    /// Locked rather than a captured `var` because `GitRootResolver.ExistenceCheck` is
    /// `@Sendable` and runs inside the actor: the calls are in fact serial, but the
    /// compiler cannot see that from the closure's type, and asserting it with
    /// `@unchecked Sendable` over mutable state would be the assertion rather than the
    /// proof.
    ///
    /// `limit` stops a non-terminating search from appending forever: past it every
    /// answer is `true`, which ends the walk and leaves the oversized trail for the
    /// caller to report as a failure instead of hanging the suite.
    private final class ProbeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var trail: [String] = []
        private let hit: String?
        private let limit: Int

        init(hit: String?, limit: Int) {
            self.hit = hit
            self.limit = limit
        }

        func record(_ candidate: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard trail.count < limit else { return true }   // break the loop
            trail.append(candidate)
            return candidate == hit
        }

        var probed: [String] {
            lock.lock()
            defer { lock.unlock() }
            return trail
        }
    }

    func testRootFindsGitDirAncestor() throws {
        let repo = tmpDir()
        let deep = repo.appendingPathComponent("Sources/Deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        let root = try XCTUnwrap(resolvedRoot(for: deep.path))
        XCTAssertEqual(URL(fileURLWithPath: root).resolvingSymlinksInPath().path,
                       repo.resolvingSymlinksInPath().path)
    }

    func testFallsBackToNormalizedInputWhenNoGit() throws {
        // A real dir with no .git ancestor falls back to its symlink-normalized
        // path. macOS collapses /private/tmp ↔ /tmp, so accept either form.
        //
        // This also walks all the way to `/`, so it exercises the divergent case
        // end-to-end through `computeRoot` — see `resolvedRoot` on why the bound
        // lives on the operation rather than on one method.
        let root = try XCTUnwrap(resolvedRoot(for: "/private/tmp"))
        XCTAssertTrue(root == "/private/tmp" || root == "/tmp", "got \(root)")
    }

    func testEmptyPathReturnsHomePlaceholder() throws {
        XCTAssertEqual(try XCTUnwrap(resolvedRoot(for: "")), "~")
    }

    /// The ancestor walk must be finite for a path with no `.git` anywhere above
    /// it — including the filesystem root itself.
    ///
    /// Regression: the walk used to step upward with `deletingLastPathComponent()`
    /// and stop when the parent equalled the current path. That fixed point is not
    /// a documented contract, and under the `NSURL`-backed implementation `"/"`
    /// maps to `"/.."`, then `"/../.."`, so the guard never fired and `computeRoot`
    /// spun with a filesystem probe per iteration — ~10 min on CI (GitHub
    /// `macos-15`) while the same code converged locally.
    ///
    /// These assertions are on the *list*, which is implementation-independent,
    /// rather than on wall-clock time. They pin the helper's shape only — a correct
    /// helper that nothing called would leave them green, so
    /// `testProbesExactlyTheFiniteAncestorList` is what ties the production search
    /// to this list.
    func testAncestorWalkIsFiniteAndEndsAtRoot() {
        let ancestors = GitRootResolver.ancestorPaths(of: "/private/tmp")
        XCTAssertEqual(ancestors, ["/private/tmp", "/private", "/"])

        // The root is the degenerate case that used to diverge. `..` was the
        // signature of that divergence (`/..`, `/../..`, …), and the exact
        // equalities above already exclude it for these inputs — `ancestorPaths`
        // only rejoins components it split out of the input, so it cannot
        // synthesize one.
        XCTAssertEqual(GitRootResolver.ancestorPaths(of: "/"), ["/"])
        XCTAssertEqual(GitRootResolver.ancestorPaths(of: "/a/b/c/d"),
                       ["/a/b/c/d", "/a/b/c", "/a/b", "/a", "/"])
    }

    /// A component starting with a combining mark must not swallow the separator
    /// before it. `String.split(separator: "/")` splits on grapheme clusters, so
    /// `"/" + U+0301` fuses into one `Character`, the separator is missed, and an
    /// ancestor level disappears — the enclosing repo root would then never be
    /// probed for `.git`. Splitting Unicode scalars is what the kernel does.
    func testCombiningMarkComponentDoesNotSwallowSeparator() {
        let ancestors = GitRootResolver.ancestorPaths(of: "/tmp/x/repo/\u{0301}sub/deep")
        XCTAssertTrue(ancestors.contains("/tmp/x/repo"),
                      "the repo level was dropped by grapheme-cluster splitting: \(ancestors)")

        // Multi-scalar content must still split correctly. The ZWJ family is one
        // `Character` but seven scalars, and 日本語 is multi-byte — neither
        // contains U+002F, so neither may be disturbed.
        XCTAssertEqual(GitRootResolver.ancestorPaths(of: "/tmp/日本語/x"),
                       ["/tmp/日本語/x", "/tmp/日本語", "/tmp", "/"])
        XCTAssertEqual(GitRootResolver.ancestorPaths(of: "/tmp/👨‍👩‍👧‍👦/x"),
                       ["/tmp/👨‍👩‍👧‍👦/x", "/tmp/👨‍👩‍👧‍👦", "/tmp", "/"])
    }

    /// Resolving a path directly at the filesystem root must return promptly.
    ///
    /// `"/"` is the degenerate input: the walk has nowhere to go up to, so it is
    /// where a divergent `deletingLastPathComponent()` starts accumulating `".."`
    /// immediately. The deadline comes from `resolvedRoot`, which every call in
    /// this suite shares — see its doc comment for why the bound cannot live on
    /// this method alone.
    func testRootPathResolvesWithoutHanging() throws {
        XCTAssertEqual(try XCTUnwrap(resolvedRoot(for: "/")), "/",
                       "the root must resolve to itself")
    }

    /// The search must probe exactly the finite ancestor list — no more, and in that
    /// order.
    ///
    /// This asserts on the *probes* because neither of the two obvious observables
    /// can see the regression this file exists to prevent:
    ///
    /// - The **return value** cannot. With no `.git` anywhere the result is the
    ///   normalized input however the search reached that conclusion, and when a
    ///   `.git` is found the search stops far below `"/"`, where the divergence
    ///   lives. Verified by mutation: restoring the pre-fix
    ///   `deletingLastPathComponent()` walk left every test in this suite green —
    ///   including, at the time (`cd0c993`), a property assertion that the resolved
    ///   root contained no `".."`, since replaced here by exact-equality assertions
    ///   on the ancestor list.
    /// - A **timeout** cannot either. The divergent walk *converges* on some
    ///   Foundation implementations and diverges on others, so a wall-clock bound
    ///   fires only where the suite already hangs. In the Foundation this test
    ///   binary links, `URL(fileURLWithPath: "/").deletingLastPathComponent().path`
    ///   is already `"/"` — an immediate fixed point, so the pre-fix walk terminates
    ///   here in the same number of steps as the fixed one. (A separately compiled
    ///   SDK-15.4-linked binary takes one `"/.."` step before converging, and CI's
    ///   diverged outright; neither is what `swift test` runs on this machine, so
    ///   neither licenses a claim about this suite's behaviour.)
    ///
    /// The probe *count* is what survives both, and `probeLimit` is what makes it an
    /// assertion rather than a hang: an unbounded search on a diverging platform
    /// exhausts the limit and reports the trail, instead of parking `swift test`
    /// until the CI job cap with no test named — the month-long misdiagnosis this
    /// regression already cost once.
    ///
    /// Being explicit about the limit of this test, since a mutation showed it: where
    /// `deletingLastPathComponent()` reaches its fixed point immediately — this
    /// binary's Foundation does — the pre-fix walk probes exactly these same paths
    /// for the inputs below, so this test passes against it here.
    ///
    /// That is a real limit, not an equivalence. The two implementations are *not*
    /// observationally identical for every input even on such a platform: `/a/../b`
    /// probes 2 paths under the walk and 4 under `ancestorPaths`
    /// (`/a/../b`, `/a/..`, `/a`, `/`), and `/tmp//x` probes `/tmp//x/.git` versus
    /// `/tmp/x/.git`. They agree only on inputs already free of `..` and `//` — which
    /// is every input production supplies, because `computeRoot` normalizes first, and
    /// is why the mutation survived. The `hit:` case below pins one such input so the
    /// equivalence is not silently assumed.
    ///
    /// What the limit buys is that the same assertion becomes a named failure
    /// wherever they *do* differ, which is precisely where the old code hung. Pair it
    /// with `testAncestorWalkIsFiniteAndEndsAtRoot`, which pins finiteness of the
    /// list directly and is platform-independent.
    ///
    /// Probes are observed through `root(for:)` — the entry point production calls —
    /// via the `exists` check injected on the internal initializer, not by calling a
    /// static helper directly. An earlier version of this test drove a static
    /// `computeRoot(for:exists:)` instead, and so asserted on a *sibling* of
    /// production: rewriting the private instance method above it to walk the tree some
    /// other way bypassed everything pinned here.
    ///
    /// To be exact about what routing through `root(for:)` did and did not buy, because
    /// the two are easy to conflate: it means a future change that stops calling
    /// `gitRoot(of:exists:)` fails this test. It does **not** make the pre-fix walk
    /// fail it — that mutation survives either way, for the platform reason given
    /// above, and the static seam was never what was keeping it alive. The
    /// normalization is asserted rather than worked around, since it is what makes the
    /// unnormalized inputs above unreachable in production.
    func testProbesExactlyTheFiniteAncestorList() throws {
        /// Enough for the deepest input below, and far below the unbounded walk's
        /// appetite. Reached only by a search that does not terminate on the list.
        let probeLimit = 24

        /// Collects the probe trail for one resolution.
        ///
        /// A fresh resolver per call, so the LRU cache can never answer instead of the
        /// search — a cache hit would record an empty trail and pass every assertion
        /// below vacuously.
        ///
        /// Goes through `resolvedRoot` — i.e. under the wall-clock deadline — rather
        /// than awaiting `root(for:)` directly, and `probeLimit` does *not* make that
        /// redundant. The two bounds catch disjoint failures: the limit only fires on a
        /// loop that *calls* `exists`, and the canonical regression here diverges while
        /// building the ancestor list, before the first probe is ever issued. A bare
        /// `await` would then park the whole suite with no test named — the exact
        /// failure mode this file exists to prevent, reintroduced by its own helper.
        /// It is also what `resolvedRoot`'s "every call in this suite goes through
        /// here" is asserting; an earlier version of this helper made that sentence
        /// false.
        func probes(of path: String, hit: String? = nil) throws -> (probed: [String], root: String) {
            let recorder = ProbeRecorder(hit: hit, limit: probeLimit)
            let resolver = GitRootResolver(exists: { recorder.record($0) })
            let root = try XCTUnwrap(resolvedRoot(for: path, using: resolver))
            let probed = recorder.probed
            XCTAssertLessThan(probed.count, probeLimit,
                              "the search did not terminate on the ancestor list; trail: \(probed)")
            return (probed, root)
        }

        // Inputs are chosen to normalize to themselves, so the expected trails don't
        // depend on which real paths happen to be symlinks. `/private/tmp` would not
        // qualify: it resolves to `/tmp`, dropping a level.
        let none = try probes(of: "/a/b/c")
        XCTAssertEqual(none.probed, ["/a/b/c/.git", "/a/b/.git", "/a/.git", "/.git"])
        XCTAssertEqual(none.root, "/a/b/c", "with no .git found, the input is its own group")

        // The degenerate input: nowhere to go up to, so exactly one probe.
        let root = try probes(of: "/")
        XCTAssertEqual(root.probed, ["/.git"])

        // And the search must stop at the first hit rather than probing to the root.
        let found = try probes(of: "/a/b/c", hit: "/a/b/.git")
        XCTAssertEqual(found.probed, ["/a/b/c/.git", "/a/b/.git"])
        XCTAssertEqual(found.root, "/a/b")

        // `..` and `//` — the two input shapes on which the pre-fix walk and
        // `ancestorPaths` genuinely disagree — never reach the search, because
        // normalization removes them first. Asserting that here is what makes the
        // equivalence noted above a checked property rather than an assumption.
        let dotDot = try probes(of: "/a/../b")
        XCTAssertEqual(dotDot.probed, ["/b/.git", "/.git"],
                       "`..` survived normalization and reached the ancestor walk")
        let doubleSep = try probes(of: "/a//b")
        XCTAssertEqual(doubleSep.probed, ["/a/b/.git", "/a/.git", "/.git"],
                       "a repeated separator survived normalization")
    }

    func testCachedResultIsStable() throws {
        let repo = tmpDir()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        let resolver = GitRootResolver()
        let first = try XCTUnwrap(resolvedRoot(for: repo.path, using: resolver))
        let second = try XCTUnwrap(resolvedRoot(for: repo.path, using: resolver))
        XCTAssertEqual(first, second)
    }
}
