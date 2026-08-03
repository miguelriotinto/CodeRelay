import XCTest
import Foundation
import CPTYShim
@testable import ClaudeRelayServer

/// `terminate()` must reap the session's whole process **group**, not just the
/// one process it forked.
///
/// `forkpty` calls `setsid()` in the child, making it a session and
/// process-group leader whose pgid equals its pid. Everything the session then
/// runs inherits that group: `login`, the `zsh` it execs, the coding agent the
/// user starts, and that agent's children. A bare `kill(childPID, …)` reaches
/// only the process at the top of that tree.
///
/// That was the bug. The leader (`login`/`zsh`) exits promptly on SIGTERM while
/// the agent and its children keep running, reparented to launchd. They
/// accumulate across every create/terminate cycle for the life of the server,
/// holding the resources of sessions the server believes it already reclaimed,
/// until the machine can no longer start a shell at all.
///
/// It is a distinct leak from the `FD_CLOEXEC` one in
/// `PTYMasterFDInheritanceTests`: that flag stops a master being *duplicated*
/// into other sessions' shells and says nothing about descendants outliving the
/// process they were signalled through. Fixing one does not fix the other, which
/// is why both earn tests.
final class PTYTerminateProcessGroupTests: XCTestCase {

    /// The signal `terminate()` sends must be a **group** signal, so that a
    /// descendant which is not `childPID` itself still receives it.
    ///
    /// Measured on a stand-in group rather than on the session's own group, and
    /// the reason is a kernel rule rather than convenience: `forkpty` calls
    /// `setsid()`, so the child is in a different *session* from the test, and
    /// `setpgid`/`POSIX_SPAWN_SETPGROUP` into a group in another session is EPERM
    /// by design. Nothing outside that session can join the group, so no test can
    /// place an observable member inside it. Driving the session's shell instead
    /// doesn't work either: `PTYSession` execs setuid `login`, and under a test
    /// harness `login -fp` echoes commands without running them (the host quirk
    /// documented in `PTYMasterFDInheritanceTests`), so no descendant is ever
    /// created and the test could only skip — a silent pass for the exact bug it
    /// exists to catch.
    ///
    /// So this asserts the property that *is* reachable, and it is the one that
    /// broke: `terminate()`'s reap must reach a group, and it must reach a member
    /// that is not the leader. A `sleep` is parked in its own new group with a
    /// non-leader child, `PTYSession`'s exact reap sequence is applied to it, and
    /// both are required to die. Against the old single-pid `kill` the non-leader
    /// survives; against `killpg` it does not.
    func testReapSequenceKillsNonLeaderGroupMembers() async throws {
        let (leader, member) = try Self.spawnGroupWithNonLeaderChild()
        defer { kill(leader, SIGKILL); kill(member, SIGKILL) }

        XCTAssertEqual(kill(leader, 0), 0, "group leader \(leader) should be alive")
        XCTAssertEqual(kill(member, 0), 0, "non-leader member \(member) should be alive")

        // Exactly what PTYSession.terminate() does to a session's group.
        PTYSession._testOnly_reap(pid: leader, sessionLabel: "test")

        let memberDied = await Self.waitForExit(pid: member, timeout: 10.0)
        XCTAssertTrue(memberDied, """
            the non-leader member of the group (pid \(member)) survived the reap. Signalling only \
            the leader pid leaves the rest of the pty's process group running: the leader \
            (login/zsh) exits and its children reparent to launchd, so every terminated session \
            leaks its agent and the machine eventually cannot start a shell.
            """)
    }

    /// `terminate()` must still reap the group when the **leader has already
    /// exited** but its children have not.
    ///
    /// This is the common shape in production, and it is what made the old
    /// escalation dead code: `login`/`zsh` exits promptly on SIGTERM while the
    /// agent lingers, and the old guard asked `kill(leaderPid, 0) == 0` before
    /// escalating — so in exactly this case it concluded "already dead" and
    /// returned without ever sending SIGKILL to the survivors.
    func testReapSequenceEscalatesWhenTheLeaderIsAlreadyGone() async throws {
        let (leader, member) = try Self.spawnGroupWithNonLeaderChild(memberIgnoresSIGTERM: true)
        defer { kill(leader, SIGKILL); kill(member, SIGKILL) }

        // Kill the leader outright, leaving an orphaned group behind.
        kill(leader, SIGKILL)
        _ = await Self.waitForExit(pid: leader, timeout: 5.0)
        XCTAssertEqual(kill(member, 0), 0, "the member should outlive its leader for this test")

        PTYSession._testOnly_reap(pid: leader, sessionLabel: "test")

        let memberDied = await Self.waitForExit(pid: member, timeout: 10.0)
        XCTAssertTrue(memberDied, """
            a group whose leader had already exited was never reaped (pid \(member) survived). \
            Gating the SIGKILL escalation on the leader's own liveness skips it in the common \
            case: the leader exits on SIGTERM and the agent it spawned is what lingers.
            """)
    }

    /// Spawns `sh` as a **new process-group leader**, which in turn forks a child
    /// that stays in that group without leading it. Returns both pids.
    ///
    /// `sleep` under `sh` rather than a busy loop so a process leaked by a failing
    /// run can't burn CPU. When `memberIgnoresSIGTERM` is set the child traps
    /// SIGTERM, which forces the reap to reach its SIGKILL escalation to succeed.
    private static func spawnGroupWithNonLeaderChild(
        memberIgnoresSIGTERM: Bool = false
    ) throws -> (leader: pid_t, member: pid_t) {
        let trap = memberIgnoresSIGTERM ? "trap '' TERM; " : ""
        // The child prints its own pid, so the test learns it without guessing.
        let script = "\(trap)sleep 600 & echo $!; wait"

        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("pty-group-probe-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: outputPath) }
        FileManager.default.createFile(atPath: outputPath, contents: nil)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // pgroup 0 => the spawned process becomes its own group leader.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_addopen(&actions, 1, outputPath, O_WRONLY | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_RDWR, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sh"), strdup("-c"), strdup(script), nil]
        defer { for arg in argv where arg != nil { free(arg) } }

        var leader: pid_t = 0
        let result = argv.withUnsafeBufferPointer { buffer in
            posix_spawn(&leader, "/bin/sh", &actions, &attr, buffer.baseAddress, environ)
        }
        guard result == 0 else {
            throw XCTSkip("posix_spawn of the probe group failed (errno \(result))")
        }

        // Read back the child's pid. Polling a file rather than a pipe keeps this
        // free of fd bookkeeping in the parent.
        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: outputPath, encoding: .utf8),
               let first = text.split(whereSeparator: \.isNewline).first,
               let member = pid_t(first.trimmingCharacters(in: .whitespaces)) {
                return (leader, member)
            }
            usleep(100_000)
        }
        kill(leader, SIGKILL)
        throw XCTSkip("the probe group's child never reported its pid")
    }

    /// Polls until `pid` is gone, or the timeout elapses.
    ///
    /// Polling rather than one sleep-then-check: the exit is asynchronous
    /// (SIGTERM, then a 2 s escalation to SIGKILL), so a fixed wait would be
    /// either flaky or much slower than necessary.
    private static func waitForExit(pid: pid_t, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // ESRCH means gone. EPERM would mean the pid now belongs to another
            // user's process, which also means ours is gone.
            if kill(pid, 0) != 0 && (errno == ESRCH || errno == EPERM) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
