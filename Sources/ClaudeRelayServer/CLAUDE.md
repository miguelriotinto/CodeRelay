# ClaudeRelayServer

Server-side guidance. Loads when working under `Sources/ClaudeRelayServer/`.

## PTY Sessions

`PTYSession` is an actor that uses `forkpty` via the C shim (`CPTYShim`) to spawn an interactive zsh login shell. Output goes to a `RingBuffer` for session resume scrollback (zero-copy writes via `withUnsafeMutableBytes`). Sessions never expire by default (`detachTimeout=0`).

**Two-phase init**: `PTYSession.init()` creates the PTY but does not start reading. Call `startReading()` after init to activate the dispatch source (required for Swift 6 actor-initializer isolation).

**The master FD is `FD_CLOEXEC`, and that is load-bearing.** `forkpty` closes the
master in the child *it* forks, so a session's own shell is never the problem —
the masters at risk are the ones already in the server's fd table when a *later*
session forks. `fork` copies the table verbatim, so without this flag every one
of them survives the `execv("/usr/bin/login", …)`, and session N's shell holds
N−1 masters. Both halves of the resulting bug trace to that single flag:

- **PTY exhaustion.** Closing our master doesn't free the kernel pty pair while
  another session's shell still references it. `ptmx` is a fixed pool
  (`kern.tty.ptmx_max`, 511), so a long-lived server that churns sessions
  eventually can't fork one at all.
- **Process leak.** A shell on a leaked pty never sees its master close, so it
  never gets EOF/SIGHUP and never exits — it outlives the server that spawned it
  and reparents to launchd. Measured before the fix: 38 stray `login -fp`
  processes, 28 already owned by pid 1 from earlier server restarts.

`terminate()`'s SIGTERM→SIGKILL is *not* a backstop for this. Those signals go to
this session's `login` child, whose own pty is fine; the wedged processes are
other sessions' shells holding this master. (It has its own, separate group bug —
see **`terminate()` signals the process group** below. The two compose, and each
had to be fixed on its own; `FD_CLOEXEC` alone did not stop the exhaustion.) Set on the parent's copy after the
fork, next to the `O_NONBLOCK` call — note `F_SETFD` (descriptor flag) is a
different command from `F_SETFL` (file-status flag); don't merge the two
read-modify-writes. Guarded by `PTYMasterFDInheritanceTests`, whose probe child
must be spawned by a bare `posix_spawn`: `Foundation.Process` sets
`POSIX_SPAWN_CLOEXEC_DEFAULT` and inherits nothing regardless of the flag, so a
`Process`-based probe passes against the unfixed code.

**`terminate()` sweeps the child's terminal SESSION, and the widening from `pid` to
group to session was three separate fixes.** `forkpty` calls `setsid()` in the
child, so the child leads a new session *and* its own process group (pgid == pid).
Each survivor of an incomplete reap holds the resources of a session the server
believes it already reclaimed, and they accumulate for the life of the server.

The reap target widened by exactly one level three times, and each step felt like
the complete fix:

1. **pid → group.** SIGTERM and the SIGKILL escalation were both single-pid, so
   they reached only the process at the top; measured, a grandchild outlived both
   and reparented to launchd.
2. **The escalation was gated on the *leader's* liveness** (`kill(pid, 0)`), which
   is false in the exact case the backstop exists for: `login`/`zsh` exits promptly
   on SIGTERM while the agent lingers. So the guard concluded "already dead" and
   returned. It is now `killpg(pid, 0) == 0 || !survivors.isEmpty`.
3. **group → session** (shipped 0.3.21). Fixes 1–2 shipped as 0.3.20 and *still
   leaked*, because an interactive `zsh` runs **job control**: every job it starts
   gets its OWN pgid via `setpgid`, so the leader's group holds `login` and nothing
   else. Measured on the live 0.3.20 server: session 26119 had **13 members across
   5 process groups**, and `killpg(26119)` reached exactly 1. The session is the
   boundary that actually means "everything this PTY started" — job control
   fragments groups freely, but nothing leaves the session without calling
   `setsid()` itself.

`pid ⊂ process group ⊂ session` is the distinction to keep in mind; a
group-liveness check is the *narrower* question, which is why the escalation guard
now consults the session too. The group signal stays as the floor: the sweep needs
a sysctl enumeration that can fail, so a failed sweep degrades to 0.3.20 behaviour
rather than to signalling nothing.

