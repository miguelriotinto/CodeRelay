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
    /// Bounding a single *test method* does not achieve that, because XCTest runs
    /// methods in alphabetical order and the guard has to survive being shadowed.
    /// Verified by running the suite: `testFallsBackToNormalizedInputWhenNoGit`
    /// executes 5th and resolves `/private/tmp`, which has no `.git` at
    /// `/private/tmp`, `/private`, or `/` — so it walks to the root, the same
    /// divergent case — while `testRootPathResolvesWithoutHanging` executes last,
    /// 7th. A regression would therefore park the earlier test and the later
    /// deadline would never be reached. Bounding the *operation* keeps the
    /// attribution wherever it happens to strike first.
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
    ///   `deletingLastPathComponent()` walk left every test in this suite green,
    ///   including a property assertion that the root contains no `".."`.
    /// - A **timeout** cannot either. The divergent walk *converges* on some
    ///   Foundation implementations (this machine among them, after one `"/.."`
    ///   step) and diverges on others, so a wall-clock bound fires only where the
    ///   suite already hangs.
    ///
    /// The probe *count* is what survives both, and `probeLimit` is what makes it an
    /// assertion rather than a hang: an unbounded search on a diverging platform
    /// exhausts the limit and reports the trail, instead of parking `swift test`
    /// until the CI job cap with no test named — the month-long misdiagnosis this
    /// regression already cost once.
    ///
    /// Being explicit about the limit of this test, since a mutation showed it: on a
    /// *converging* platform the pre-fix walk probes exactly these same three paths,
    /// so this test passes against it here. That is not a gap in the assertion — the
    /// two implementations are observationally identical on such a platform, for
    /// every input. What the limit buys is that the same assertion becomes a named
    /// failure wherever they *do* differ, which is precisely where the old code
    /// hung. Pair it with `testAncestorWalkIsFiniteAndEndsAtRoot`, which pins
    /// finiteness of the list directly and is platform-independent.
    func testProbesExactlyTheFiniteAncestorList() {
        /// Enough for the deepest input below, and far below the unbounded walk's
        /// appetite. Reached only by a search that does not terminate on the list.
        let probeLimit = 24

        func probes(of path: String, hit: String? = nil) -> (probed: [String], root: String) {
            var probed: [String] = []
            let root = GitRootResolver.gitRoot(of: path) { candidate in
                guard probed.count < probeLimit else { return true }   // break the loop
                probed.append(candidate)
                return candidate == hit
            }
            XCTAssertLessThan(probed.count, probeLimit,
                              "the search did not terminate on the ancestor list; trail: \(probed)")
            return (probed, root)
        }

        let none = probes(of: "/private/tmp")
        XCTAssertEqual(none.probed, ["/private/tmp/.git", "/private/.git", "/.git"])
        XCTAssertEqual(none.root, "/private/tmp", "with no .git found, the input is its own group")

        // The degenerate input: nowhere to go up to, so exactly one probe.
        XCTAssertEqual(probes(of: "/").probed, ["/.git"])

        // And the search must stop at the first hit rather than probing to the root.
        let found = probes(of: "/a/b/c", hit: "/a/b/.git")
        XCTAssertEqual(found.probed, ["/a/b/c/.git", "/a/b/.git"])
        XCTAssertEqual(found.root, "/a/b")
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
