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
///
/// **The group is not the whole boundary.** Reaping the group was necessary but
/// not sufficient: the `zsh` inside the session runs job control, which puts every
/// job in its *own* process group, so a group kill reaches `login` and nothing
/// else. Measured on a live server after the group fix shipped, a terminated
/// session left `zsh` and three jobs alive and reparented to launchd. The reap
/// therefore sweeps the child's terminal **session**, which job control cannot
/// fragment. See `testSessionSweepFindsMembersInOtherProcessGroups`, and keep the
/// group-signal tests below: the group kill is the fallback for when the sweep's
/// enumeration is unavailable.
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

    /// A process group is too narrow a boundary: the reap must reach a member of the
    /// child's **terminal session** that is in a *different* process group.
    ///
    /// This is the shape a real session always has, and the group-only reap missed
    /// all of it. `forkpty` calls `setsid()`, so the child leads a new session — but
    /// the interactive `zsh` inside it runs job control, and job control puts every
    /// job in its own group via `setpgid`. Measured against the shipped group-only
    /// reap on a live server: `login` died and `zsh` plus three jobs survived,
    /// reparented to launchd, still alive at T+15 s.
    ///
    /// The test builds that shape directly — a session leader with a job that left
    /// its group — because `sh -m` does not fragment groups without a controlling
    /// tty, so only an explicit `setpgid` reproduces what zsh does. The fork is
    /// necessary for a second reason: a stand-in group can live in the test runner's
    /// own session, but a stand-in *session* cannot, or the reap would signal the
    /// test process itself.
    ///
    /// Asserts on the **enumeration** rather than by signalling, which is what makes
    /// it a real test rather than a skip. `_testOnly_sessionMembers` is the exact
    /// function the reap uses to decide what to signal, so covering it covers the
    /// fix; actually signalling this session from here would kill the probe's own
    /// leader and prove nothing about the fragmented job.
    func testSessionSweepFindsMembersInOtherProcessGroups() async throws {
        let probe = try Self.spawnSessionWithFragmentedGroup()
        defer { kill(probe.job, SIGKILL); kill(probe.leader, SIGKILL) }

        XCTAssertEqual(kill(probe.leader, 0), 0, "session leader should be alive")
        XCTAssertEqual(kill(probe.job, 0), 0, "the fragmented job should be alive")

        // Precondition: this is only a meaningful test if the job really left the
        // leader's group. If it didn't, a group kill would have sufficed.
        XCTAssertNotEqual(getpgid(probe.job), getpgid(probe.leader), """
            the probe job is still in the leader's process group, so it cannot \
            distinguish a session sweep from a group kill
            """)
        XCTAssertEqual(getsid(probe.job), probe.leader,
                       "the probe job should still be in the leader's session")

        let members = PTYSession._testOnly_sessionMembers(sessionID: probe.leader,
                                                          excluding: probe.leader)

        XCTAssertTrue(members.contains(probe.job), """
            the session sweep did not find pid \(probe.job), which is in the session \
            (sid \(probe.leader)) but in its own process group \(getpgid(probe.job)). \
            A group-only reap leaves exactly these processes running: zsh puts every \
            job in its own group, so a terminated session leaks its agent and every \
            command that agent started.
            """)
        XCTAssertFalse(members.contains(probe.leader),
                       "the excluded leader must not appear; callers signal it directly")
        XCTAssertFalse(members.contains(getpid()),
                       "the sweep must never report the server's own pid")
    }

    /// The sweep must return **nothing** when handed our own session id — not merely
    /// filter our own pid out of the results.
    ///
    /// This guards a defect that really happened, and it is the most dangerous one in
    /// this file. `getsid(childPID)` called from the parent after `forkpty` returns
    /// the *parent's* session, because the child has not reached its `setsid()` yet
    /// (measured: 8/8 calls). An earlier draft of the session sweep stored that value
    /// and reaped it — which SIGKILLed the test runner, and in production would have
    /// killed the relay and every session it hosts on a routine teardown.
    ///
    /// Filtering just `getpid()` would not have saved it: our session also holds the
    /// launchd job's other members, and under a harness the runner's whole tree.
    func testSessionSweepRefusesTheServersOwnSession() throws {
        let ownSession = getsid(0)
        try XCTSkipIf(ownSession == -1, "getsid failed for the test process")

        // Sanity: this process really is in that session, so a sweep that did not
        // refuse would have something to return.
        XCTAssertEqual(getsid(getpid()), ownSession)

        let members = PTYSession._testOnly_sessionMembers(sessionID: ownSession,
                                                          excluding: -1)
        XCTAssertTrue(members.isEmpty, """
            the sweep returned \(members.count) member(s) for the caller's OWN session. \
            In production that set is the relay server plus every PTY it hosts, and the \
            reap SIGKILLs it — turning each session teardown into a server suicide.
            """)
    }

    /// `childSessionID` must equal `childPID`, never a value read back with
    /// `getsid` — see `testSessionSweepRefusesTheServersOwnSession` for why reading
    /// it is unsafe.
    ///
    /// `setsid()` in the child guarantees sid == pid, so this is checkable without
    /// racing anything: the assertion is that the code *asserts* the session rather
    /// than observing it.
    func testChildSessionIDIsTheChildPIDAndNotTheServersSession() async throws {
        let session = try PTYSession(sessionId: UUID(), cols: 80, rows: 24,
                                     scrollbackSize: 4096)
        defer { Task { await session.terminate() } }

        let sid = await session._testOnly_childSessionID
        let ownSession = getsid(0)

        XCTAssertNotEqual(sid, ownSession, """
            childSessionID is the SERVER's session (\(ownSession)). terminate() would \
            sweep it and SIGKILL the relay. This is what a getsid(childPID) read from \
            the parent returns, because the child has not run setsid() yet.
            """)
        XCTAssertGreaterThan(sid, 1, "the swept session id must be a real pid")
    }

    /// An unavailable sweep must degrade to the group signal, not to signalling
    /// nothing and not to a crash.
    ///
    /// `sessionID == -1` is the real path here: `getsid` at init can fail, and the
    /// reap still has to reap what it can.
    func testUnavailableSessionSweepStillReapsTheGroup() async throws {
        let (leader, member) = try Self.spawnGroupWithNonLeaderChild()
        defer { kill(leader, SIGKILL); kill(member, SIGKILL) }

        XCTAssertTrue(PTYSession._testOnly_sessionMembers(sessionID: -1, excluding: -1).isEmpty,
                      "an unavailable sweep must report no members rather than guessing")

        // sessionID: -1 is what a failed init-time getsid leaves behind.
        PTYSession._testOnly_reap(pid: leader, sessionLabel: "test", sessionID: -1)

        let memberDied = await Self.waitForExit(pid: member, timeout: 10.0)
        XCTAssertTrue(memberDied, """
            with the session sweep unavailable the reap stopped reaping the group too \
            (pid \(member) survived). The group kill is the floor that makes a failed \
            enumeration safe; without it a sysctl failure leaks the entire session.
            """)
    }

    /// Spawns a **session leader** (as `forkpty` does) with one child that leaves the
    /// leader's process group, exactly as zsh's job control does for every job.
    ///
    /// Returns the leader (which is also the session id) and the fragmented job.
    /// Both are `sleep`s, so a process leaked by a failing run cannot burn CPU.
    private static func spawnSessionWithFragmentedGroup() throws
        -> (leader: pid_t, job: pid_t) {
        // `sh -c` with an explicit setpgid via a tiny script: `sh -m` does not
        // fragment groups without a controlling tty, so job control cannot be relied
        // on to produce the shape here. `perl` is used for setpgid because /bin/sh
        // has no builtin for it and it is present on every macOS.
        let script = """
        perl -e 'setpgrp(0,0); exec("/bin/sleep", "600")' & echo $!; exec /bin/sleep 600
        """

        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("pty-session-probe-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: outputPath) }
        FileManager.default.createFile(atPath: outputPath, contents: nil)

        // `posix_spawnattr_t` is an opaque pointer on Darwin (so Optional in
        // Swift) and a plain struct on Linux; declaring the storage per platform
        // lets every call below take `&attr` unchanged.
        #if os(Linux)
        var attr = posix_spawnattr_t()
        var actions = posix_spawn_file_actions_t()
        #else
        var attr: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        #endif
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // POSIX_SPAWN_SETSID makes the spawned process a *session* leader, which is
        // what `forkpty` does and what this test needs: the probe must not share the
        // test runner's session, or the reap under test would signal the runner.
        posix_spawnattr_setflags(&attr, relay_posix_spawn_setsid_flag())

        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_addopen(&actions, 1, outputPath, O_WRONLY | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_RDWR, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sh"), strdup("-c"), strdup(script), nil]
        defer { for arg in argv where arg != nil { free(arg) } }

        var leader: pid_t = 0
        let result = argv.withUnsafeBufferPointer { buffer in
            posix_spawn(&leader, "/bin/sh", &actions, &attr, buffer.baseAddress!, environ)
        }
        guard result == 0 else {
            throw XCTSkip("posix_spawn of the probe session failed (errno \(result))")
        }

        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: outputPath, encoding: .utf8),
               let first = text.split(whereSeparator: \.isNewline).first,
               let job = pid_t(first.trimmingCharacters(in: .whitespaces)),
               kill(job, 0) == 0,
               // Wait for the job to have actually left the group; the echo races
               // perl's setpgrp.
               getpgid(job) != getpgid(leader) {
                return (leader, job)
            }
            usleep(100_000)
        }
        kill(leader, SIGKILL)
        throw XCTSkip("the probe session's fragmented job never appeared")
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

        #if os(Linux)
        var attr = posix_spawnattr_t()
        var actions = posix_spawn_file_actions_t()
        #else
        var attr: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        #endif
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // pgroup 0 => the spawned process becomes its own group leader.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_addopen(&actions, 1, outputPath, O_WRONLY | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_RDWR, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sh"), strdup("-c"), strdup(script), nil]
        defer { for arg in argv where arg != nil { free(arg) } }

        var leader: pid_t = 0
        let result = argv.withUnsafeBufferPointer { buffer in
            posix_spawn(&leader, "/bin/sh", &actions, &attr, buffer.baseAddress!, environ)
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
