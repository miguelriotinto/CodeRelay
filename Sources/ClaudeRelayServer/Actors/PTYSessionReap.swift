import Foundation
import os
import CPTYShim
import ClaudeRelayKit

// MARK: - Reaping a session's processes

/// The teardown half of `PTYSession`: signalling everything a PTY started.
///
/// Split into its own file because every member is `static` and takes its
/// targets as parameters — a property the tests depend on (see `_testOnly_reap`),
/// so nothing here closes over actor state and the extraction is mechanical.
extension PTYSession {

    /// SIGTERM everything in the child's terminal **session**, then escalate to
    /// SIGKILL after 2 s for whatever is left.
    ///
    /// **Why the session and not just the group.** `forkpty` calls `setsid()`, so
    /// the child leads a new session *and* its own process group. Signalling that
    /// group is necessary but not sufficient, because the interactive `zsh` inside
    /// it runs job control: every job it starts gets its **own** process group via
    /// `setpgid`. So the real tree looks like this —
    ///
    ///     login 4083   pgid 4083   <- the only group a group-kill reaches
    ///       zsh 4084   pgid 4084   <- already a different group
    ///         sleep    pgid 4109
    ///         python   pgid 4110
    ///
    /// `killpg(4083, …)` reaches exactly one process. Measured against the shipped
    /// group-only reap: `login` died, and `zsh` plus three jobs survived, reparented
    /// to launchd, still alive at T+15 s. The session is the boundary that means
    /// "everything this PTY started" — job control fragments groups freely, but
    /// nothing leaves the session without calling `setsid()` itself.
    ///
    /// Those survivors are the leak. Each keeps the resources of a session the
    /// server believes it already reclaimed, and they accumulate across every
    /// create/terminate cycle for as long as the server lives. Note this is a
    /// *process* leak only: the master fd is released correctly (verified — the
    /// server's `/dev/ptmx` count returns to baseline), so it no longer implies
    /// `kern.tty.ptmx_max` exhaustion the way the `FD_CLOEXEC` bug did.
    ///
    /// **Why the group signal is still here.** The session sweep depends on a
    /// sysctl enumeration that can fail (ENOMEM under process churn, -1 for any
    /// other reason), and `sessionID == -1` means the init-time lookup failed. The
    /// group kill needs no enumeration, so it is the floor: worst case we degrade
    /// to exactly the previous behaviour rather than signalling nothing.
    ///
    /// Neither signal can hit the server itself, and for the same reason in both
    /// cases — the `setsid()`. The child's group and session are its own, never
    /// ours, so the server is not a member of either set. The sweep additionally
    /// filters pid <= 1.
    ///
    /// SIGCHLD is `SIG_IGN` in `main.swift`, so the kernel auto-reaps; no waitpid.
    ///
    /// `static` and taking its targets as parameters so the reap is testable
    /// against a stand-in group: nothing outside the child's session can join the
    /// real one (`setpgid` across sessions is EPERM), so a test cannot place an
    /// observable member in it. See `PTYTerminateProcessGroupTests`.
    /// Internal rather than `private` only because `terminate()` lives in
    /// `PTYSession.swift` and Swift scopes `private` to the file. The two helpers
    /// below stay `private`: every caller is in this file.
    static func reap(pid: pid_t, sessionLabel: String, startTime: Int64,
                     sessionID: pid_t) {
        // ESRCH means "already gone", which is success here, so it is not worth an
        // error line; anything else is.
        if killpg(pid, SIGTERM) != 0 && errno != ESRCH {
            RelayLogger.log(.error, category: "session",
                "PTYSession \(sessionLabel) SIGTERM failed for process group \(pid): errno \(errno)")
        }
        if kill(pid, SIGTERM) != 0 && errno != ESRCH {
            RelayLogger.log(.error, category: "session",
                "PTYSession \(sessionLabel) SIGTERM failed for pid \(pid): errno \(errno)")
        }
        signalSessionMembers(sessionID: sessionID, signal: SIGTERM,
                             sessionLabel: sessionLabel, excluding: pid)

        // zsh exits within ~100 ms of SIGTERM in practice, so 2 s is a generous
        // margin before forcing the issue.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            // Liveness is checked on the process GROUP, not on the leader.
            //
            // `kill(pid, 0)` was the wrong question, and it gated the whole
            // escalation: the leader is `login`/`zsh`, which exits promptly on
            // SIGTERM, while the processes that actually linger are the agent and
            // its children. So in the exact case this backstop exists for — leader
            // gone, descendants still running — the old check saw "already dead",
            // returned, and never escalated. `killpg(pid, 0)` instead succeeds
            // while *any* member of the group remains.
            //
            // The session is checked alongside the group, because the group is the
            // narrower set: with job control fragmenting groups, the common survivor
            // case is an *empty* leader group and a non-empty session. Gating on the
            // group alone would skip the escalation for precisely the processes the
            // session sweep was added to reach.
            let survivors = Self.sessionMembers(sessionID: sessionID, excluding: pid)
            guard killpg(pid, 0) == 0 || !survivors.isEmpty else { return }

            // Skip SIGKILL if the pid was recycled for an unrelated process in the
            // last 2 s (C-10). `startTime == -1` means the init-time lookup failed,
            // in which case we accept the residual reuse risk and proceed.
            //
            // Only meaningful while the leader itself is alive: once it has exited,
            // its pid is not what the surviving members are, so there is no start
            // time to compare. A recycled pid also cannot redirect the group
            // signal, because pid reuse does not transfer group leadership — the
            // group named here either still holds our own descendants or is empty
            // (and then `killpg` above already returned ESRCH).
            if kill(pid, 0) == 0, startTime != -1 {
                let current = relay_get_process_start_time(pid)
                if current != -1 && current != startTime {
                    RelayLogger.log(.error, category: "session",
                        "PTYSession \(sessionLabel) PID \(pid) was recycled (start \(startTime) → \(current)); skipping SIGKILL")
                    return
                }
            }
            // Group first, then the leader — same reasoning as the SIGTERM above.
            // Without the group signal the escalation inherits the original bug: it
            // would force-kill the one process that was already ignoring SIGTERM
            // and leave its children running.
            if killpg(pid, SIGKILL) != 0 && errno != ESRCH {
                RelayLogger.log(.error, category: "session",
                    "PTYSession \(sessionLabel) SIGKILL failed for process group \(pid): errno \(errno)")
            }
            if kill(pid, SIGKILL) != 0 && errno != ESRCH {
                RelayLogger.log(.error, category: "session",
                    "PTYSession \(sessionLabel) SIGKILL failed for pid \(pid): errno \(errno)")
            }
            // Re-enumerate rather than reusing `survivors` from the liveness check
            // above: SIGKILL to the group may have already cleared some of them, and
            // a pid that died in between could have been recycled by an unrelated
            // process. A fresh sweep is one extra sysctl on a path that runs once
            // per session teardown.
            Self.signalSessionMembers(sessionID: sessionID, signal: SIGKILL,
                                      sessionLabel: sessionLabel, excluding: pid)
        }
    }

    /// Live members of terminal session `sessionID`, excluding `excluding` (the
    /// leader, which every caller signals directly) and the server itself.
    ///
    /// Empty when the sweep is unavailable — `sessionID == -1` (the init-time
    /// `getsid` failed) or the enumeration errored. Callers must treat empty as "no
    /// information", never as "nothing survived": the group signal is the floor that
    /// makes that degradation safe.
    private static func sessionMembers(sessionID: pid_t, excluding: pid_t) -> [pid_t] {
        guard sessionID > 1 else { return [] }
        // Never sweep our own session. Filtering the server's pid out of the results
        // is not enough on its own: our session also contains the launchd job's other
        // members and, in a test harness, the runner and its whole tree — so a
        // mistaken sessionID here would kill the relay and every session it hosts.
        //
        // This is a real defect's guard, not a hypothetical one. `getsid(childPID)`
        // read from the parent after `forkpty` returns the *parent's* session (the
        // child has not run `setsid()` yet), and an earlier draft of this fix stored
        // exactly that — which SIGKILLed the test runner. `childSessionID` is now
        // `childPID` by construction; this makes the failure mode "signal nothing"
        // even if that ever regresses.
        guard sessionID != getsid(0) else {
            RelayLogger.log(.error, category: "session",
                "PTYSession session sweep refused: \(sessionID) is the server's own session")
            return []
        }
        // A PTY session holding more than this many processes means something has
        // gone very wrong; the cap bounds the stack buffer rather than the sweep's
        // correctness in any realistic tree.
        var buffer = [Int32](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBufferPointer { buf in
            relay_get_session_members(sessionID, buf.baseAddress, Int32(buf.count))
        }
        guard count > 0 else { return [] }
        let ownPID = getpid()
        return buffer.prefix(Int(count))
            .filter { $0 != excluding && $0 != ownPID }
    }

    /// Send `signal` to every member of the child's terminal session.
    ///
    /// This is what reaches the processes a group signal misses — see `reap`'s note
    /// on job control fragmenting a session into many groups.
    private static func signalSessionMembers(sessionID: pid_t, signal: Int32,
                                             sessionLabel: String, excluding: pid_t) {
        let members = sessionMembers(sessionID: sessionID, excluding: excluding)
        guard !members.isEmpty else { return }
        // Logged at info, not error: reaching this branch is normal (any background
        // job puts itself in its own group), and it is the only visible record that
        // the sweep did work a group kill could not.
        RelayLogger.log(.info, category: "session",
            "PTYSession \(sessionLabel) signalling \(members.count) session member(s) with \(signal): \(members)")
        for member in members {
            // ESRCH is expected and benign: the member may have exited between the
            // enumeration and this signal.
            if kill(member, signal) != 0 && errno != ESRCH {
                RelayLogger.log(.error, category: "session",
                    "PTYSession \(sessionLabel) signal \(signal) failed for session member \(member): errno \(errno)")
            }
        }
    }

    // MARK: - Test Hooks

    /// Runs `terminate()`'s exact reap against an arbitrary process group.
    ///
    /// `startTime: -1` skips the pid-recycle guard, which is what a stand-in group
    /// needs: the guard exists to protect *our* forked child's pid, and a test
    /// group has no `relay_get_process_start_time` baseline recorded at fork.
    ///
    /// `sessionID` defaults to -1 so the group-reap tests drive the group path in
    /// isolation: a stand-in group lives in the *test runner's* session, so passing a
    /// real session id would have the reap signal the test process itself. Tests for
    /// the session sweep pass one explicitly.
    static func _testOnly_reap(pid: pid_t, sessionLabel: String, sessionID: pid_t = -1) {
        reap(pid: pid, sessionLabel: sessionLabel, startTime: -1, sessionID: sessionID)
    }

    /// Runs the session sweep's enumeration alone, so a test can assert *which* pids
    /// it finds without signalling them — the only way to cover the fragmented-group
    /// case, since the processes that prove the bug cannot be signalled from a test
    /// without killing its own session. See `PTYTerminateProcessGroupTests`.
    static func _testOnly_sessionMembers(sessionID: pid_t, excluding: pid_t) -> [pid_t] {
        sessionMembers(sessionID: sessionID, excluding: excluding)
    }
}
