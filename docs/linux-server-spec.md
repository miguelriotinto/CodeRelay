# ClaudeRelay Linux Server — Specification & Implementation Plan

**Target platform:** Arch Linux / Omarchy (systemd user session, Hyprland/Wayland desktop; any systemd Linux for the service)
**Parity target:** the macOS server and CLI (`ClaudeRelayServer` + `ClaudeRelayCLI`), feature for feature
**Status:** implemented — server, CLI, service management, packaging and tests complete on this host; see §12
**Date:** 2026-09-04

---

## 1. Goal and scope

Make the CodeRelay **server** — the WebSocket relay, the admin HTTP API, PTY session
management, device pairing, push dispatch, and the `claude-relay` CLI that manages it —
run as a first-class background service on a Linux host, so an Omarchy box can be the
machine a phone, a Mac, or the Linux client connects *to*.

**Parity is defined against the macOS server, not the Linux client.** The Linux client
(`docs/linux-client-spec.md`) is a consumer of this server and is untouched. "Parity"
means: the same wire protocol byte for byte, the same admin API, the same config file
and keys, the same CLI commands with the same output, the same session semantics
(detach/reattach, scrollback replay, agent detection, hook-reported state, OSC 52
clipboard, per-token caps, rate limiting), and the same test suite passing.

### 1.1 Non-goals

- **The Apple client libraries.** `ClaudeRelayClient` (SwiftUI/UIKit/AppKit/IOKit) and
  `ClaudeRelaySpeech` (WhisperKit/CoreML) are not ported; they are excluded from the
  Linux build (AD-1). The Linux client already exists in Kotlin.
- **A new push provider.** APNs and FCM are HTTP/2 clients over `AsyncHTTPClient` and
  `Crypto`; they build and run unchanged on Linux. No Linux-specific push transport is
  added — the Linux client deliberately has none (client spec AD-4).
- **Relocating `~/.claude-relay` to XDG paths.** The config directory, `config.json`,
  `tokens.json`, and the hook script path are shared knowledge across three clients'
  documentation and the state-hook script. Same path on both platforms.
- **Replacing Homebrew.** The macOS distribution is unchanged. Linux gets its own
  packaging (§10).
- **Windows.** Nothing here targets it.

---

## 2. Architecture decisions

### AD-1 — Same package, platform-conditional manifest

The server is ported in place, not forked. Measured before any change was made:

| Target | Files | Lines | Apple-only imports |
|---|---|---|---|
| `CPTYShim` (C) | 2 | 343 | sysctl, libproc, `util.h` |
| `ClaudeRelayKit` | 19 | 1,648 | `Security` ×2 |
| `ClaudeRelayServer` | 36 | 7,657 | `os` ×3, `AppKit` ×1 |
| `ClaudeRelayCLI` | 15 | 2,522 | `CoreImage` ×1 |

Ten Apple-only imports in 12,170 lines; everything else is Foundation, NIO, Crypto,
AsyncHTTPClient, ArgumentParser and SwiftTerm — all of which support Linux (SwiftTerm's
own manifest excludes its `Apple/`, `Mac/`, `iOS/` sources under `os(Linux)`).

`Package.swift` is Swift, so it branches: under `os(Linux)` the two Apple client
libraries, their two dependencies (WhisperKit, LLM.swift), and their test targets are
not declared. The manifest runs on the *host*, so "Linux" here means "building on
Linux" — the same reasoning SwiftTerm documents.

Rejected alternatives:
- *A separate `ClaudeRelayLinux/server` package.* Two copies of 12 k lines to keep
  honest, for ten imports.
- *A rewrite (Go, Rust, Kotlin).* The protocol subtleties this codebase encodes —
  fire-and-forget replies, replay ordering, the reap-by-session invariant, the
  double-checked rate-limit gate — are exactly what a rewrite loses.