The sweep is `relay_get_session_members` (KERN_PROC_ALL + `getsid()`, *not* the
KERN_PROC_SESSION filter — that returns ENOENT on macOS 15 for a session that
exists). Two guards matter, and both trace to a real defect: `sessionMembers`
refuses `sessionID == getsid(0)`, and `childSessionID` is `childPID` **by
construction rather than read back**. `getsid(childPID)` from the parent is a race
that loses essentially always — `forkpty` returns before the child runs `setsid()`,
so it reports *the parent's* session (measured 8/8), and an earlier draft stored
exactly that and SIGKILLed the test runner. POSIX guarantees the child's sid equals
its pid, so there is nothing to read.

Neither signal can hit the server, and for the same reason in both cases — the
`setsid()` means the child's group and session are its own. The pid-recycle
start-time check is skipped once the leader is gone: pid reuse transfers neither
group nor session leadership.

The reap lives in `PTYSessionReap.swift` as `static` functions taking their targets
as parameters, so tests exercise production code. They must drive it against a
**stand-in** group: nothing outside the child's session can join the real one
(`setpgid` / `POSIX_SPAWN_SETPGROUP` across sessions is EPERM by design), and
driving the session's own shell doesn't work either because under a test harness
`login -fp` echoes commands without running them — so a shell-driven test can only
skip, i.e. silently pass the bug it exists to catch. `_testOnly_reap` therefore
defaults `sessionID` to -1 (group path in isolation), and
`_testOnly_sessionMembers` exposes the enumeration alone so the fragmented-group
case can be asserted without signalling anything. A leak probe that never starts a
background job passes against the *buggy* code — no fragmented groups ever exist —
so the multi-pgid tree is modelled directly (fork + setsid + setpgid). Guarded by
`PTYTerminateProcessGroupTests`.

**A process in `U` state cannot be reaped at all.** Two leaked `login` processes on
the dev machine survived `SIGKILL` to their group and showed `Us+` — uninterruptible
kernel wait. Nothing in userspace can clear those; their ptys are pinned until
reboot. This is why the fix must prevent the leak rather than rely on any sweep, and
why "hard reset was required" is consistent with a correct group kill.

**Residual gap the session sweep cannot close (known, accepted):** a child that
calls `setsid()` itself leaves the session and survives any sweep — Claude Code's
own Bash tool does exactly this. Reaping those would need ancestry-walking, which
races pid reuse. So "no leaks" means *no leaks via group or session*, not zero
strays.

**Non-blocking writes**: The master FD is set to `O_NONBLOCK`. A `DispatchSourceWrite` drains a 4 MB pending queue when the FD becomes writable. Overflow drops oldest bytes with a once-per-session warning. This prevents paste/rapid-input workloads from EAGAIN-spinning inside the actor and starving resize/output dispatch.

**Output backpressure**: `RelayMessageHandler` caps inflight WebSocket-write bytes per session at 2 MB (`maxInflightOutputBytes`). When the cap is hit the server skips frames until writes drain — the `RingBuffer` holds the authoritative copy and clients replay from it on resume.

**Per-token session cap**: `SessionManager.createSession` enforces `config.maxSessionsPerToken` (default 50, 0 = unlimited) and throws `SessionError.sessionLimitExceeded` when exceeded. Prevents runaway clients from fork-bombing the server.

**fd liveness is tracked outside actor isolation, and only reads whose result is
believed take the lock.** The master fd is closed by the read source's *cancel
handler*, which runs on a dispatch queue, not on the actor — so actor state
(`terminated`) cannot be the authority on whether the fd is still ours.
`PTYSession.fdClosed` is an `OSAllocatedUnfairLock<Bool>` for exactly that reason:
the cancel handler marks it before closing, and copies of the lock share one
allocation, so the handler's captured copy is the same state the actor reads.

This is deliberately **not** a file-wide "always lock the fd" rule, and reading it
as one has already produced a false comment. No other fd use takes the lock; their
failure mode on a stale fd is a discarded errno, or at worst a resize delivered to a
PTY that is no longer ours — never a plausible-looking wrong answer handed back to a
caller. What they check instead is **not** uniform, and summarising it as "they check
`terminated`" is the false comment in question:

- `relay_set_winsize` in `resize()`/`forceRepaint()`, and the entry to `write(_:)`,
  do check `terminated`.
- `drainWriteQueue()` does not, and can't delegate to its caller — the write source's
  event handler calls it directly, so it bypasses `write(_:)`'s guard entirely.
- the read source's `read(fd, …)` has no check available: the event handler isn't
  actor-isolated, so reading `terminated` would mean an `await` in the hot read path.
  Ordering comes from the source instead — the `cancel()` that stops the handler is
  what runs the cancel handler that closes the fd.

