import XCTest
import CPTYShim
import Foundation

/// Smoke tests for `relay_get_process_start_time` — the C-shim addition used
/// by `PTYSession.terminate` to detect PID reuse before sending SIGKILL (C-10).
final class ProcessStartTimeTests: XCTestCase {

    /// The current process must report a plausible start time (non-negative
    /// and in the past).
    func testCurrentProcessStartTimeIsPlausible() {
        let mypid = Int32(ProcessInfo.processInfo.processIdentifier)
        let start = relay_get_process_start_time(mypid)
        XCTAssertGreaterThan(start, 0, "Start time must be positive")
        let nowMicros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        XCTAssertLessThanOrEqual(start, nowMicros,
            "Start time must be in the past (or equal to now)")
    }

    /// Repeated calls must return the same value for a given PID — the
    /// start time doesn't move while the process is alive.
    func testStartTimeIsStableAcrossCalls() {
        let mypid = Int32(ProcessInfo.processInfo.processIdentifier)
        let a = relay_get_process_start_time(mypid)
        let b = relay_get_process_start_time(mypid)
        XCTAssertEqual(a, b)
    }

    /// Nonexistent PID returns -1.
    func testNonExistentPIDReturnsError() {
        // Use a PID well out of the typical range. sysctl returns an empty
        // kinfo_proc for a dead/unknown PID; our shim returns -1 for that.
        let start = relay_get_process_start_time(999_999)
        XCTAssertEqual(start, -1)
    }
}