**Consequence to accept — `Package.resolved`.** Resolving on Linux drops the pins for
`whisperkit`, `llm.swift`, and their transitive `swift-syntax`. The committed file is
the macOS superset and must stay that way: a Linux checkout must not commit a rewritten
`Package.resolved`. §11 makes CI insensitive to this.

### AD-2 — One shim header, two implementations

`pty_shim.h` is unchanged. Darwin's implementations (sysctl `KERN_PROCARGS2`,
`KERN_PROC`, libproc `PROC_PIDVNODEPATHINFO`) stay in `pty_shim.c` behind
`__APPLE__`; `pty_shim_linux.c` implements the same nine functions from `/proc`.
The Swift callers do not know which they got.

| Function | Darwin | Linux |
|---|---|---|
| `relay_forkpty` | `<util.h>` | `<pty.h>`, `-lutil` |
| `relay_get_process_name` | exec path from `KERN_PROCARGS2` | `readlink /proc/<pid>/exe`, then `cmdline[0]` (login `-` stripped), then `comm` |
| `relay_get_process_script_name` | `argv[1]` from `KERN_PROCARGS2` | `/proc/<pid>/cmdline` field 1 |
| `relay_get_parent_pid` | `kinfo_proc.e_ppid` | `/proc/<pid>/stat` field 4 |
| `relay_get_session_members` | `KERN_PROC_ALL` + `getsid()` | `/proc` scan + `getsid()` |
| `relay_get_process_start_time` | `p_starttime` (µs) | `stat` field 22 × 10⁶/`CLK_TCK` |
| `relay_proc_cwd` | `proc_pidinfo` | `readlink /proc/<pid>/cwd` |
| `relay_proc_cwd_descendant` | libproc child walk | `/proc` child walk, depth 4 |

Two semantics were checked rather than assumed:
- **Process name.** Agent matching (`CodingAgent.matchesProcessName`) is *equals or
  `<name>-`/`<name>.` prefix* on the executable basename. `/proc/<pid>/exe` is the
  exec'd binary, like the Darwin exec-path string; a login shell reads `bash`, not
  `-bash`. The kernel's ` (deleted)` suffix (binary replaced on disk mid-run) is
  stripped so an upgrade cannot break detection.
- **Start time** feeds only an equality check for PID reuse (C-10). Ticks-since-boot
  scaled to microseconds is stable per process and distinct per reuse, which is all
  the caller needs; nothing derives wall-clock time from it.

The reap invariant (`pid ⊂ group ⊂ session`, `PTYSessionReap.swift`) holds unchanged:
`forkpty` calls `setsid()` on Linux too, and the members are filtered by `getsid(2)`.
`POSIX_SPAWN_SETSID`, which the reap tests need, is exposed as
`relay_posix_spawn_setsid_flag()` because glibc hides the macro behind `_GNU_SOURCE`
and its value differs from Darwin's.

### AD-3 — The session shell: no `login(1)`

macOS spawns `login -fp <user>`, a setuid binary that establishes the login context
and picks the account shell, with `-zsh` as a fallback. `login -f` requires root on
Linux, and a systemd user service has none.

Linux execs the account's own shell directly and reproduces what `login -fp` gave it:

- `argv[0] = "-<basename>"` — the login-shell marker, so `/etc/profile` and the
  user's profile run and `PATH` ends up as it would in a terminal (mise shims,
  `~/.local/bin`, …). This is what puts `claude` on the session's `PATH`.
- `HOME`, `USER`, `LOGNAME`, `SHELL` set explicitly; `TERM=xterm-256color` as before.
- The server's environment is *preserved* (that is `-p`), not replaced. macOS pins
  `PATH` to a Homebrew list and `LANG=en_US.UTF-8`; Linux has no Homebrew prefix and a
  forced `en_US.UTF-8` on a box that has not generated it makes every `setlocale()`
  warn — so only a *missing* `LANG` is defaulted, to `C.UTF-8`, and only a missing
  `PATH` to `/usr/local/bin:/usr/bin:/bin`.
