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
other sessions' shells holding this master. Set on the parent's copy after the
fork, next to the `O_NONBLOCK` call — note `F_SETFD` (descriptor flag) is a
different command from `F_SETFL` (file-status flag); don't merge the two
read-modify-writes. Guarded by `PTYMasterFDInheritanceTests`, whose probe child
must be spawned by a bare `posix_spawn`: `Foundation.Process` sets
`POSIX_SPAWN_CLOEXEC_DEFAULT` and inherits nothing regardless of the flag, so a
`Process`-based probe passes against the unfixed code.

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

## Server-Side Activity Monitoring

The server monitors all PTY output continuously (even for detached sessions) via `SessionActivityMonitor`. It detects coding agent entry/exit and output silence, maintaining an `ActivityState` per session. Agents are identified via the `CodingAgent` registry (process-name matching + OSC title keywords); currently ships with Claude Code, Codex, opencode, Copilot CLI, Cursor Agent, and Droid (see `CodingAgent.all`, each with a bundled manifest under `Sources/ClaudeRelayServer/Resources/Agents/`). State changes are pushed to clients via `sessionActivity` WebSocket messages. This ensures background tabs correctly reflect agent running/idle state even when the client is attached to a different session.

**Performance**: The foreground-process poll runs at 1 s for an attached session (`PTYSession.attachedPollCadence`) and 5 s once detached (`detachedPollCadence`). ANSI regex processing is skipped on the hot output path when no agent is running, and `CodingAgent.processNames` is pre-lowercased at init so polling doesn't re-allocate strings on every tick.

`SessionManager` switches cadence in exactly three places — `attachSession` and `resumeSession` restore the fast poll (both land in `.activeAttached`), `detachSession` slows it. None of them writes the PTY directly; all three call `syncPollCadence(id:)`. Three non-obvious constraints hold there:

- **`resumeSession` must restore it too.** Same-device tab switches detach-then-resume, so without this a switched-to session stayed at 5 s. That made it the common path, not an edge case. Covered by `testResumeRestoresAttachedPollCadence`.
- **The value is re-read from committed state after every suspension, never captured by the caller.** This is the load-bearing part. `setPollCadence` is a cross-actor call, so it suspends, and `SessionManager` is reentrant at every `await`: a caller that captured its cadence *before* suspending can land a stale value after another transition has already committed — a detach's 5 s overwriting a resume's 1 s, i.e. this very bug one level down. Ordering the statements cannot fix it, because the race is between the two PTY writes, not the two methods. `syncPollCadence` instead loops, re-deriving the cadence from `sessions[id].info.state` after each write and exiting only once the PTY already holds what committed state implies. The exit condition is **state agreement, never a pass count** — an earlier version capped the loop at 8 passes and reintroduced the bug at the boundary: a transition committing during the eighth write returned early on the single-flight guard, then the owner finished its stale write and exhausted the loop without re-reading, leaving nothing to repair it. `testSyncLoopTakesAsManyPassesAsThereAreTransitions` guards the removal by forcing more passes than that cap allowed (the gated reentrancy test drives only two, so it cannot distinguish `while true` from any cap >= 2). Termination doesn't need the cap: a further pass only happens when another task committed a *different* state while this one was suspended, so the loop stops one pass after lifecycle transitions quiesce. (Not because transitions are inherently finite — sustained detach/resume flapping could keep the owner looping — but each pass suspends on the PTY actor rather than spinning, and overtaking callers return on the guard instead of accumulating.) Writes are single-flight per session: that serialises them and gives one owner responsibility for reaching agreement (so `lastWritten` is also the PTY's current value, making the comparison sound), but it is not what fixes the race — delete the guard and the tests still pass. A caller that finds a loop in flight writes nothing, which is safe only because it commits its state *before* calling and the owner re-reads after every write.
- **`detachSession` installs its detach-expiry timer above that suspension point.** Otherwise a reentrant `resumeSession` cancels a not-yet-installed timer, and the detach then arms one against a session that is once again `.activeAttached`. `testDetachTimerIsInstalledBeforeCadenceSuspension` pins `detachSession` at the suspension point with a gated mock PTY to make the interleaving deterministic, and asserts both the surviving cadence and the absence of the timer.

Relatedly, `attachSession` cancels any live detach-expiry timer (as `resumeSession` already did), and `handleDetachTimeout` drops its `detachTimers` entry unconditionally at the top: a fired timer is spent whether or not the session is still expirable, and both of its early returns used to leave the entry behind.

**Hook-based state authority (F6)**: An optional local Claude Code hook can report authoritative lifecycle state, overriding screen detection while fresh. `PTYSession` injects `CLAUDE_RELAY_SESSION_ID` + `CLAUDE_RELAY_ADMIN_PORT` into each session's shell env (admin port threaded through the default `PTYFactory` closure; the `PTYFactory` typealias is unchanged so test mocks are unaffected). The shipped hook (`Scripts/hooks/claude-relay-state-hook.sh`) POSTs `{sessionId, state}` to the localhost-only `POST /hook/state` admin route → `SessionManager.reportHookState` → `SessionActivityMonitor.applyHookState`. Hook state is trusted for a 10 s TTL (`hookStateTTL`); `updateScreenDetection` no-ops while a fresh hook state exists, then screen detection resumes automatically when it goes stale. The hook reports **state only** — agent *identity* stays owned by the foreground poll, so a hook can never assert or evict an agent. With no hook installed, behavior is identical to screen-detection-only. Install docs: `Scripts/hooks/README.md`.