`TIOCGWINSZ` is the exception that needs the lock: it *returns data the caller
trusts*, and a recycled fd number would yield another session's real dimensions, so
`_testOnly_kernelWindowSize()` performs the closed-check and the ioctl in one
critical section. Splitting them would be a check-then-act race against the cancel
handler. `os_unfair_lock` is not recursive — never re-enter it from a `withLock`
body.

The lock is only observable because `_testOnly_markMasterFDClosed()` exists to reach
it; the real close can't be scheduled from a test. Deleting the guard left the whole
suite green before that, and `WindowSizeFailure` distinguishes `.fdClosed` from
`.ioctlFailed` so the assertion can tell the guard firing from an ioctl that merely
failed. That hook **marks the flag without closing the fd** — the `DispatchSourceRead`
still owns the descriptor until its cancel handler runs, so a real `close()` there
would double-close a number the process may have recycled. It also sharpens the test:
with the fd open, an unguarded read *succeeds* and returns the live size, which is the
production hazard (a recycled fd answering for another session) made deterministic.

**Don't walk a path tree by `deletingLastPathComponent()` until it reaches a fixed
point.** Foundation doesn't document that one exists, and whether it does depends on
the Foundation in play: on GitHub's `macos-15` runner `"/"` mapped to `"/.."`, then
`"/../.."`, so a `parent == current` guard never fired and `GitRootResolver` spun a
filesystem probe per iteration — a hung `swift test` with no failing test named, for
a month. Enumerate ancestors by dropping components off the path *string*
(`GitRootResolver.ancestorPaths`), which is finite by construction, and split
Unicode **scalars** rather than `Character`s so a component starting with a
combining mark can't fuse onto the preceding `/` and drop an ancestor level.

## Terminal Queries Are Answered Here, Not By The Device

A terminal *query* in the PTY stream (`ESC ] 11 ; ? BEL` background colour,
`ESC [ 6 n` cursor position, DA/DECRQM/XTGETTCAP/XTWINOPS reports) must never
reach a client. Across the relay the answer costs a WebSocket round trip, so it
arrives after the asking program stopped reading — the shell's line editor then
takes it as keystrokes and echoes the payload at the prompt. The reported
symptom was a literal `11;rgb:0000/0000/0000` sitting unexecuted at a bash
prompt; the all-zero colour is the fingerprint of our own client, whose
`nativeBackgroundColor` is forced to black.

`handleOutput` therefore does two things at that seam, and both halves are
required:

- **Answer locally.** `TerminalScreenModel.feed` now *returns* whatever the
  emulator wants to send upstream, and `handleOutput` writes it back to the PTY.
  Zero latency, and because both ends run the same SwiftTerm it is byte-identical
  to the answer the device would have given. This is the tmux/mosh model. It also
  fixes **detached** sessions, whose queries previously rotted in the ring buffer
  until some client reattached and answered them. `feed` is deliberately not
  `@discardableResult` — silently dropping these answers is the defect.
- **Strip from both client-bound copies.** `TerminalQueryFilter.strip` runs over
  the bytes that go to `ringBuffer.write` *and* `outputHandler`, so neither the
  live forward nor a later replay can provoke a late answer. Detection
  (`screenModel`, `activityMonitor`) and `osc52Parser` keep the raw stream —
  stripping before the emulator would leave the query unanswered by anyone.

Only sequences that are unambiguously queries *and* render nothing are stripped;
commands sharing a final byte (SCORC `CSI u`, DECSTR `CSI !p`, title-stack
`CSI 22t`) pass through byte-exact. Two accepted residuals: the filter is
stateless, so a query split across two PTY reads reaches the device (pre-fix
behaviour, never worse), and a truncated tail at the end of a chunk is forwarded
rather than held back — withholding it would stall the render.

`EscapeResponseFilter` (which strips stale *replies* out of a replay) is the same
root cause treated at the symptom, from the other end. It stays as defence in
depth for ring buffers recorded before this fix.

## Server-Side Activity Monitoring

The server monitors all PTY output continuously (even for detached sessions) via `SessionActivityMonitor`. It detects coding agent entry/exit and output silence, maintaining an `ActivityState` per session. Agents are identified via the `CodingAgent` registry (process-name matching + OSC title keywords); currently ships with Claude Code, Codex, opencode, Copilot CLI, Cursor Agent, and Droid (see `CodingAgent.all`, each with a bundled manifest under `Sources/ClaudeRelayServer/Resources/Agents/`). State changes are pushed to clients via `sessionActivity` WebSocket messages. This ensures background tabs correctly reflect agent running/idle state even when the client is attached to a different session.