- The shell is resolved **before fork** (`LoginShell.resolve()`), because `getpwuid`
  may allocate and consult NSS, neither of which is safe between fork and exec. The
  child sees only C strings. Fallback order — passwd shell, `$SHELL`, bash, sh — skips
  `nologin`/`false` and anything not executable; `LoginShell.choose` is pure and
  unit-tested.

Consequence: the cwd walk exists on Darwin because setuid `login` hides its cwd from
`proc_pidinfo`. On Linux `childPID` *is* the shell and `readlink /proc/<pid>/cwd`
succeeds first time; the descendant walk is kept for the contract and is never entered
on the happy path.

### AD-4 — Service management: one systemd user unit, one name

`launchd` ↔ `systemd --user`. The unit is `claude-relay.service`, whichever way it was
installed:

| Origin | Unit path | macOS analogue |
|---|---|---|
| Package (`clauderelay-bin` PKGBUILD) | `/usr/lib/systemd/user/claude-relay.service` | Homebrew's `homebrew.mxcl.clauderelay` |
| `claude-relay load` (from-source) | `~/.config/systemd/user/claude-relay.service` | `com.claude.relay` LaunchAgent |

The macOS "two managers both bind the port" hazard that `ServiceManagerDetector`
exists for **does not exist on Linux**: systemd's unit search path makes a
`~/.config/systemd/user/` unit *shadow* a same-named `/usr/lib/systemd/user/` one, so
at most one definition is ever active. `load` on a packaged install therefore does not
write a second unit — it enables the packaged one. `SystemdUnitDetector` still reports
which file is in effect (via `systemctl --user show -p FragmentPath`) so `status` can
say "Managed by: systemd (packaged unit)" and `unload` can refuse to delete a file it
did not write.

| launchd key | systemd directive |
|---|---|
| `KeepAlive` | `Restart=always`, `RestartSec=5` |
| `RunAtLoad` | `[Install] WantedBy=default.target` + `systemctl --user enable --now` |
| `StandardOutPath` / `StandardErrorPath` | journald (`journalctl --user -u claude-relay`) |
| `EnvironmentVariables` `HOME`/`USER`/`PATH` | inherited from the user manager; `PATH` is not pinned |
| `WorkingDirectory` | `WorkingDirectory=%h` |

`claude-relay logs show` is unaffected: it reads the in-memory `LogStore` over the
admin API, not the log files.

Lifetime matches macOS: a user unit starts when the user's systemd instance does (first
login) and stops at logout, exactly as a LaunchAgent does. `loginctl enable-linger` is
the documented opt-in for a headless host that must serve with nobody logged in; the
CLI mentions it in `load`'s output but does not run it (it is a policy change and needs
polkit).

### AD-5 — Clipboard: `wl-copy` / `xclip` on stdin

Device → host image paste (`paste_image`) writes to the compositor's CLIPBOARD
selection through `wl-copy --type image/png` under Wayland, `xclip -selection
clipboard -t image/png` under X11. Bytes go on **stdin** (never argv —
`/proc/<pid>/cmdline` is world-readable), the same rule the Linux client's
`DesktopClipboard` follows.

A systemd user service does not have a terminal's environment. `WAYLAND_DISPLAY` is
present only if the session imported it into the user manager (uwsm and Omarchy's
Hyprland session do); when it is absent the service probes
`$XDG_RUNTIME_DIR/wayland-{1,0}` so paste works without hand-editing the unit. No tool
or no display → `pasteImage` returns `false`, which the device sees as
`paste_image_result{success:false}` — the same signal a failed `NSPasteboard` write
gives. The command runner is an injected seam; the policy is unit-tested without a
compositor.

Host → device (OSC 52, F11) is pure stream parsing in `PTYSession` and needs nothing.

### AD-6 — Terminal QR: pure-Swift encoder on Linux, CoreImage border reproduced

