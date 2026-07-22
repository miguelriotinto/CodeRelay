import XCTest
import CPTYShim
import Foundation
@testable import ClaudeRelayServer

final class ProcCwdShimTests: XCTestCase {
    func testShimReadsOwnCwd() {
        var buf = [CChar](repeating: 0, count: 1024)
        let rc = relay_proc_cwd(Int32(ProcessInfo.processInfo.processIdentifier), &buf, 1024)
        XCTAssertEqual(rc, 0, "shim should read the test process's own cwd")
        if rc == 0 { XCTAssertFalse(String(cString: buf).isEmpty) }
    }

    /// Regression for the proc_listallpids double-divide (Codex PR #29 finding 1):
    /// the descendant walk must scan the FULL pid array, not ~1/4 of it.
    ///
    /// Start from `launchd` (pid 1): its OWN cwd is unreadable (sugid → EPERM),
    /// so `relay_proc_cwd` fails at depth 0 and the walk MUST fall through to the
    /// proc_listallpids scan + parent match to find a readable descendant. Its
    /// children are spread across the full system pid array, so with the former
    /// truncation (only the first ~1/4 scanned) this frequently returned -1.
    /// A correct full-array scan resolves some descendant's cwd.
    func testDescendantWalkScansFullArrayFromUnreadableRoot() {
        // Precondition: pid 1's own cwd is not directly readable (proves the
        // walk cannot short-circuit at depth 0 and must scan the pid array).
        var probe = [CChar](repeating: 0, count: 1024)
        XCTAssertNotEqual(relay_proc_cwd(1, &probe, 1024), 0,
                          "expected launchd's own cwd to be unreadable (EPERM)")

        var buf = [CChar](repeating: 0, count: 1024)
        let rc = relay_proc_cwd_descendant(1, &buf, 1024)
        XCTAssertEqual(rc, 0, "descendant walk from launchd should resolve a descendant cwd")
        if rc == 0 { XCTAssertFalse(String(cString: buf).isEmpty) }
    }
}