**Performance**: The foreground-process poll runs at 1 s for an attached session (`PTYSession.attachedPollCadence`) and 5 s once detached (`detachedPollCadence`). ANSI regex processing is skipped on the hot output path when no agent is running, and `CodingAgent.processNames` is pre-lowercased at init so polling doesn't re-allocate strings on every tick.

`SessionManager` switches cadence in exactly three places — `attachSession` and `resumeSession` restore the fast poll (both land in `.activeAttached`), `detachSession` slows it. None of them writes the PTY directly; all three call `syncPollCadence(id:)`. Three non-obvious constraints hold there:

- **`resumeSession` must restore it too.** Same-device tab switches detach-then-resume, so without this a switched-to session stayed at 5 s. That made it the common path, not an edge case. Covered by `testResumeRestoresAttachedPollCadence`.
- **The value is re-read from committed state after every suspension, never captured by the caller.** This is the load-bearing part. `setPollCadence` is a cross-actor call, so it suspends, and `SessionManager` is reentrant at every `await`: a caller that captured its cadence *before* suspending can land a stale value after another transition has already committed — a detach's 5 s overwriting a resume's 1 s, i.e. this very bug one level down. Ordering the statements cannot fix it, because the race is between the two PTY writes, not the two methods. `syncPollCadence` instead loops, re-deriving the cadence from `sessions[id].info.state` after each write and exiting only once the PTY already holds what committed state implies. The exit condition is **state agreement, never a pass count** — an earlier version capped the loop at 8 passes and reintroduced the bug at the boundary: a transition committing during the eighth write returned early on the single-flight guard, then the owner finished its stale write and exhausted the loop without re-reading, leaving nothing to repair it. `testSyncLoopTakesAsManyPassesAsThereAreTransitions` guards the removal by forcing more passes than that cap allowed (the gated reentrancy test drives only two, so it cannot distinguish `while true` from any cap >= 2). Termination doesn't need the cap: a further pass only happens when another task committed a *different* state while this one was suspended, so the loop stops one pass after lifecycle transitions quiesce. (Not because transitions are inherently finite — sustained detach/resume flapping could keep the owner looping — but each pass suspends on the PTY actor rather than spinning, and overtaking callers return on the guard instead of accumulating.) Writes are single-flight per session: that serialises them and gives one owner responsibility for reaching agreement (so `lastWritten` is also the PTY's current value, making the comparison sound), but it is not what fixes the race — delete the guard and the tests still pass. A caller that finds a loop in flight writes nothing, which is safe only because it commits its state *before* calling and the owner re-reads after every write.
- **`detachSession` installs its detach-expiry timer above that suspension point.** Otherwise a reentrant `resumeSession` cancels a not-yet-installed timer, and the detach then arms one against a session that is once again `.activeAttached`. `testDetachTimerIsInstalledBeforeCadenceSuspension` pins `detachSession` at the suspension point with a gated mock PTY to make the interleaving deterministic, and asserts both the surviving cadence and the absence of the timer.

Relatedly, `attachSession` cancels any live detach-expiry timer (as `resumeSession` already did), and `handleDetachTimeout` drops its `detachTimers` entry unconditionally at the top: a fired timer is spent whether or not the session is still expirable, and both of its early returns used to leave the entry behind.

**Hook-based state authority (F6)**: An optional local Claude Code hook can report authoritative lifecycle state, overriding screen detection while fresh. `PTYSession` injects `CLAUDE_RELAY_SESSION_ID` + `CLAUDE_RELAY_ADMIN_PORT` into each session's shell env (admin port threaded through the default `PTYFactory` closure; the `PTYFactory` typealias is unchanged so test mocks are unaffected). The shipped hook (`Scripts/hooks/claude-relay-state-hook.sh`) POSTs `{sessionId, state}` to the localhost-only `POST /hook/state` admin route → `SessionManager.reportHookState` → `SessionActivityMonitor.applyHookState`. Hook state is trusted for a 10 s TTL (`hookStateTTL`); `updateScreenDetection` no-ops while a fresh hook state exists, then screen detection resumes automatically when it goes stale. The hook reports **state only** — agent *identity* stays owned by the foreground poll, so a hook can never assert or evict an agent. With no hook installed, behavior is identical to screen-detection-only. Install docs: `Scripts/hooks/README.md`.