`claude-relay setup` renders the pairing QR with CoreImage on macOS, chosen because it
"adds no SPM dependency". Linux has no CoreImage. It links
[`swift-qrcode-generator`](https://github.com/fwcd/swift-qrcode-generator) (Nayuki's
encoder in pure Swift, MIT) — declared in the manifest unconditionally so the pin set is
identical on both hosts, linked into the CLI **only** on Linux. macOS is unchanged.

`CIQRCodeGenerator` emits the symbol with a 1-module light border that the shipped Mac
output — and `TerminalQRRendererTests` — include. The Linux path adds the same border,
so the matrix geometry (version 5 → 37 + 2 + 2×`quietZone`) and hence the printed code
are identical on both platforms and one test file covers both. Verified: the six
renderer tests pass unmodified on Linux.

### AD-7 — Logging: stderr *is* the system sink

`RelayLogger` wrote to `os.Logger`, stderr, and the in-memory `LogStore`. On Linux the
stderr of a systemd service is journald, which is the `log stream` equivalent — a second
backend (swift-log to journald) would duplicate every line. `RelayLogLevel` replaces
`OSLogType` in the public signature with the same four case names so all 49 call sites
are untouched; the `os.Logger` sink is kept under `canImport(os)`.

### AD-8 — Integration tests: a NIO WebSocket client

Twelve of the server's 433 tests drive a real `WebSocketServer` through
`ClaudeRelayClient` (`RelayConnection`, `SessionController`,
`SharedSessionCoordinator`), which cannot build on Linux (AD-1). Those three files are
excluded from the Linux test target and the same twelve scenarios are re-expressed
against a small `TestWebSocketClient` built on `NIOWebSocket`'s client upgrader, which
compiles on both platforms. The originals stay on macOS untouched — the macOS runner is
not available here, and rewriting passing tests one cannot run is how parity claims go
wrong.

### AD-9 — Host address: `getifaddrs`, `hostname`, Avahi

`HostAddressProbe` shells out to `scutil` and `ipconfig getifaddr en0`. Linux reads
the same facts from `getifaddrs(3)` (first non-loopback IPv4, RFC1918/link-local
preferred), `gethostname(3)`, and treats `<hostname>.local` as a `.bonjour` candidate
only when `avahi-daemon` is answering (its D-Bus name or `/run/avahi-daemon/pid`), since
a `.local` name nobody serves is worse than a stale DHCP literal. The selection policy
(`HostAddressResolver.choose`) and its tests are pure and unchanged.

---

## 3. Platform seam inventory

Every macOS-coupled surface in the server and CLI, with its Linux replacement. These
are the contracts the Linux code satisfies; the shared code calls them by these names.

| macOS | Linux | Where |
|---|---|---|
| `forkpty` from `<util.h>` | `<pty.h>` + `-lutil` | `pty_shim.c`, `Package.swift` |
| sysctl/libproc process helpers | `/proc` readers | `pty_shim_linux.c` (AD-2) |
| `login -fp <user>` → zsh | `LoginShell` → exec account shell as `-<shell>` | `PTYSession.init`, `LoginShell.swift` (AD-3) |
| `OSAllocatedUnfairLock` | `NIOLockedValueBox` (both platforms) | `PTYSession.fdClosed` |
| `[weak source]` on `DispatchSourceRead` (@objc, class-bound) | weak capture of the concrete `DispatchSource` | `PTYSession.makeReadSource` |
| `os.Logger` + `OSLogType` | `RelayLogLevel`; `os.Logger` kept under `canImport(os)` | `RelayLogger.swift` (AD-7) |
| `MacClipboardService` (`NSPasteboard`) | `LinuxClipboardService` (`wl-copy`/`xclip`) | `DefaultClipboardService.make()` (AD-5) |
| `SecRandomCopyBytes` | `SecureRandom` on `SystemRandomNumberGenerator` (both platforms) | `TokenGenerator`, `PairingCode` |
| `ByteBuffer.getData`, `Data(buffer:)` implicit | explicit `import NIOFoundationCompat` | `AdminRoutes`, `PushHTTP` |
| `CIQRCodeGenerator` | `QRCodeGenerator` (Linux-only link) | `TerminalQRRenderer` (AD-6) |
| `RelativeDateTimeFormatter` | `RelativeTime.portableAbbreviated` (same strings) | `SessionCommands` |
| launchd plist + `launchctl` | systemd user unit + `systemctl --user` | `ServiceCommands`, `SystemdService` (AD-4) |
| `ServiceManagerDetector` (Homebrew vs LaunchAgent) | `SystemdUnitDetector` (packaged vs user unit) | `ServiceCommands`, `SetupCommand` |
| `scutil` / `ipconfig getifaddr` | `getifaddrs` / `gethostname` / Avahi check | `HostAddressProbe` (AD-9) |
| `/opt/homebrew`, `/usr/local` search paths | `/usr/bin`, `/usr/share/clauderelay` | `findServerBinary`, `locateBundledScript` |
| `Bundle.module` → `.bundle` beside the binary | `Bundle.module` → `ClaudeRelay_ClaudeRelayServer.resources/` beside the binary | PKGBUILD installs it |
| `posix_spawnattr_t?` (opaque) in tests | `posix_spawnattr_t()` (struct) under `os(Linux)` | `PTYTerminateProcessGroupTests` |

