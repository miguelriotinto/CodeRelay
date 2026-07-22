import XCTest
import CPTYShim
@testable import ClaudeRelayServer

final class ProcCwdShimTests: XCTestCase {
    func testShimReadsOwnCwd() {
        var buf = [CChar](repeating: 0, count: 1024)
        let rc = relay_proc_cwd(Int32(ProcessInfo.processInfo.processIdentifier), &buf, 1024)
        XCTAssertEqual(rc, 0, "shim should read the test process's own cwd")
        if rc == 0 { XCTAssertFalse(String(cString: buf).isEmpty) }
    }
}
