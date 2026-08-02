import XCTest
import Foundation
@testable import ClaudeRelayServer

final class GitRootResolverTests: XCTestCase {
    private func tmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRootFindsGitDirAncestor() async throws {
        let repo = tmpDir()
        let deep = repo.appendingPathComponent("Sources/Deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        let root = await GitRootResolver().root(for: deep.path)
        XCTAssertEqual(URL(fileURLWithPath: root).resolvingSymlinksInPath().path,
                       repo.resolvingSymlinksInPath().path)
    }

    func testFallsBackToNormalizedInputWhenNoGit() async {
        // A real dir with no .git ancestor falls back to its symlink-normalized
        // path. macOS collapses /private/tmp ↔ /tmp, so accept either form.
        let root = await GitRootResolver().root(for: "/private/tmp")
        XCTAssertTrue(root == "/private/tmp" || root == "/tmp", "got \(root)")
    }

    func testEmptyPathReturnsHomePlaceholder() async {
        let root = await GitRootResolver().root(for: "")
        XCTAssertEqual(root, "~")
    }

    /// The ancestor walk must be finite for a path with no `.git` anywhere above
    /// it — including the filesystem root itself.
    ///
    /// Regression: the walk used to step upward with `deletingLastPathComponent()`
    /// and stop when the parent equalled the current path. That fixed point is not
    /// guaranteed — which implementation backs `URL` is chosen by the Foundation
    /// the process links against at runtime, and the `NSURL`-backed one maps `"/"`
    /// to `"/.."` and then `"/../.."` forever, so the guard never fired and
    /// `computeRoot` spun with a filesystem probe per iteration. It hung
    /// `swift test` on CI (GitHub `macos-15`) for ~10 min while converging
    /// locally, so the assertions below are on the *list*, which is
    /// implementation-independent, rather than on wall-clock time.
    func testAncestorWalkIsFiniteAndEndsAtRoot() {
        let ancestors = GitRootResolver.ancestorPaths(of: "/private/tmp")
        XCTAssertEqual(ancestors, ["/private/tmp", "/private", "/"])

        // The root is the degenerate case that used to diverge.
        XCTAssertEqual(GitRootResolver.ancestorPaths(of: "/"), ["/"])

        // No ancestor may contain a `..` — that was the signature of the
        // divergence (`/..`, `/../..`, …).
        for path in ["/", "/private/tmp", "/a/b/c/d"] {
            for ancestor in GitRootResolver.ancestorPaths(of: path) {
                XCTAssertFalse(ancestor.contains(".."), "\(path) produced \(ancestor)")
            }
        }
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
    /// Guards the hang end-to-end. The timeout is the point: `swift test` applies
    /// no per-test time limit, so a reintroduced divergence would park the whole
    /// suite until the CI job cap with no failing test named — which is exactly
    /// the month-long diagnosis this regression already cost once. Racing the
    /// call against a deadline converts that hang into an attributed failure.
    func testRootPathResolvesWithoutHanging() {
        let done = expectation(description: "root(for: \"/\") returned")
        // Detached so the spin (if it returns) occupies a cooperative-pool
        // thread while `wait` blocks the test thread — a hang then trips the
        // timeout instead of deadlocking the waiter.
        Task.detached {
            let resolved = await GitRootResolver().root(for: "/")
            XCTAssertEqual(resolved, "/", "the root must resolve to itself")
            done.fulfill()
        }
        wait(for: [done], timeout: 2.0)
    }

    func testCachedResultIsStable() async throws {
        let repo = tmpDir()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        let resolver = GitRootResolver()
        let first = await resolver.root(for: repo.path)
        let second = await resolver.root(for: repo.path)
        XCTAssertEqual(first, second)
    }
}