### 3.1 Not a seam — runs unchanged

`WebSocketServer`, `AdminHTTPServer`, `RelayMessageHandler`, `SessionManager`,
`TokenStore`, `RateLimiter`, `PairingCodeStore`, `SessionActivityMonitor`,
`AgentStateDetector` + manifests, `TerminalScreenModel`/`TerminalQueryFilter`
(SwiftTerm headless), `OSC52Parser`, `RingBuffer`, `PushDispatcher`/`APNsClient`/
`FCMClient`/`PushHTTP`, `ConfigManager`, all of `ClaudeRelayKit`'s protocol models, and
the CLI's token/session/config/log/hook commands. Measured: after the seams above, the
Linux `swift test` runs **772 tests with 0 failures** (2 deliberate `XCTSkip`s that also
skip on macOS without local TLS certs).

---

## 4. Service management design

### 4.1 The unit

Written by `claude-relay load` to `~/.config/systemd/user/claude-relay.service`, and
shipped verbatim by the package at `/usr/lib/systemd/user/claude-relay.service`:

```ini
[Unit]
Description=CodeRelay terminal relay server
Documentation=https://github.com/miguelriotinto/CodeRelay
After=default.target

[Service]
Type=simple
ExecStart=<server binary>
WorkingDirectory=%h
Restart=always
RestartSec=5
# Sessions exec the user's login shell, which sets its own PATH; the service
# itself only needs the standard system directories.
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
```

`ExecStart` in the packaged unit is `/usr/bin/claude-relay-server`; `load` resolves the
binary with the existing fallback chain (sibling of the CLI, then `/usr/bin`,
`/usr/local/bin`, `~/.claude-relay/bin`).

### 4.2 Command mapping

| Command | macOS | Linux |
|---|---|---|
| `load` | write plist, `launchctl load` | packaged unit present → `systemctl --user enable --now claude-relay`; else write user unit, `daemon-reload`, `enable --now` |
| `unload` | `launchctl unload`, delete plist | `disable --now`; delete the user unit **only if `load` wrote it**; packaged unit → nudge to `pacman -R` |
| `start`/`stop`/`restart` | `launchctl start/stop <label>` | `systemctl --user start/stop/restart claude-relay` |
| `status` | admin API + "Managed by: Homebrew/launchd" | admin API + "Managed by: systemd (packaged unit / user unit)" |
| `health` | admin API | unchanged |
| `setup` | start via owner, else `load` | unit present → `start`; else `load` |

The nudge model survives: `start` on a machine with no unit says "run
`claude-relay setup`"; `unload` against a packaged unit says which command removes it.
`--json` output gains `"manager": "systemd-package" | "systemd-user" | "none"` in
place of the macOS `homebrew | launchAgent | both | none`.

### 4.3 What the service environment must and must not contain

