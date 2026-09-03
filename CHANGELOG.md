# Changelog

All notable changes to ClaudeRelay are documented in this file.

The server/CLI, iOS app, and macOS app are versioned independently. Server/CLI uses 0.x.y; iOS uses X.Y.Z; macOS starts at 0.1.0.

## [Unreleased]

### Linux client 0.2.0 — desktop parity

The Arch/Omarchy client (`ClaudeRelayLinux/`) reaches the parity scope of
`docs/linux-client-spec.md`, plus the desktop features that spec deferred.

#### Added

- **Terminal.** Local scrollback for the normal screen (bounded by the
  `terminalScrollbackLines` setting; wheel, Shift+PageUp/PageDown, a history
  marker while scrolled), text selection (drag, double-click word, triple-click
  line, Shift+drag while a program tracks the mouse) with PRIMARY and clipboard
  copy, paste from the clipboard and from PRIMARY (middle click), bracketed when
  the program enabled DECSET 2004, image paste to the host as `paste_image`,
  mouse click/drag reporting, high-resolution wheel banking, DECSCUSR cursor
  shapes and blink, a hollow cursor when the window is unfocused, OSC 52 →
  device clipboard, OSC title → window title, BEL → system beep.
- **Keyboard accelerators**, dispatched at the window: new / detach / terminate
  / next / previous / session 1–9 / sidebar / settings / zoom / copy / paste.
  `SessionCoordinator.detachActiveSession()` is new in the shared Kotlin
  session layer, mirroring the macOS "Detach Current".
- **Desktop shell.** Settings screen (Connection, General, About; the speech,
  haptics and recording-shortcut sections are hidden on desktop through a new
  `visibleSections` parameter on the shared `SettingsScreen`), auto-connect,
  `lastConnectedServerId`, tray session rollup with quick switch and actions,
  single-instance socket in `$XDG_RUNTIME_DIR` so a second `coderelay://`
  click or the "New Session" desktop action reaches the running app, desktop
  notifications fed from the coordinator's activity stream with click-to-focus
  via `notify-send --action`, pairing from a `coderelay://pair` link or a pasted
  setup line, live Omarchy theme following, terminal font size from Settings
  with Ctrl+Shift+= / - / 0, remembered window size, an app icon.
- **termlib patches** `0001-mouse-dispatch` and `0002-bracketed-paste`, ready
  to upstream.

#### Changed

- The servers list gains inset row dividers, and tab numbers, the uptime
  label, the fn toggle and key-bar glyphs no longer force
  `FontFamily.Monospace` (shared Android screens; validated by `android.yml`).
- `linux.yml` also triggers on `ClaudeRelayAndroid/feature-*` edits and
  packages the jpackage image; `release.yml` asserts the native library and
  icon are in the image and ships `coderelay.svg` in the tarball.

#### Fixed

- `DesktopNotifier` no longer runs `notify-send` on the caller's thread (the
  coordinator is confined to the AWT event thread; a waiting daemon froze it).
- The termlib patch tasks declare the files they edit as outputs, so the
  Kotlin sync after them cannot report itself up-to-date on a stale copy.

## [0.3.18] - 2026-08-03 — PTY master fd leak

### Fixed

- **PTY masters are close-on-exec, ending both the pty exhaustion and the stray
  `login` processes.** `PTYSession.init` never set `FD_CLOEXEC` on the master fd.
  `forkpty` closes the master in the child *it* forks, so a session's own shell was
  never the problem — the masters at risk are the ones already in the server's fd
  table when a *later* session forks. `fork` copies that table verbatim and
  `execv("/usr/bin/login", …)` drops only close-on-exec descriptors, so session N's
  shell held N−1 masters (measured cumulatively: 0, 1, 2, 3, 4, 5). Two symptoms
  followed from the one flag. First, closing our master does not free the kernel pty
  pair while a *sibling* session's shell still references it; `ptmx` is a fixed pool
  (`kern.tty.ptmx_max`, 511), so a long-lived server that churns sessions eventually
  cannot fork one at all. Second, a shell on a leaked pty never sees its master
  close, so it never gets EOF/SIGHUP and never exits — it outlives the server that
  spawned it and reparents to launchd. Measured on a dev machine before the fix: 84
  stray `login -fp` processes, 75 already owned by pid 1 from earlier server
  restarts, with the pool degraded far enough that `ls /dev/ttys*` hung.
  `terminate()`'s SIGTERM→SIGKILL was never a backstop for this: those signals go to
  *this* session's `login` child, whose own pty is fine, while the wedged processes
  are *other* sessions' shells holding *this* master. The flag is set on the parent's
  copy after the fork, next to the existing `O_NONBLOCK` call; `F_SETFD` (descriptor
  flag) is a different command from `F_SETFL` (file-status flag), so the two
  read-modify-writes stay separate. The guarding test's probe child must be spawned
  by a bare `posix_spawn` — `Foundation.Process` sets `POSIX_SPAWN_CLOEXEC_DEFAULT`
  and inherits nothing regardless of the flag, so a `Process`-based probe passes
  against the unfixed code. That false pass occurred during development and is
  recorded in the test's doc comment.
- **Workspace grouping can no longer wedge the foreground poll.**
  `GitRootResolver` resolves each session's cwd to its enclosing repo so sessions
  group by repo; it runs on the per-session foreground poll via
  `SessionManager.handleWorkingDir`. For any cwd with no `.git` ancestor the walk
  could fail to terminate, spinning a filesystem probe per iteration inside the
  actor — on a host whose Foundation exhibits the divergence below, that stalls
  workspace grouping and push rollups for the affected session. `GitRootResolver`
  walked up to the git root by calling
  `URL.deletingLastPathComponent()` until the parent equalled the current path.
  Foundation does not document that such a fixed point exists, and the
  `NSURL`-backed implementation instead maps `"/"` to `"/.."`, then `"/../.."`,
  accumulating without ever converging — so the guard never fired. It surfaced as
  a hung `swift-test` job on GitHub's `macos-15` runner, which it killed for a
  month while the same code converged locally; `sample` on the runner put
  all 2235 samples inside `-[NSURL URLByAppendingPathComponent:]`, i.e. a
  spinning loop rather than a parked `await`. No single factor selects the
  behaviour: varying only the linked SDK on one machine flips it, yet CI's binary
  was SDK-15-linked too and diverged where a local SDK-15-linked one converges,
  so the runtime Foundation participates as well. The walk now enumerates
  ancestors by dropping trailing components off the path *string*, which is
  finite by construction under every implementation, and splits Unicode scalars
  rather than `Character`s so a component beginning with a combining mark can't
  fuse onto the preceding separator and silently drop an ancestor level. The
  resolution step is a static function taking the existence check as a parameter,
  so a test can assert *which* paths it probes: with no `.git` anywhere the
  returned root is the input however the search got there, and when one is found
  the search stops well below `"/"`, so nothing about the return value — and no
  wall-clock bound, on a platform where the old walk happens to converge — could
  observe the defect. The seam is the whole normalize-then-search step rather
  than just the search, so the assertions can't be satisfied by a helper that
  production has stopped calling.
