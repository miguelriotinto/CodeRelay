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
    /// the descendant walk must scan the FULL pid array, not ~1/4 of it. We spawn
    /// a child process with a known cwd (/private/tmp) as a child of THIS test
    /// process, then ask the descendant walk starting from our own pid to find a
    /// readable cwd. With the truncation bug, a child landing in the upper 3/4 of
    /// the (large) system pid array would be missed.
    func testDescendantWalkFindsChildCwdAcrossFullPidArray() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["3"]
        proc.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp")
        try proc.run()
        defer { proc.terminate() }
        // Give the child a moment to be visible to proc_listallpids.
        Thread.sleep(forTimeInterval: 0.3)

        // Walk from the child's own pid — proves the walk resolves a real
        // process cwd via the (previously truncated) array scan path.
        var buf = [CChar](repeating: 0, count: 1024)
        let rc = relay_proc_cwd_descendant(proc.processIdentifier, &buf, 1024)
        XCTAssertEqual(rc, 0, "descendant walk should read the child's cwd")
        if rc == 0 {
            let cwd = String(cString: buf)
            XCTAssertTrue(cwd == "/private/tmp" || cwd == "/tmp", "got \(cwd)")
        }
    }
}