- Must not pin `PATH` to a login shell's view — the session shell rebuilds it (AD-3).
- `XDG_RUNTIME_DIR` is set by the user manager; `WAYLAND_DISPLAY` may or may not be
  (AD-5 handles both).
- `HOME` is set by the user manager; `RelayConfig.configDirectory` (`~/.claude-relay`)
  resolves from it.

---

## 5. PTY and process model on Linux

Everything in `Sources/ClaudeRelayServer/CLAUDE.md` still applies. Linux-specific
facts, each verified on this host:

- `forkpty` allocates from `/dev/ptmx`; the child's `setsid()` makes it session
  leader; `getsid(child) == child` after exec. The `FD_CLOEXEC` master flag, the
  `O_NONBLOCK` master, `DispatchSourceRead`/`DispatchSourceWrite` on the master (from
  swift-corelibs-libdispatch), and the out-of-actor `fdClosed` lock behave as on macOS.
- **PID reuse.** Linux's default `pid_max` (4,194,304 on 64-bit) makes reuse in the
  2-second SIGTERM→SIGKILL window vanishingly rare; the start-time guard is still
  applied because the code path is shared.
- **Foreground process detection.** `tcgetpgrp` on the master works identically; the
  ancestor walk uses `/proc/<pid>/stat` ppid. `/proc/<pid>/exe` is unreadable
  (`EACCES`) only for processes the server cannot ptrace — another user's, or
  set-uid — which never occur inside a session the server itself spawned.
- **Working directory** for git-root rollups: `readlink /proc/<pid>/cwd` of the
  foreground process, no walk needed.
- **Hook state (F6).** `CLAUDE_RELAY_SESSION_ID`/`CLAUDE_RELAY_ADMIN_PORT` are set
  before exec exactly as on macOS; the hook script is POSIX `sh` + `curl`, both present
  on Arch by default.

---

## 6. Config, paths, and identity

Unchanged: `~/.claude-relay/config.json`, `tokens.json`, `push-registrations.json`,
`hooks/claude-relay-state-hook.sh`, every config key, every default (WS 9200, admin
9100, `bindAll=true`, `maxSessionsPerToken=50`). `NSHomeDirectory()` and
`FileManager.homeDirectoryForCurrentUser` resolve from `HOME` on Linux, which the user
manager sets.

`claude-relay --version` reports the same version string as macOS; the version constant
is shared.

---

## 7. Networking and TLS

`WebSocketServer` and `AdminHTTPServer` are pure NIO; `NIOSSL` bundles BoringSSL and
needs no system OpenSSL. `bindAll` semantics, the plaintext warning, the 64 KB admin body
cap, and the rate limiter are identical.

The CLI's `AdminClient` is `URLSession` from `FoundationNetworking` (already guarded
with `canImport(FoundationNetworking)`), which links libcurl on Linux.

Host-address selection for the pairing QR: AD-9. The ATS-derived "requires TLS" policy
(`HostAddressResolver.requiresTLS`) is about what the *Apple clients* can reach, so it
stays exactly as is on a Linux host.

---

## 8. Logging and diagnostics

