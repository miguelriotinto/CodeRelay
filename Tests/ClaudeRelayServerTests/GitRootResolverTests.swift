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
    /// guaranteed. Under the Objective-C `NSURL` backing (Swift 6.1 / Xcode 16,
    /// i.e. CI) `"/"` maps to `"/.."` and then `"/../.."` forever, so the guard
    /// never fired and `computeRoot` spun with a filesystem probe per iteration.
    /// It hung `swift test` on CI for ~10 min and passed locally on Swift 6.2,
    /// whose `URL` does converge — so the assertion below is on the *list*, which
    /// is implementation-independent, rather than on wall-clock time.
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

    /// Resolving a path directly at the filesystem root must return promptly.
    /// Guards the hang end-to-end: the old walk never returned for this input on
    /// an NSURL-backed Foundation.
    func testRootPathResolvesWithoutHanging() async {
        let resolved = await GitRootResolver().root(for: "/")
        XCTAssertFalse(resolved.contains(".."), "got \(resolved)")
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
