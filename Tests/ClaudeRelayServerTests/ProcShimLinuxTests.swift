#if os(Linux)
import XCTest
import Foundation
import CPTYShim

/// The `/proc`-backed half of `pty_shim.h` (`pty_shim_linux.c`), checked
/// against real processes rather than fixtures: the test runner itself, and
/// children it spawns with known argv, parentage and session.
///
/// `relay_proc_cwd` / `relay_proc_cwd_descendant` are covered by
/// `ProcCwdShimTests`, which runs unmodified on both platforms.
final class ProcShimLinuxTests: XCTestCase {

    // MARK: - Helpers

    /// Spawns `argv` detached from stdio. `setsid` makes it lead its own
    /// session, as `forkpty` children do.
    private func spawn(_ argv: [String], setsid: Bool = false) throws -> pid_t {
        var attr = posix_spawnattr_t()
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        if setsid {
            posix_spawnattr_setflags(&attr, relay_posix_spawn_setsid_flag())
        }

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_RDWR, 0)

        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for arg in cArgs where arg != nil { free(arg) } }

        var pid: pid_t = 0
        let result = cArgs.withUnsafeBufferPointer { buffer in
            posix_spawn(&pid, argv[0], &actions, &attr, buffer.baseAddress!, environ)
        }
        guard result == 0 else { throw XCTSkip("posix_spawn failed: errno \(result)") }
        waitForExec(pid)
        return pid
    }

    /// `posix_spawn` returns before the child reaches `execve`, and until it does
    /// `/proc/<pid>/cmdline` is empty and `/proc/<pid>/exe` still points at the
    /// forked copy of this test binary. Production never observes that window —
    /// it inspects processes that have been running — so the wait belongs in the
    /// test, not the shim. Polls until cmdline is populated (or a short bound).
    private func waitForExec(_ pid: pid_t) {
        for _ in 0..<200 {
            if let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline"), !data.isEmpty {
                return
            }
            usleep(1000)
        }
    }

    private func reap(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    private func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard relay_get_process_name(pid, &buf, 256) == 0 else { return nil }
        return String(cString: buf)
    }

    private func scriptName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard relay_get_process_script_name(pid, &buf, 256) == 0 else { return nil }
        return String(cString: buf)
    }

    // MARK: - Process name

    func testProcessNameIsTheExecutableBasenameOfTheCallingProcess() throws {
        let exe = try XCTUnwrap(
            FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") as String?)
        let expected = (exe as NSString).lastPathComponent
        XCTAssertEqual(processName(getpid()), expected)
    }

    func testProcessNameOfSpawnedSleepIsSleep() throws {
        let pid = try spawn(["/bin/sleep", "30"])
        defer { reap(pid) }
        XCTAssertEqual(processName(pid), "sleep")
    }

    /// The kernel appends " (deleted)" to `exe` once the binary is unlinked —
    /// which is what an upgrade mid-session does. The name must stay clean or
    /// agent detection would stop matching the running agent.
    func testProcessNameDropsTheDeletedSuffixAfterTheBinaryIsUnlinked() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proc-shim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("relay-probe-sleep").path
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: copy)

        let pid = try spawn([copy, "30"])
        defer { reap(pid) }
        try FileManager.default.removeItem(atPath: copy)

        XCTAssertEqual(processName(pid), "relay-probe-sleep")
    }

    func testProcessNameFailsForAPidThatDoesNotExist() {
        // pid_max is 4,194,304 on 64-bit Linux; nothing sits this high.
        XCTAssertNil(processName(4_000_000))
    }

    // MARK: - Script name

    /// A shell script started as `sh <path>` is what `node <agent>` looks like
    /// to the agent detector: argv[1] is the script whose basename we match.
    func testScriptNameIsTheBasenameOfArgvOne() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proc-shim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("codex").path
        try "#!/bin/sh\nexec sleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)

        let pid = try spawn(["/bin/sh", script])
        defer { reap(pid) }
        XCTAssertEqual(scriptName(pid), "codex", "argv[1] basename is what agent detection matches")
        // The exec basename is the interpreter. `/proc/<pid>/exe` resolves the
        // symlink, so on a distro where /bin/sh → bash it reads "bash"; the point
        // is only that it is the interpreter, never the script.
        XCTAssertNotEqual(processName(pid), "codex")
    }

    func testScriptNameFailsWhenThereIsNoArgvOne() throws {
        let pid = try spawn(["/bin/sleep", "30"])
        defer { reap(pid) }
        // argv[1] is "30" — present, so the shim reports it; the caller's
        // agent registry is what decides "30" is not an agent.
        XCTAssertEqual(scriptName(pid), "30")

        let bare = try spawn(["/bin/cat"])
        defer { reap(bare) }
        XCTAssertNil(scriptName(bare))
    }

    // MARK: - Parent, session, start time

    func testParentPidOfASpawnedChildIsTheTestProcess() throws {
        let pid = try spawn(["/bin/sleep", "30"])
        defer { reap(pid) }
        XCTAssertEqual(relay_get_parent_pid(pid), getpid())
        XCTAssertEqual(relay_get_parent_pid(4_000_000), -1)
    }

    func testSessionMembersFindsASessionLeaderAndOnlyItsSession() throws {
        let leader = try spawn(["/bin/sleep", "30"], setsid: true)
        defer { reap(leader) }
        let bystander = try spawn(["/bin/sleep", "30"])
        defer { reap(bystander) }

        var members = [Int32](repeating: 0, count: 64)
        let count = relay_get_session_members(leader, &members, 64)
        XCTAssertGreaterThanOrEqual(count, 1)
        let found = Set(members.prefix(Int(max(count, 0))))
        XCTAssertTrue(found.contains(leader), "the leader is a member of its own session")
        XCTAssertFalse(found.contains(bystander), "a process in the runner's session must not be reported")
        XCTAssertFalse(found.contains(0) || found.contains(1), "pids 0 and 1 are never reported")
    }

    func testStartTimeIsStableForOneProcessAndPositive() throws {
        let pid = try spawn(["/bin/sleep", "30"])
        defer { reap(pid) }
        let first = relay_get_process_start_time(pid)
        let second = relay_get_process_start_time(pid)
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(first, second, "the value feeds an equality check for PID reuse; it must not drift")
        XCTAssertEqual(relay_get_process_start_time(4_000_000), -1)
    }

    /// Two processes started in sequence must not share a start time, or the
    /// PID-reuse guard could mistake a newcomer for the process it is about to
    /// SIGKILL. Clock ticks are 10 ms at HZ=100, so a short sleep separates them.
    func testStartTimesOfSuccessiveProcessesDiffer() throws {
        let first = try spawn(["/bin/sleep", "30"])
        defer { reap(first) }
        usleep(30_000)
        let second = try spawn(["/bin/sleep", "30"])
        defer { reap(second) }
        XCTAssertNotEqual(relay_get_process_start_time(first), relay_get_process_start_time(second))
    }

    func testSetsidFlagMatchesGlibc() {
        // glibc: #define POSIX_SPAWN_SETSID 0x80 (spawn.h, _GNU_SOURCE)
        XCTAssertEqual(relay_posix_spawn_setsid_flag(), 0x80)
    }
}
#endif