| Need | macOS | Linux |
|---|---|---|
| Live service log | `log stream --predicate 'subsystem == "com.coderemote.relay"'` | `journalctl --user -u claude-relay -f` |
| Recent entries via CLI | `claude-relay logs show` | unchanged (admin API) |
| Crash | Console.app | `coredumpctl` (this host's `diagnose-crash` skill) |

---

## 9. Clipboard bridging

Both halves of F11 hold:
- **Host → device** (OSC 52): unchanged stream parsing.
- **Device → host** (`paste_image`): AD-5. Runtime dependency `wl-clipboard`
  (Wayland) or `xclip` (X11), both `optdepends` in the package because the server is
  fully functional without them — only image paste degrades, to a `success:false`
  reply.

---

## 10. Packaging and distribution

### 10.1 Build

```bash
swift build -c release --static-swift-stdlib --product claude-relay-server -Xlinker -lcurl
swift build -c release --static-swift-stdlib --product claude-relay -Xlinker -lcurl
```

`--static-swift-stdlib` links the Swift runtime and Foundation statically so the
binaries do not depend on a Swift toolchain at runtime. Remaining dynamic dependencies
are glibc, libstdc++, libgcc_s, and libcurl — all in Arch's `base`. Verified with
`ldd` in §12. `-Xlinker -lcurl` is required: FoundationNetworking's static archive
(`lib_CFURLSessionInterface.a`) calls libcurl but the static-stdlib link does not
add it, and the link fails with `undefined reference to curl_*` (seen on Swift 6.0.3;
the flag is harmless where a newer toolchain adds it itself). The link-time
`libcurl.so` symlink comes from `libcurl4-openssl-dev` on Ubuntu / `curl` on Arch.

### 10.2 Artifacts a release ships

- `claude-relay`, `claude-relay-server`
- `ClaudeRelay_ClaudeRelayServer.resources/` — the agent manifests `Bundle.module`
  resolves **next to the executable**; without it the server fatal-errors on the first
  session create (the Homebrew formula carries the same warning for `.bundle`).
- `claude-relay-state-hook.sh` (→ `/usr/share/clauderelay/`, which
  `locateBundledScript`'s `../share/clauderelay` candidate finds from `/usr/bin`).
- `claude-relay.service` (→ `/usr/lib/systemd/user/`).

Tarball: `claude-relay-v<ver>-linux-x86_64.tar.gz`, built by `release.yml` on
`ubuntu-latest` with the Swift 6 toolchain, gated on the Linux test job.

### 10.3 `clauderelay-bin` PKGBUILD

Mirrors the client's `coderelay-bin`: consumes the release tarball, `depends=('curl')`,
`optdepends=('wl-clipboard' 'xclip')`, installs the four artifacts above, and prints a
post-install note (`claude-relay setup`, `systemctl --user enable --now claude-relay`,
`loginctl enable-linger` for headless). `conflicts=('clauderelay')` reserves the name
for a future source package.

---

## 11. Testing and CI

### 11.1 Layers

1. **The macOS suite, unmodified, on Linux** — 772 tests. The primary parity gate: the
   protocol, session, PTY, reap, activity, push and CLI tests were written against the
   macOS server and must pass against the Linux one.
2. **Ported integration scenarios** (AD-8) — the 12 client-driven tests re-expressed
   over `TestWebSocketClient`: auth, redundant auth, reconnect, brute-force limiting,
   rapid session switching, self-steal, replay-complete ordering (empty and non-empty
   buffer), force-repaint wiring, and the three unattached-request-reply rules.
3. **Linux seam tests** — `ProcShimLinuxTests` (`/proc` readers against the test
   process itself and a spawned child: name, script name, ppid, session members, start
   time stability, cwd), `LoginShellTests` (fallback order, `nologin` skipped,
   `-argv0`), `LinuxClipboardServiceTests` (tool selection, Wayland socket probe,
   stdin delivery, `false` without a display), `SystemdUnitDetectorTests` (owner
   resolution and nudges, mirroring `ServiceManagerDetectorTests`), `SystemdUnitTests`
   (unit file content), `RelativeTimeTests`, `HostAddressProbeLinuxTests`
   (classification of `getifaddrs` output).
4. **End-to-end on this host** — service installed via `claude-relay load`, a token
   minted, a session created over a real WebSocket, `claude` detected as the agent,
   detach/reattach with replay, `paste_image` landing in `wl-paste --list-types`,
   `setup` printing a QR that decodes to the pairing URL.

### 11.2 CI

A `linux-server` job in `ci.yml` on `ubuntu-latest` with `swift-actions/setup-swift`:
`swift build`, `swift test`, then `git diff --exit-code Package.resolved` **is not**
run — instead the job restores the file after resolution so the AD-1 hazard cannot fail
a build, and a separate check greps that the committed pins still include `whisperkit`.
`release.yml` gains `build-linux-server`, producing the §10.2 tarball.

---

## 12. Implementation plan and ledger

| Phase | Scope | Status |
|---|---|---|
| **P0** Manifest | `Package.swift` conditional targets/deps; `Package.resolved` hazard documented | done |
| **P1** C shim | `pty_shim_linux.c`; Darwin code guarded; `-lutil`; `relay_posix_spawn_setsid_flag` | done |
| **P2** Kit | `SecureRandom`; `Security` import removed | done |
| **P3** Server compiles | `RelayLogLevel`; `NIOLockedValueBox`; weak `DispatchSource`; `LoginShell` + Linux exec path; `LinuxClipboardService` + `DefaultClipboardService`; `NIOFoundationCompat` imports | done — `claude-relay-server` builds |
| **P4** CLI compiles | `TerminalQRRenderer` Linux backend with CoreImage border; `RelativeTime` | done — `claude-relay` builds |
| **P5** Existing suite green | `posix_spawn` typing in two PTY tests; QR border | done — 772/772 |
| **P6** Service management | `ServicePlatform` seam (`SystemdService`/`LaunchdService`), `SystemdUnitDetector`, `ServiceCommands`/`SetupCommand` refactor, unit file | done |
| **P7** Host address | `HostAddressProbe` via `getifaddrs`/`gethostname`/Avahi; interface ordering | done |
| **P8** Integration test port | `TestWebSocketClient` + `WireTestServer`; 12 scenarios green | done |
| **P9** Linux seam tests | `ProcShimLinuxTests`, `LoginShellTests`, `LinuxClipboardServiceTests`, `SystemdUnitDetectorTests`, `SystemdUnitFileTests`, `RelativeTimeTests`, `HostAddressProbeLinuxTests` — 50 tests | done |
| **P10** Packaging & CI | static build (`ldd`: glibc + gcc-libs only); `packaging/claude-relay.service`; `packaging/PKGBUILD`; `linux-server` CI job + `build-linux-server` release job | done |
| **P11** Docs | `CLAUDE.md` (Linux server + seams), `README.md` (install/service), this spec | done |
| **P12** End-to-end | live server binary + real PTY (login shell) + independent WebSocket client: auth, session create, shell I/O round-trip verified on SKARNOK | done |

---

## 13. Parity matrix

Every feature the README lists for the server, and its state on Linux.

| Feature | Linux | Notes |
|---|---|---|
| WebSocket terminal relay (9200, optional TLS) | ✅ same code | NIO + NIOSSL |
| Admin HTTP API (9100, localhost-only, 64 KB cap) | ✅ same code | |
| Token auth, per-token session cap, rate limiting | ✅ same code | `SecureRandom` for token bytes |
| PTY sessions, detach/reattach, scrollback replay | ✅ | shell exec per AD-3 |
| Session reap by session id | ✅ | `/proc` + `getsid` |
| Agent detection (process chain + screen rules + hook) | ✅ | `/proc/<pid>/exe` basename |
| Terminal queries answered server-side | ✅ same code | SwiftTerm headless on Linux |
| OSC 52 host→device clipboard | ✅ same code | |
| Device→host image paste | ✅ | `wl-copy`/`xclip`; `false` without a display |
| Device pairing (`setup`, QR, `pair_request`) | ✅ | QR per AD-6 |
| Push notifications (APNs/FCM) | ✅ same code | needs the same portal setup |
| Workspace rollups (git root) | ✅ | cwd from `/proc` |
| `claude-relay` token/session/config/logs/hook commands | ✅ same code | |
| `claude-relay load/unload/start/stop/restart/status` | 🔧 P6 | systemd user unit |
| Service manager awareness | 🔧 P6 | packaged vs user unit |
| Background service at login, auto-restart | 🔧 P6 | `Restart=always`, `default.target` |
| Packaging | 🔧 P10 | `clauderelay-bin` |
| Full Disk Access caveat | n/a | no TCC on Linux |