- **`forceRepaint()`'s size wiggle is now asserted against the kernel's own
  `winsize`.** The tests previously read the size back through a shell echoing
  `$COLUMNS`, which requires the shell to be scheduled before the assertion runs —
  on GitHub's `macos-15` runner it wasn't, so both tests failed there while passing
  locally. They now read the master fd directly (a new `relay_get_winsize` shim
  call behind a `_testOnly_` hook), which is the same `struct winsize` a Node/Ink
  app compares against its cache. No change to shipped behaviour; the repaint fix
  itself landed in 0.3.9.
- **Resumed sessions no longer poll at the slow cadence.** `SessionManager.resumeSession`
  reached `.activeAttached` without restoring `PTYSession.attachedPollCadence`, so the
  foreground-process poll stayed at the 5 s detached cadence. Same-device tab switches
  detach-then-resume, which made this the common path rather than a rare one: after
  switching tabs, agent entry/exit (and therefore the activity dot) could lag by up to
  5 s. `resumeSession` now restores the 1 s cadence exactly as `attachSession` does.
  All three cadence updates (attach/detach/resume) are now awaited rather than dispatched
  in unstructured `Task`s, so a tab switch's sequential detach→resume can no longer land
  its two writes out of order and leave an attached session polling slowly. Awaiting adds
  a suspension point to the reentrant `SessionManager` actor, so the three call sites no
  longer write the PTY directly: they route through a new `syncPollCadence(id:)` that
  **re-reads the cadence from the session's committed state after every suspension**
  rather than capturing it up front. Without that, a transition suspended mid-write still
  applies the value it decided on before suspending, so a detach's 5 s can land after a
  resume's 1 s — the same bug one level down, and one that statement ordering cannot fix
  because the race is between the two PTY writes. The loop exits on state agreement
  rather than a pass count: a bounded version stranded a stale cadence when a transition
  committed during its final write. `detachSession` additionally installs
  its detach-expiry timer above the suspension point; otherwise a reentrant
  `resumeSession` cancels a not-yet-installed timer and the detach then arms one against
  a session that is once again `.activeAttached`. Two adjacent detach-timer
  leaks are fixed alongside it: `attachSession` now cancels a live expiry timer (as
  `resumeSession` already did), and `handleDetachTimeout` drops its `detachTimers` entry
  unconditionally instead of returning from either early guard with the entry intact.
- **`claude-relay config validate` now uses the same port range the admin API enforces.**
  It checked 1–65535 while `PUT /config` accepts only 1024–65535
  (`AdminRoutes.validatePort`), so a privileged port such as 80 was reported as
  "Configuration is valid." even though `config set` refuses it — and, if it was already
  in `config.json`, the server would fail to bind it without root. A `wsPort ==
  adminPort` collision is also reported in the same pass as a range error rather than
  only after the range error is fixed. Additionally, a non-numeric port is now an error
  rather than being silently skipped by the old `if let port = Int(value), <range>`
  form — defence in depth, since `/config` serves a typed `RelayConfig` and so cannot
  currently put a non-integer on the wire.
- **The accepted port range is now defined once.** `1024...65535` was written out
  separately in `AdminRoutes.validatePort` and `ConfigSetCommand`, while
  `ConfigValidateCommand` kept its own already-drifted `1`/`65535` pair. All three now
  derive from `RelayConfig.portRange` in ClaudeRelayKit, so the CLI's client-side checks
  cannot disagree with what the admin API accepts.

## [0.3.17] - 2026-08-01 — Device pairing via QR

Ships the F11 device-pairing feature across all four targets (herdr F11, 1a/1b/1c).

### Server + CLI

- **`claude-relay setup`** mints a single-use pairing code (8 chars Crockford
  Base32 = 40 bits, 5-minute TTL) via `POST /pair/create` on the localhost-only
  admin API and renders it as a terminal QR encoding
  `coderelay://pair?host=&port=&tls=&code=`. `setup` also starts the service
  using whichever manager owns it.
- **Pre-auth redemption** — the device sends `pair_request` and receives
  `pair_success{token, tokenId, label}`, then performs the normal
  `auth_request` with the minted token, all on one socket inside the existing
  10 s auth timer. Pairing never sets `isAuthenticated`, so there remains
  exactly one path to an authenticated connection.
- **Abuse bounds** — a bad code is a `RateLimiter.recordFailure(ip:)` identical
  to a bad token (10 attempts / 60 s), plus a per-connection cap of 3 mirroring
  `maxAuthAttempts`. `PairingCodeStore` is in-memory, constructed once in
  `main.swift`, and injected with no default parameter.
- **Revocable per-device tokens** — the minted token is labeled
  `"<device> (paired)"` (or the operator's `setup --label`), sanitised
  identically on both the mint and redeem paths: control characters and
  newlines stripped, capped at 60 scalars.
- **Service manager awareness** — `ServiceManagerDetector` resolves whether
  `homebrew.mxcl.clauderelay` or `com.claude.relay` owns the server, and every
  service command nudges with the correct command instead of driving the wrong
  label. `load` refuses to create a second manager without `--force`.
  Previously `start`/`stop`/`restart`/`unload` failed outright on a Homebrew
  install.

### Clients (iOS, macOS, Android)

- QR scanning on iOS and Android; macOS pairs via manual code entry in the
  **Pair** sheet (its `Cmd+Shift+Q` scanner still handles session-attach QRs
  only). `PairingURL` + `PairingCode` live in ClaudeRelayKit so validation of
  hostile QR input happens in one tested place, shared by all three clients.

## [0.3.16] - 2026-07-29 — Server-side ownership visibility

### Server

- **`auth_success` now carries `tokenId`**, so a client can name its own
  ownership boundary instead of inferring it.
- **`session_list` is logged** (token truncated to 8 chars). This is the answer
  to "which sessions does this client own" — the question behind every
  empty-pane report — and five fixes shipped without it being visible from the
  server side.

### Clients

- Six accumulated session-ownership fixes (iOS build 174, macOS build 97,
  Android 0.3-m43): the server is now authoritative for session ownership with
  no local owned-set (#41); lost sessions are classified by `tokenId` so a
  relaunch no longer wipes owned sessions (#39, #40); the launch session fetch
  is no longer lost to the debounce (#42); a just-established socket is not
  reconnected on foreground (#43); and connect→auth→list is one
  uninterruptible handshake (#44).
- **macOS**: fixed a perpetual connection-dot blink that pinned Core Animation.

## [0.3.15] - 2026-07-25 — Working-state detection from the spinner line

### Server

- **Detect Claude Code's working state from the live spinner line** (a gerund
  followed by an elapsed-timer paren) rather than the "esc to interrupt"
  footer, which was not reliably present.

## [0.3.14] - 2026-07-25 — Auth desync and reconnect-storm fixes

### Clients

- **Treat auth `error(400)` as idempotent success.** `authenticate()` was the
  only `SessionController` method missing a `case .error` branch, so a server
  error on the auth path fell through to `default` and threw
  `unexpectedResponse(typeString)` = `"error"` — surfacing on iOS as
  "Unexpected server response: error" and blocking session creation. A 400
  "Already authenticated" means the socket *is* authenticated (a client/server
  auth-state desync), so the client now adopts the authed state; other codes
  (429/401/500) surface their real message. Mirrored in the Kotlin client.
- **macOS: stopped a runaway status-poll reconnect storm.** A dead
  `MainWindow.serverList` `@StateObject` that was never referenced kept a 5 s
  status poller alive forever.

### Server

- Excluded the creator's own steal observer on `session_create`.

## [0.3.13] - 2026-07-24 — herdr feature set + Android FCM

### Server

- **F5 — broader agent support**: Copilot CLI, Cursor Agent, and Droid join the
  `CodingAgent` registry (#32).
- **F6 — hook-based state authority**: an optional local Claude Code hook
  POSTs `{sessionId, state}` to the localhost-only `POST /hook/state`,
  overriding screen detection for a 10 s TTL. The hook reports state only —
  agent identity stays owned by the foreground poll (#33).
- **F11 (first half) — two-way clipboard**: `OSC52Parser` runs over the raw PTY
  stream and forwards decoded clipboard writes as `clipboard_update`, so tmux,
  vim, and kitty get clipboard-to-device sync with no per-tool integration
  (#35).
- **F1/F2 — push notifications and workspace rollups**: APNs/FCM delivery with
  per-session ordered edge detection (#30), and server `cwd`→git-root mapping
  driving grouped sidebars (#29). Per-device APNs topic so iOS and macOS both
  receive push (#31).

### Clients

- **iOS/macOS**: F3 session/layout persistence and restore (#34), the F5 agent
  palette, and F11 clipboard writes.
- **Android**: FCM push (messaging service, token registration, notifications),
  F5, F3, and `applicationId` set to `com.singular.coderelay` for Firebase.

### CI

- macOS app builds on `macos-26` (Xcode 26 SDK) for `ToolbarSpacer` (#36); the
  Swift job is capped at 20 min so a hung test fails fast (#37).

## [0.3.12] - 2026-07-22 — Agent-cluster flicker fix

### Server

- **The OSC terminal-title path could evict a running agent.** Claude Code
  continuously rewrites its window title while working, with no "claude"
  keyword; two such titles between foreground-process polls tripped the shared
  exit-debounce counter and fired `exitAgent()`, pushing `agent=nil` to
  clients — so the sidebar agent cluster and tab color vanished and reappeared
  every few seconds. The title path now drives agent **entry** only; exit is
  owned solely by the foreground-process poll (kernel process-tree ground
  truth).

### Clients

- The idle/"Waiting" state color changes from teal to yellow across the sidebar
  dot, activity dot, state pill, and session tab.
- Session state indicators redesigned across all clients, with an animated
  agent sparkle in the sidebar row (#28).

### Packaging

- **The Homebrew formula now installs the `ClaudeRelayServer` resource bundle.**
  Without it `session_create` crashed the server, while `status` and `health`
  still passed.

## [0.3.11] - 2026-07-22 — Uptime and reply-routing fixes

### Server

- **`/status` uptime no longer always reports ~0 s.** `AdminRoutes.startTime`
  was a lazily-initialized `Date()` set on the first `/status` call; it now
  reads the kernel process start time via CPTYShim, matching `PTYSession`.

### iOS

- **Fixed the "unexpected server response: auth_success" popup on connect** by
  scoping every `SessionController` command waiter to its own reply type, so a
  concurrent `auth_success` can no longer be captured by a
  `createSession`/`attach`/`resume` waiter.

## [0.3.10] - 2026-07-22 — Agent-state detection across all clients

### Server

- **Manifest-driven agent state detector** with bundled per-agent manifests and
  a screen-detection arbiter, plus the herdr screen-region slicers and
  opencode support. Produces idle/working/blocked/unknown per session.

### Clients

- iOS, macOS, and Android surface the agent state and window title in the
  sidebar; Android also shows rich agent state in its compact session tabs.
- Fixed flagging the active session as unseen, bounded emulator scrollback, and
  pinned the SwiftTerm floor to 1.10.0.

### Dependencies

- WhisperKit bumped to 1.0.0 (drops swift-transformers/jinja). The release CI
  build is scoped to server products so it skips the WhisperKit compile.

## [0.3.9] - 2026-07-08 — Refresh actually repaints Claude Code

### Server

- **`forceRepaint()` is now a real resize wiggle** — the 0.3.8 refresh
  delivered SIGWINCH at unchanged size, which Node/Ink apps (Claude
  Code) ignore: Node re-reads TIOCGWINSZ in its WINCH handler and skips
  the redraw when dimensions match its cache (measured: 0 repaint bytes
  on same-size WINCH vs a full repaint on a 1-column change). The server
  now mimics the keyboard show/hide gesture: TIOCSWINSZ to cols−1,
  150 ms, restore. A client resize landing mid-wiggle wins — the restore
  re-reads the tracked size after the gap. No protocol change; existing
  clients' tap-to-redraw starts working once the server is upgraded.
  Post-replay repaint on reattach inherits the same fix.

## [0.3.8] - 2026-07-07 — Client-requested screen refresh

### Server + Protocol

- **`refresh` client message** — new `ClientMessage` case (`"refresh"`,
  empty payload). The server delivers SIGWINCH to the attached session's
  foreground process group via the existing `PTYSession.forceRepaint()`,
  making the running full-screen app (Claude Code, vim, …) re-emit its
  whole screen. Fire-and-forget: no ack, the repaint bytes are the
  response. Additive — no `protocolVersion` bump; older clients simply
  never send it, but clients that DO send it need a server at this
  version or newer (older servers reply error 400 to the unknown type).

### Apps (iOS + Android)

- **Tap-to-redraw now actually works** — tapping the session-name badge
  sends `refresh`, so the glyph-overlap artifact is fixed by fresh
  authoritative bytes from the running app instead of a client-side
  repaint of the (possibly corrupt) local grid. This is the same replay
  the keyboard show/hide toggle triggers as a side effect of resizing,
  without moving the keyboard. Local repaints (iOS `updateScroller`
  re-sync, Android full-grid damage) are kept as belt-and-suspenders.

## [0.3.6] - 2026-05-15 — Silent scrollback replay on reattach

### Server + Client

- **`replay_complete` protocol message** — new `ServerMessage` case sent by
  the server after the binary scrollback chunks (and before
  `session_activity`) on every `session_attach` and `session_resume`,
  including the empty-buffer case. The protocol stays additive: no
  `protocolVersion` bump, the message is ignored by clients that don't
  recognise it.
- **Client-side replay buffering** — `TerminalViewModel` gains an
  `isReplaying` gate. While the gate is held, all incoming bytes are
  parked in `pendingOutput` regardless of whether the SwiftUI terminal
  view has already laid out (`terminalSized`). On `replay_complete` the
  gate releases and the entire buffer is fed to SwiftTerm in one batch,
  so SwiftTerm's 60 fps `queuePendingDisplay` coalesces the whole
  scrollback into a single rendered frame. The user no longer sees the
  terminal scroll through 512 KB of history when reattaching to a
  long-lived session.
- **`SharedSessionCoordinator`** sets `vm.beginReplay()` before
  `attachSession` / `resumeSession` and routes the new
  `RelayConnection.onReplayComplete` callback into `vm.endReplay()` so
  the gate opens deterministically rather than via a timer heuristic.

SPM test count: **677** (was 672) — added protocol round-trip /
field-verification tests for `replay_complete` plus two
`WebSocketIntegrationTests` covering the emit ordering (after binary,
before activity) and the empty-buffer-still-emits invariant.

## [0.3.5] - 2026-05-11 — macOS QR attach + session steal fix

### macOS

- **QR code scanning for session attach** — macOS app can now scan QR codes to attach to sessions, matching the iOS feature. Includes refusal fallback for denied camera access.
- **Menu bar refactored** — removed Settings from the menu bar toolbar; added Servers + Attach Session items for quicker navigation. Settings popup restored as a non-toolbar item.

### Server

- **Session steal stops output to stolen device** — when a session is stolen via `attachSession`, the server immediately stops sending output to the previous owner and unclaims it, preventing a race where stale output could leak to a device that no longer owns the session.

## [0.3.4] - 2026-05-10 — Continuous listening + test coverage expansion

### Speech — continuous listening redesign (iOS 1.4.0, macOS 1.1.0)

- **Strict two-phase wake-word flow.** New `.armed` state sits between
  `.detectingWakeWord` and `.recording`. User says "Claude" → mic turns red
  → user speaks command → Smart-Turn decides when they're finished. Combined
  utterances ("Claude list my files" in one breath) are rejected — the visual
  red-light handshake is load-bearing. `.armed` times out to `.listening`
  after 4 s if no command speech starts. UI color buckets: blue for
  `listening`/`detectingWakeWord`, red for `armed`/`recording`/
  `detectingTurnEnd`, yellow for processing.
- **Wake-word recall boosters** (`WakeWordAudioPreprocessor`). Peak-normalize
  clips to ~0.95 so a quiet "Claude" reads as loud; pad to 3 s of silence so
  Whisper's encoder stops treating it as an outlier. Match cascade now ends
  in Metaphone phonetic equality with a first-letter guard, catching
  Whisper mishearings like "clod" / "clawed" without hard-coding them.
- **Smart-Turn is now authoritative.** VAD `minSilenceDuration` raised
  from 0.3 s to 1.0 s so natural breath pauses don't fire `silenceStart`.
  The turn-end race no longer treats timer-wins as "force done" — the
  timer is a safety-net against hung CoreML inference that resumes
  `.recording` on expiry. `raceTurnEnd` returns three-way
  `TurnEndDecision {done, continuing, inferenceTimedOut}`. Default
  `turnEndSilenceTimeout` raised from 1.5 s to 8 s. The user-facing
  "Silence Timeout" slider was removed from Settings on both platforms,
  along with its `@AppStorage` — the value comes from
  `SpeechProcessingOptions` defaults now.
- **VAD swapped to FluidInference Silero-VAD v6 unified** (stateful LSTM,
  576-sample input) in `SileroVoiceActivityDetector`. Smart-Turn v3 +
  Whisper log-mel `.mlpackage` now bundled; both fall back gracefully
  when the resource fails to load or compile.

### Test coverage expansion

A full-codebase test gap analysis followed by a targeted coverage sweep. SPM
test count: **532** → **672**. The sweep focused on modules with zero or
superficial coverage, and on protocol edge cases, concurrency invariants,
and error paths that had previously been exercised only through integration
tests.

### Kit module

- **`ConnectionQuality` fully covered** (new `ConnectionQualityTests`, 18
  tests) — every RTT threshold (100 ms, 300 ms, 800 ms) and success-rate
  threshold (50 %, 83 %, 100 %) pinned to an explicit boundary test. Locks
  in the documented asymmetry that `.excellent` requires a perfect success
  rate, and that `.disconnected` is never returned by the initializer (it's
  set externally when the connection dies).
- **`RelayConfig` fully covered** (new `RelayConfigTests`, 10 tests) —
  default values, Codable round-trip, backward-compat decoding when older
  configs omit `maxSessionsPerToken` / `bindAll`, and the `configDirectory`
  / `configFile` / `tokensFile` URL shape. Prevents a missing field in an
  older `config.json` from drifting toward unsafe defaults.
- **`TokenInfo.isExpired` pinned** (extended `TokenGeneratorTests`, 8 new
  tests) — covers `expiresAt = nil` / past / future, plus
  `TokenGenerator.generate` with `expiryDays = 0 / nil / N`. Also asserts
  SHA-256 hash output is 64 lowercase hex chars and that Base64URL tokens
  contain no `+`, `/`, or `=`.
- **Previously untested protocol cases** (extended `ClientMessageTests`,
  `ServerMessageTests`, `MessageEnvelopeTests`, 22 new tests) — round-trip
  coverage for `sessionTerminate`, `sessionList`, `sessionListAll`,
  `pasteImage`, `pasteImageResult`, `sessionResume(skipReplay: true)`, and
  `authRequest` / `authSuccess` with `protocolVersion`. Error-path tests
  for unknown type strings, missing `type` / `payload` keys, and empty type
  strings assert the envelope rejects malformed frames instead of silently
  falling through.

### Server module

- **`TokenStore.rename` and `TokenStore.inspect` covered** (extended
  `TokenStoreTests`, 5 new tests) — rename round-trip and persistence
  across actor instances, plus `tokenNotFound` error paths for both
  methods. These were the two public surfaces on `TokenStore` with zero
  coverage.
- **Admin HTTP API endpoint tests** (new `AdminRoutesEndpointTests`, 13
  tests) — exercises `/health`, `/status`, `/sessions`, `/sessions/{id}`,
  `/tokens`, `/tokens/{id}`, `/config`, `/logs`, and unknown-route 404s
  directly against `AdminRoutes.handle` with a real `SessionManager` and
  `TokenStore`. Previously these routes were only exercised through the
  CLI integration path.
- **`RateLimiter` concurrency** (extended `RateLimiterTests`, 4 new tests)
  — `TaskGroup`-based stress covers concurrent `recordFailure` across 100
  tasks, mixed `recordFailure` / `isBlocked` on the same IP, `reset` racing
  with `isBlocked`, and LRU eviction retaining the most recent IPs when
  `maxTrackedIPs` is exceeded. Asserts the actor's invariant holds under
  the scanner-traffic shape that motivated the LRU cap.

### Client module

- **`RecoveryController` directly tested** (new `RecoveryControllerTests`,
  7 tests) — previously the circuit breaker, generation tokens, and
  cooldown logic were only covered transitively through
  `SharedSessionCoordinator`. New tests drive the state via the
  `_testOnly_` hooks: breaker reset semantics (idempotent when already
  idle), `scheduleAutoRecovery` gated on torn-down / suspended state,
  `triggerUserRecovery` torn-down no-op, and `cancel` suspending + the 1 s
  cancel-debounce on subsequent `triggerUserRecovery`.
- **`TerminalViewModel` send suppression covered** (extended
  `TerminalViewModelTests`, 4 new tests) — `isSendingSuppressed = true`
  makes `sendInput` (both `Data` and `String` variants) a no-op, empty
  `Data` to `receiveOutput` doesn't crash, and `String` input encodes via
  UTF-8.

### CLI module

- **`AdminClient` covered** (new `AdminClientTests`, 9 tests) — base-URL
  construction across the UInt16 range (min, max, default, custom),
  `isServiceRunning` returning `false` for a closed port, every
  `AdminClientError` case's `errorDescription`, and the default 10 s
  request timeout. Previously the HTTP client used by every CLI command
  had zero unit coverage.
- **`OutputFormatter` error formatting** (extended `OutputFormatterTests`,
  6 new tests) — `formatError(_:json:)` with a generic `NSError` (human +
  JSON), `AdminClientError.serviceNotRunning` (human + JSON),
  `AdminClientError.httpError` parsing an embedded `{"error": ...}` body,
  and table formatting with combining-mark Unicode content.

### Speech module (Xcode-only)

- **`SpeechEngineState` covered** (new `ClaudeRelayAppTests/SpeechEngineStateTests`,
  9 tests) — `isActive` returns `false` for `.idle` / `.error`, `true` for
  the four active cases; all six `description` strings pinned; Equatable
  conformance asserted for both base cases and associated-value cases.
- **`WhisperTranscriber.isSilenceHallucination` covered** (new
  `ClaudeRelayAppTests/WhisperHallucinationTests`, 12 tests) — every known
  Whisper silence hallucination from the static set ("thank you",
  "thanks for watching", "subscribe", "okay", "hmm", etc.) plus
  case-insensitivity, punctuation stripping, and negative cases ensuring
  normal user input isn't mis-classified. These tests run in the iOS test
  bundle; SPM `swift test` does not exercise them.

### Speech — continuous listening redesign (iOS 1.4.0/111, macOS 1.1.0/32)

- **Strict two-phase wake-word flow.** New `.armed` state sits between
  `.detectingWakeWord` and `.recording`. User says "Claude" → mic turns red
  → user speaks command → Smart-Turn decides when they're finished. Combined
  utterances ("Claude list my files" in one breath) are rejected — the visual
  red-light handshake is load-bearing. `.armed` times out to `.listening`
  after 4 s if no command speech starts. UI color buckets: blue for
  `listening`/`detectingWakeWord`, red for `armed`/`recording`/
  `detectingTurnEnd`, yellow for processing.
- **Wake-word recall boosters** (`WakeWordAudioPreprocessor`). Peak-normalize
  clips to ~0.95 so a quiet "Claude" reads as loud; pad to 3 s of silence so
  Whisper's encoder stops treating it as an outlier. Match cascade now ends
  in Metaphone phonetic equality with a first-letter guard, catching
  Whisper mishearings like "clod" / "clawed" without hard-coding them.
- **Smart-Turn is now authoritative.** VAD `minSilenceDuration` raised
  from 0.3 s to 1.0 s so natural breath pauses don't fire `silenceStart`.
  The turn-end race no longer treats timer-wins as "force done" — the
  timer is a safety-net against hung CoreML inference that resumes
  `.recording` on expiry. `raceTurnEnd` returns three-way
  `TurnEndDecision {done, continuing, inferenceTimedOut}`. Default
  `turnEndSilenceTimeout` raised from 1.5 s to 8 s. The user-facing
  "Silence Timeout" slider was removed from Settings on both platforms,
  along with its `@AppStorage` — the value comes from
  `SpeechProcessingOptions` defaults now.
- **VAD swapped to FluidInference Silero-VAD v6 unified** (stateful LSTM,
  576-sample input) in `SileroVoiceActivityDetector`. Smart-Turn v3 +
  Whisper log-mel `.mlpackage` now bundled; both fall back gracefully
  when the resource fails to load or compile.

## [0.3.3] - 2026-05-07 — Hardening review follow-ups

Executes the plan captured in `docs/superpowers/plans/2026-05-07-hardening-review-followups.md`.

### Server

- **`RelayMessageHandler` concurrency discipline formalised** — introduced a `bridgeToEventLoop` helper that names the "Task → await → eventLoop.execute" pattern used across nine request handlers. The pattern was previously duplicated inline; now every migrated handler expresses handler-state mutations inside an `onSuccess` / `onFailure` closure that the helper guarantees to run on the channel event loop. `@unchecked Sendable` discipline is now one reviewable shape rather than nine copy-pasted snippets.
- **`SessionRequestHandlers` extracted** — the nine session-lifecycle handlers now live in a sibling `SessionRequestHandlers.swift` as an extension on `RelayMessageHandler`. The primary file shrunk 849 → 646 lines (class body 462, under the 500-line `type_body_length` ceiling without a `swiftlint:disable` pragma). No behaviour change.

### Client

- **`RecoveryController` extracted** — the auto-recovery circuit breaker, generation tokens, cooldown tracking, reconnect backoff, and `restoreSession` flow moved from `SharedSessionCoordinator` into a sibling `RecoveryController` type. Coordinator shrank 907 → 681 lines (class body 474, under the 500-line ceiling). The `@Published` recovery UI flags still live on the coordinator because SwiftUI binds to them.
- **`cachedTerminalViews` back-compat shim removed** — three test call-sites now read `terminalCache.cachedIds.count`. No production code ever read the shim.

### Apps

- **Bedrock token Keychain writes debounced** — both iOS and macOS `AppSettings` now store a stored `@Published var bedrockBearerToken` seeded from the Keychain at launch; writes flow through a 500 ms Combine debounce so typing a 40-character token results in one `SecItemAdd`, not 40. Migration is now resilient to a partial Keychain failure: the legacy `UserDefaults` copy is only scrubbed after save-plus-reread confirms the value landed, so a partial save no longer makes the token vanish from the UI.
- **iOS test coverage** — 9 new tests in `AppSettingsBedrockTests` exercise the pure migration + fallback helpers. Fixed pre-existing test-target compile failures (added `ClaudeRelaySpeech` dep + imports, marked `TextCleanerStaticTests` `@MainActor`).

### Tooling

- **SwiftLint `type_body_length.error` tightened back to 500** — was temporarily 1000 during the v0.3.2 hardening pass pending the `RelayMessageHandler` + `SharedSessionCoordinator` splits. Full `Sources/` lint is 15 warnings, 0 errors across 65 files.

### Documentation

- **ATS scoping documented** — README now carries a "When TLS is required" subsection explaining that the apps' `NSAllowsLocalNetworking` ATS entry only covers RFC1918, loopback, `.local`, and link-local addresses. Tailscale CGNAT (`100.64/10`), IPv6 ULA, and public hostnames require TLS on the server (`tlsCert` + `tlsKey`) and a `wss://` URL in the app — ATS does not support CIDR ranges, so this is the supported path for non-LAN deployments.

### Configuration

- **`bindAll` config key controls WebSocket bind host** — previously the server bound `0.0.0.0` unconditionally. The behavior is now gated by a config key (default `true`, network-reachable on every interface, matching the previous behavior) so operators can tighten to `127.0.0.1` with one toggle. Set `bindAll=false` (via `claude-relay config set bindAll false` or `--no-bind-all` on `claude-relay load`) to restrict to localhost. Startup logs identify the bound host, and emit a clear `[ERROR]` line when `bindAll=true` without TLS to surface the plaintext-on-network risk.
- Existing configs on disk that never mentioned `bindAll` inherit the default (`true`) so upgrading users keep their previous reachability.

### Security

- **Shared rate limiter on WebSocket auth** — the admin HTTP surface's `RateLimiter` is now shared with the WebSocket server. Brute-force scanners that opened a fresh TCP connection per auth attempt (bypassing the per-connection 3-strike cap) are now rejected with a 429 frame before they can even send `auth_request`. `handlerAdded` captures the client IP, `isBlocked` is checked before arming the 10 s auth timer, and `auth_failure` records against the shared bucket.
- **Apps scope ATS to local networking** — `NSAllowsArbitraryLoads` replaced with `NSAllowsLocalNetworking` on both iOS and macOS apps. Plaintext `ws://` is now allowed only to RFC1918 / link-local addresses (typical LAN servers); plaintext to a public hostname is refused. Users who need public-hostname plaintext must configure TLS on the server (`bindAll` + `tlsCert`/`tlsKey`).

### Tooling

- **PR-gated CI workflow** — `.github/workflows/ci.yml` runs `swift build`, `swift test`, `swiftlint`, and iOS/macOS Xcode builds on every pull request.
- **SwiftLint clean baseline** — split `SessionManagerTests` into three focused suites (`SessionLifecycleTests`, `SessionObserverTests`, `SessionOwnershipTests`) with a shared `SessionManagerTestCase`; closed remaining file-length and type-body-length errors.

## [0.3.2] - 2026-05-04 — Review-driven hardening pass

A 59-task sweep resolving 98 findings (26 HIGH, 46 MEDIUM, 26 LOW) from a full-codebase multi-agent review. No protocol or UX changes; the focus is lifecycle correctness, memory bounds, resource cleanup, and test coverage. See `docs/superpowers/plans/2026-05-04-full-codebase-review-fixes.md` for the full task matrix. SPM test count: 349 (was 331).

### Reliability (client + apps)
- **Foreground recovery never gets stuck** — `SharedSessionCoordinator.handleForegroundTransition` now uses an idempotent outer `defer` so mid-flight cancellation always clears `isRecovering`, unblocking all future recovery attempts
- **Skip recovery when alive** — scenePhase `.active` now short-circuits before paying for a ping RTT if the connection is already healthy
- **Auth path race eliminated** — `SessionController.sendAndWaitForResponse` response handler consolidation fixed a pending-value race; added error-path coverage
- **Connection-quality window bounded** — `RelayConnection.rttWindow` bookkeeping centralized in `recordRTT`, guaranteeing the 6-measurement cap and failure counter are always enforced
- **ConnectionConfig.wsURL returns optional** — malformed hosts from corrupted bookmarks or deep links no longer crash the app
- **ServerStatusChecker probe cleans up on cancel** — wrapped in `withTaskCancellationHandler` so FDs aren't leaked when the 5 s timeout racer wins

### Reliability (server)
- **Non-blocking PTY writes with EAGAIN buffer** — master FD set to `O_NONBLOCK`; a `DispatchSourceWrite` drains a 4 MB queue when the FD is ready, preventing paste/rapid-input from starving the session actor
- **PTY output backpressure** — cap inflight WebSocket-write bytes per session at 2 MB; skip frames while writes drain (server's ring buffer is authoritative and replays on resume)
- **Stale observer dictionaries purged** — `SessionManager` evicts observer entries older than 1 h every 30 min, preventing unbounded growth when handlers die without running `cleanupSession()`
- **`RateLimiter.attempts` LRU-capped at 10 k IPs** — under sustained scanning traffic the dictionary grew without bound; evicts oldest 10 % on overflow
- **Graceful shutdown has a 10 s timeout** — `main.swift` races normal shutdown against a timer and force-exits with a log line rather than hanging on a stuck PTY
- **`TokenStore.flushTask` cancelled up-front in `flushIfDirty`** — removes the race that could leave a dangling Task after `shutdownGracefully`
- **Per-token session cap** — new `maxSessionsPerToken` config (default 50, 0 = unlimited); prevents a runaway client from fork-bombing the server with unlimited sessions
- **`ConfigManager.load` returns defaults on corrupt file** — a bad edit to `config.json` no longer crashes launchd-managed services
- **`LogStore` compacts at 5 % overshoot** — was +1000 entries, so the live array stayed within ~1.05× capacity instead of oscillating wildly

### Reliability (CLI)
- **`AdminClient` requests timeout at 10 s** — was URLSession default (~60 s); `claude-relay health` / `status` now feel instant when the server is hung
- **Client-side `config set` validation** — CLI rejects unknown keys, out-of-range ports, bad log levels, and negative session limits before they reach the admin API
- **`claude-relay config validate` command** — runs the same checks on the saved config file without touching the server

### Reliability (speech)
- **`TextCleaner` confined to `@MainActor`** — removed `@unchecked Sendable`; `clean()`/`unload()` concurrency is now enforced at compile time
- **`AudioCaptureSession` auto-stops after 5 minutes** — a forgotten backgrounded recording was allocating ~77 MB of `Float` samples
- **`OnDeviceSpeechEngine.stopAndProcess` cancels prior `processingTask`** — defensive guard against rapid double-taps orphaning the handle
- **`CloudPromptEnhancer` error bodies sanitized** — `Bearer <token>` redacted from log lines; JSON parsed to extract clean error messages

### Reliability (iOS + macOS apps)
- **TerminalViewModel `terminalReady()` called once per session** — `updateUIView` was firing on every coordinator property change, triggering redundant pending-buffer flushes
- **`ServerListViewModel.stopPolling()` in `deinit`** — poll task no longer survives VM deallocation
- **`ServerListViewModel.cancelConnect` no longer resets `isConnecting` inside defer when cancelled**
- **iOS port validation matches macOS (`>= 1`)** in `AddEditServerViewModel`
- **iOS `connectionTimedOut` alert is binding-based** — was racy under rapid toggles; now tracks the `@Published` property directly
- **iOS speech preload task cancelled on `ServerListView.onDisappear`** — stops the ~1 GB model download when the user navigates away
- **iOS `AppSettings` accessed via `@ObservedObject` in closures** — was grabbing `.shared` at closure-capture time, missing later mutations
- **macOS `coordinatorTasks` pre-cancelled before spawning new ones** in `followCoordinator`
- **macOS key-capture window observer explicitly cancelled** on disappear
- **macOS `TerminalContainerView` scrollback-clear behavior matched to iOS**

### Memory bounds
- **`TerminalViewModel.pendingOutput` capped at 4 MB** with a once-per-session warning when drops begin
- **Terminal scrollback configurable via Settings** — `terminalScrollbackLines` (default 5000, up to 25000); iOS devices with 4 GB RAM no longer hold 10 k lines × N cached sessions. Server ring buffer still replays anything that fell off the edge on reattach.
- **`SavedConnectionStore` encoding errors logged** instead of silently losing bookmarks
- **`SpeechModelStore.totalModelSize` overflow-safe** and skips directories during enumeration

### Performance
- **Shared `JSONEncoder`/`JSONDecoder` in `RelayMessageHandler`** — 1000 concurrent connections previously allocated 2000 encoder+decoder pairs
- **Zero-copy `RingBuffer.write` via `withUnsafeMutableBytes`** — shaves an 8 KB allocation per PTY output chunk at peak throughput
- **`CodingAgent.processNames` pre-lowercased at init** — avoids a string allocation per hot-path foreground-process poll
- **iOS session-tab `TimelineView` only ticks when a tab is flashing** — idle case is a static render

### Refactors (behavior-neutral)
- **`ActiveTerminalView` split into three components**: `MicButton`, `QRCodeGenerator`/`QRCodeOverlay`, and `RelayTerminalView` (now in `ClaudeRelayApp/Views/Components/`). The outer file now holds only orchestration + the session tab bar.
- **`ConnectionQualityDot`, `ActivityDot`, `AgentColorPalette` moved to `ClaudeRelayClient/Views/`** — single source of truth shared by iOS and macOS (the two `AgentColorPalette` copies were byte-identical)
- **`activityState(for:)` moved to `SharedSessionCoordinator`** — iOS sidebar, macOS sidebar, and macOS status bar had three copies of the same helper

### Accessibility
- iOS toolbar icon buttons now have accessibility labels
- Renamed stale "ClaudeDock" header in macOS `SettingsView` to "ClaudeRelay"

### Tests
- New `WebSocketIntegrationTests` — real client ↔ real server round-trip, plus force-reconnect preserves auth flow
- New `SessionManagerTests.testConcurrentAttachProducesSingleOwner`
- New `RateLimiterTests` — IP released when window elapses
- New `TerminalViewModelTests` — preserves data at cap, drops cleanly over cap
- New `RelayConnectionTests` — alternating ping successes/failures stay bounded by `rttWindow`, error-path coverage for auth + lightweight reconnect
- `SessionActivityMonitorTests.testTransitionsToIdleAfterSilence` de-flaked via backoff polling instead of callback-waiting
- Opportunistic coverage added across SPM targets (SPM test count: 349, was 331)

### Developer experience
- Named constants across Kit / Server / iOS replacing magic numbers (`maxInflightOutputBytes`, `maximumDuration`, `pendingOutputByteLimit`, connection-quality thresholds, ring-buffer replay chunk, keyboard accessory sizes)
- Expanded `UnsafeTransfer` doc comment with explicit event-loop-confinement warning
- CLI `session list` uses `RelativeDateTimeFormatter` to match token timestamps
- Dropped unused `import Foundation` from `ActivityState`
- `ExportOptions.plist` gitignored

## [0.3.0] - 2026-05-03

### Added
- **Multi-agent detection** — activity monitoring now supports any registered coding agent, not just Claude Code. New `CodingAgent` model with pluggable registry (ships with Claude Code + Codex)
- `AgentColorPalette` for per-agent tab coloring (Claude = existing blue, Codex = dark teal)
- Admin HTTP body cap at 64 KB with 413 rejection for oversized requests
- `SpeechEngineState` enum extracted to ClaudeRelaySpeech for cross-platform UI observation
- `TerminalCacheLRUTests` for LRU eviction logic

### Changed
- `ActivityState` generalized: `claudeActive`/`claudeIdle` → `agentActive`/`agentIdle` (wire-compatible with old values via Codable fallback)
- LRU-bound terminal cache at 8 sessions (evicts oldest on overflow)
- Byte-cap on pending terminal output to prevent memory pressure
- Server session listings served from cached activity state (no actor hops)
- Foreground-process poll slowed to 5 s while session is detached
- ANSI regex skipped on hot path when no agent is running
- Server probe is auth-only (dropped `sessionCount` from `ServerStatus`)
- Refocus fires only on session change, not every attach
- Homebrew formula bumped to v0.3.0
- SPM test count: 331 (was 307)

### Fixed
- Agent process-chain walk now stops at own PID (prevents false self-match)
- Suppress terminal sends during recovery to prevent command-response collision
- Codex tab color corrected from purple to dark teal

## [1.0] - 2026-05-03 — macOS App

### Added
- **ClaudeRelayMac** — native macOS client with full iOS feature parity
  - Single-window terminal with sidebar session list and `NavigationSplitView` layout
  - Menu bar persistent icon (`MenuBarExtra(.window)`) showing connection state and session list with activity icons
  - Keyboard shortcuts: `Cmd+T` new session, `Cmd+W` detach, `Cmd+Shift+W` terminate, `Cmd+1..9` switch by index, `Cmd+0` toggle sidebar, `Cmd+Shift+[/]` previous/next session, `Cmd+Shift+Q` scan QR code
  - Automatic foreground recovery via `NSWorkspace` sleep/wake and `NWPathMonitor` network-change observers
  - Launch-at-login via `SMAppService.mainApp` (macOS 13+) with optional menu-bar-only mode
  - Image paste: `Cmd+V` from clipboard and drag-and-drop onto terminal
  - QR code: generation for sharing sessions to mobile, camera scanning for inbound attach
  - On-device speech engine: WhisperKit (CoreML/ANE) + LLM.swift (Metal) + optional Anthropic Haiku enhancement via AWS Bedrock
  - Session naming themes shared with iOS (Game of Thrones, Viking, Star Wars, Dune, Lord of the Rings)
  - `coderelay://session/<uuid>` deep link support
  - TLS toggle per saved server

### Shared Library Changes
- `SessionCoordinating` protocol added to `ClaudeRelayClient` and conformed by both apps — formalizes the cross-platform session-lifecycle surface
- `SessionNamingTheme` and `SessionNaming.pickDefaultName` moved to `ClaudeRelayClient` as shared types
- New `ClaudeRelayClientTests` target (SPM test count now 307)

### Infrastructure Fixes
- Fixed `ClaudeRelayAppTests` target missing Info.plist generation (pre-existing, surfaced while regression-testing the Mac work)
- `project.yml` now declares `info.path` for both iOS and Mac app targets (required by XcodeGen 2.45+)

## [0.2.2] - 2026-04-25

### Fixed
- Cross-device attach: preserve session name and fix state transition when attaching from a different token
- Allow `activeDetached` → `activeAttached` transition for cross-device list-based attach
- Send scrollback history when attaching remote sessions (not just on resume)
- Prevent observer leak when channel disconnects during auth registration
- Robust Claude Code detection with parent chain walk (up to 5 ancestors) and exit debouncing
- Replaced `libproc` with `sysctl KERN_PROCARGS2` for reliable cross-platform process detection
- Restore Claude detection state on session resume and app relaunch
- Increased WebSocket frame limits to 10 MB to support image pasting

### Fixed (iOS)
- Reset terminal before scrollback replay on foreground recovery
- Prune stale session names so thematic naming works again
- Rename sessions via alert instead of inline editing
- Match splash background to AppIcon sRGB exactly
- Resolve Swift 6 Sendable warnings in speech layer

## [0.2.0] - 2026-04-16

### Added
- Protocol version negotiation — client and server exchange `protocolVersion` during auth handshake
- Image paste support (`paste_image` client message, `paste_image_result` server response)
- Server version displayed in `claude-relay status` output

### Changed
- `minProtocolVersion` set to 0 for backward compatibility with older iOS clients

## [0.1.9] - 2026-04-15

### Added
- Server-side session name storage with `renameSession` and broadcast to all connected clients
- `sessionCreate(name:)` — clients can now assign a name when creating sessions
- `sessionRename` client message and `sessionRenamed` server broadcast
- `name` field on `SessionInfo` model
- `session_list_all` / `session_list_all_result` wire messages for cross-token session listing
- GitNexus code intelligence config and skills

## [0.1.8] - 2026-04-13

### Added
- Cross-device session attach with `sessionStolen` notification when another device takes a session
- `sessionListAll` message to list sessions across all tokens (enables cross-device attach)

### Fixed
- Robust Claude detection — removed false exit triggers, persisted activity state across detach/reattach
- Cross-device attach — sessions now listed across all tokens instead of only the current token's sessions

## [1.3.1] - 2026-04-16 (iOS)

### Added
- QR code overlay on terminal view for session sharing
- QR code scanner via AVFoundation camera for session attach
- "Scan QR Code" button in attach session sheet
- Deep link handler for `coderelay://` URL scheme
- Session name sync with server (renames broadcast to all clients)
- Configurable keyboard shortcut for speech recording
- Live key capture UI (replaced shortcut pickers with `KeyCaptureView`)
- 10,000-line scrollback buffer (up from default)
- Black terminal chrome and keyboard accessory bar

### Changed
- Migrated `ShortcutModifier` enum to raw modifier flags
- LLM.swift switched from local path to remote Git dependency

### Fixed
- Restore tab activity state after returning from background
- False Claude detection on tab switch caused by scrollback replay
- QR code rendering via CIContext for SwiftUI compatibility
- QR overlay dismisses on session change
- Push activity state on session attach
- Swift 6 Sendable warnings in speech layer silenced
- Guard against empty key string in UIKeyCommand registration
- NSCameraUsageDescription added to Info.plist

## [0.1.7] - 2026-04-12

### Fixed
- Idle detection: escape-only TUI output no longer breaks `claudeIdle` state
- Tab flash visibility in iOS app when Claude awaits input

## [0.1.6] - 2026-04-11

### Added
- Server-side session activity monitoring via `SessionActivityMonitor`
- Push-based `sessionActivity` WebSocket messages broadcast to all connected clients
- Initial activity sync on client attach
- Activity observer registry in `SessionManager`

### Changed
- Claude running/idle detection moved from iOS client to server (monitors PTY output continuously, even for detached sessions)

## [1.3.0] - 2026-04-11 (iOS)

### Added
- Session tab bar with numbered tabs and Claude Code detection
- Tab flash notification when Claude Code awaits user input
- Star Wars, Dune, and Lord of the Rings naming themes for sessions
- Clear-line special key
- Haptic feedback with settings toggle
- Scrollable tab zone in status bar
- Consumes server-pushed activity state for background tab updates

### Changed
- Single-line compact status bar (replaced two-line layout)
- Removed stroke borders from status bar icons
- Reorganized header layout: chevron → servers → sessions → function keys → connectivity → time → tabs → name
- Standardized toolbar icons with capitalized key labels

### Fixed
- Backspace key repeat behavior
- Idle detection tab flash not visible due to state timing

## [1.2.0] - 2026-04-10 (iOS)

### Added
- On-device speech engine using WhisperKit (CoreML/ANE) for transcription
- LLM-based text cleanup via LLM.swift (Metal GPU)
- Cloud prompt enhancement via Anthropic Haiku (`CloudPromptEnhancer`)
- Settings page with Prompt Improvement toggle
- Model download manager with progress UI
- Silence hallucination filtering for Whisper
- Speech pipeline: `AudioCaptureSession`, `WhisperTranscriber`, `TextCleaner`, `OnDeviceSpeechEngine`, `SpeechModelStore`

### Changed
- Replaced `SFSpeechRecognizer` with WhisperKit for fully offline speech-to-text
- Model loading shows modal progress bar instead of hourglass

### Removed
- `SpeechRecognizer` (replaced by `OnDeviceSpeechEngine`)

## [1.1.0] - 2026-03-28 (iOS)

### Added
- Hardware keyboard support: Cmd+C (copy), Cmd+V (paste), Cmd+X (cut)
- App version display on splash screen

## [1.0.0] - 2026-03-27 (iOS)

### Added
- Server list with status indicators and swipe actions (edit/delete)
- Add/edit server modal configuration
- Terminal emulation via SwiftTerm
- Session sidebar with named sessions
- Speech-to-text input via SFSpeechRecognizer
- Splash screen with animated logo
- Auto-reconnection and session resume on foreground return
- Session uptime display in toolbar
- Fn key toolbar with special keys
- Hardware keyboard detection (auto-hide software keyboard toggle)

## [0.1.5] - 2026-03-29

### Added
- TLS support for WebSocket server via NIO-SSL (`tlsCert`/`tlsKey` config)
- Server-side config validation (port ranges, scrollback size, log levels)
- `UnsafeTransfer` helper for NIO ↔ Swift concurrency bridging
- `ConfigValue.infer(from:)` for CLI config type coercion
- `ConfigValidationTests` — 11 tests exercising `AdminRoutes.applyConfigValue`
- TLS server tests (cert/key loading, plain fallback)

### Changed
- `WebSocketServer` now accepts `RelayConfig` instead of just a port
- `PTYSession.startReading()` separated from `init` for Swift 6 actor isolation
- `RelayMessageHandler` and `AdminHTTPHandler` use `[weak self]` + `UnsafeTransfer` pattern
- Refactored connection flow: removed intermediate detail view
- Updated stale markdown documentation

### Fixed
- Reduced spurious timeout alerts during active terminal sessions
- Flattened connection flow — tap server to connect directly
- NIO buffer binding mutability (`var` → `let` for `frameData`, `data`)
- Trailing comma lint issue in `ActiveTerminalView.swift`

### Removed
- `AGENTS.md` (stale Codex-branded duplicate of CLAUDE.md)
- `REVIEW.md` (findings tracked, no longer needed)
- Duplicate `UnsafeTransfer` definitions (consolidated to single file)

## [0.1.4] - 2026-03-26

### Added
- Server management redesign: `ServerListView` as primary screen
- `AddEditServerView` modal for server configuration
- Unique default session names

### Changed
- Replaced `ConnectionView` with `ServerListView` entry point
- Match saved connections by UUID instead of host+port

### Removed
- Quick Connect feature (superseded by server list)

## [0.1.3] - 2026-03-24

### Fixed
- Filter escape sequence responses from scrollback on session resume

## [0.1.2] - 2026-03-23

### Fixed
- Use login shell for proper folder permissions

## [0.1.1] - 2026-03-22

### Added
- Full user folder permissions for launchd service
- README and MIT License

## [0.1.0] - 2026-03-21

Initial release.

### Added
- WebSocket relay server (NIO-based, port 9200)
- Admin HTTP API (port 9100, localhost-only)
- Token-based authentication with SHA-256 hashing
- PTY session management with `forkpty` via CPTYShim
- Session persistence: detach, reattach, scrollback replay
- CLI tool (`claude-relay`) with service/token/session/config/log commands
- iOS app with SwiftUI terminal emulation (SwiftTerm)
- Speech-to-text microphone input (SFSpeechRecognizer)
- Hardware keyboard support (Cmd+C/V/X)
- Session sidebar with named sessions
- Foreground recovery (reconnect + re-auth on wake)
- Server status indicators and health checks
- IP-based rate limiting on auth failures
- In-memory log store with structured logging
- Token expiry support
- Homebrew formula and GitHub Actions release workflow
- 110 tests across Kit, Server, and CLI targets

### Security
- Token hashing (never stored plaintext)
- WebSocket frame size limits (1MB text, 1MB binary)
- Auth attempt rate limiting (3 per connection)
- SIGCHLD auto-reap to prevent zombie processes
- Channel activity guards before WebSocket writes
- EAGAIN/EINTR handling in PTY write loop
