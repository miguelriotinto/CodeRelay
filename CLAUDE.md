# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
swift build                                    # Build all SPM targets
swift test                                     # Run all tests
swift test --filter ClaudeRelayKitTests        # One test suite
swift test --filter testTokenGeneration        # One test by name
```

**Server management** (always use CLI, never run server binary directly or pkill):
```bash
swift run claude-relay load --ws-port 9200     # Install + start launchd service
swift run claude-relay unload                  # Remove launchd service
swift run claude-relay start|stop|restart      # Manage running service
swift run claude-relay status                  # Check service status
swift run claude-relay health                  # Health check
swift run claude-relay logs show               # View logs
swift run claude-relay token create --port 9100 --label "dev"  # Create auth token
```

Note: Service commands are top-level (`claude-relay stop`), while token/session/config/log commands are grouped (`claude-relay token create`, `claude-relay session list`, etc.).

**iOS app**: Open `ClaudeRelay.xcodeproj` in Xcode, Cmd+R. After changing ClaudeRelayClient, ClaudeRelaySpeech, or ClaudeRelayKit sources, rebuild the iOS app in Xcode to pick up changes.

**Launchd**: Plist at `~/Library/LaunchAgents/com.claude.relay.plist`. The `load` command locates the server binary via a fallback chain: sibling of the CLI binary, `/opt/homebrew/bin/`, `/usr/local/bin/`, `~/.claude-relay/bin/`.

## Release Process

Use `/coderelay-deploy [ios|android|mac|server|all]` to build, publish, and verify; `/coderelay-health` for a read-only "is everything published and running?" check. Those skills own the version-bump trio, the publish targets, and the mandatory verification steps — never claim something is published without running them.

- **The user installs APKs by downloading from GitHub Releases on the phone — the Android device is NOT adb-connected to this machine.** Never assume `adb install` reaches the user's device.

## Architecture

Six SPM targets + iOS app + macOS app (both XcodeGen-managed via `project.yml`):

- **CPTYShim** — C shim for `forkpty` used by PTYSession.
- **ClaudeRelayKit** — Shared library: wire-protocol models, config, and the pluggable `CodingAgent` registry. Used by all other targets.
- **ClaudeRelayServer** — NIO-based server: `WebSocketServer` (port 9200, optional TLS via NIO-SSL) + `AdminHTTPServer` (port 9100, localhost-only). Actor-based (`SessionManager`, `TokenStore`, `PTYSession`). `RelayMessageHandler` holds a **shared static `JSONEncoder`/`JSONDecoder` — a single pair across all connections**.
- **ClaudeRelayCLI** — ArgumentParser CLI (`claude-relay`): token/session/config/service/log management. Talks to the admin HTTP API; `AdminClient` requests timeout at 10 s (127.0.0.1-only).
- **ClaudeRelayClient** — URLSessionWebSocketTask client: transport, session lifecycle, cross-platform coordination, auth. Also hosts the shared UI atoms under `Views/` used by both apps.
- **ClaudeRelaySpeech** — Cross-platform on-device speech pipeline shared by both apps. iOS-only APIs (`AVAudioSession`, `UIApplication` memory-warning observer) are guarded by `#if canImport(UIKit)`; storage paths/keys are `#if os(iOS)`-branched **to preserve existing user downloads**.
- **ClaudeRelayApp/** — iOS SwiftUI app (not in SPM, uses Xcode project). Depends on ClaudeRelayClient + ClaudeRelaySpeech + SwiftTerm.
- **ClaudeRelayMac/** — macOS SwiftUI app (not in SPM, uses Xcode project). Menu-bar persistent, single-window with sidebar + native tab support, full iOS feature parity.

### Wire Protocol

All WebSocket messages use `MessageEnvelope`: `{"type":"<type_string>","payload":{...}}`. The envelope decoder checks `ClientMessage.allTypeStrings` first, then `ServerMessage.allTypeStrings`. **Type strings must be unique across both sets** — the server's session list response uses `"session_list_result"` (not `"session_list"`) to avoid collision with the client's `"session_list"` request.

`ClientMessage` and `ServerMessage` cannot be decoded standalone — they must go through `MessageEnvelope`. Terminal I/O (`input`/`output`) uses raw binary WebSocket frames, not the envelope protocol.

**Protocol versioning**: Client sends `protocolVersion` in `auth_request`; server responds with `protocolVersion` in `auth_success`. `minProtocolVersion` is 0 for backward compatibility with older clients.

**Scrollback replay**: After `session_attached` / `session_resumed`, the server sends ring-buffer scrollback as binary frames, then a `replay_complete` envelope, then `session_activity`, before live PTY output begins. Always emitted, even when the buffer is empty — clients use it as the "you can render now" signal. The client (`TerminalViewModel`) holds incoming bytes in `pendingOutput` while `isReplaying` is true (set by the coordinator before attach/resume) and flushes them in one batch on `endReplay()`. This keeps SwiftTerm's `queuePendingDisplay` coalescing 60 fps frames into a single render, so the user sees the final terminal state instead of watching history scroll past.

### Clipboard Bridging (F11)

Two-way clipboard: device→host was already covered by `paste_image` (base64 PNG → `MacClipboardService`). Host→device is F11: `PTYSession.handleOutput` runs `OSC52Parser` (a pure, tested value type) over the raw PTY stream, decoding OSC 52 clipboard-write sequences (`ESC ] 52 ; <sel> ; <base64> BEL`, or `ESC \` terminator; `?` read-requests are ignored so the device clipboard never leaks into the session; 1 MB decoded cap). A match fires `clipboardHandler`, which `RelayMessageHandler` forwards as a new `clipboard_update` `ServerMessage`. The client (`RelayConnection.onClipboardUpdate` → `SharedSessionCoordinator`) writes it to the device clipboard via the cross-platform `DeviceClipboard` seam (`UIPasteboard`/`NSPasteboard`), **only for the active session** so a background session's copy can't hijack the pasteboard. Any PTY tool that already speaks OSC 52 (tmux, vim, kitty) gets clipboard-to-device sync with no per-tool integration. Host auto-provisioning (the spec's other, "exploratory" F11 half) is intentionally deferred.

### Date Encoding Caveat

The WebSocket server uses default `JSONEncoder` (Double timestamps). The Admin HTTP API uses `.iso8601`. Do not mix encoders between these two paths.

### TLS Support

`WebSocketServer` supports optional TLS via NIO-SSL. When `tlsCert` and `tlsKey` are set in config, an `NIOSSLServerHandler` is inserted at the front of the channel pipeline before HTTP handlers. Without TLS config, the server runs plain WebSocket. TLS minimum version is 1.2.

The iOS/macOS apps scope plaintext `ws://` to RFC1918 / loopback / `.local` / link-local via `NSAllowsLocalNetworking` in Info.plist. Tailscale CGNAT (`100.64/10`), IPv6 ULA, and public hostnames require TLS (`wss://`) — ATS does not support CIDR-based allowlists, so this is enforced by Apple at the platform layer. See README "When TLS is required".

### PTY Sessions

`PTYSession` is an actor that uses `forkpty` via `CPTYShim` to spawn an
interactive zsh login shell. Several non-obvious invariants are load-bearing
here — the `FD_CLOEXEC` master flag, the out-of-actor fd-liveness lock, the
ancestor-path walk, and the **session**-wide reap in `PTYSessionReap.swift`
(`pid ⊂ group ⊂ session`; a group kill misses zsh's job-control groups). See
`Sources/ClaudeRelayServer/CLAUDE.md` before touching any of it.

### Terminal Queries (answered server-side)

Terminal queries in the PTY stream are answered by the server's own
`TerminalScreenModel` and stripped from everything client-bound
(`TerminalQueryFilter`), so no device ever answers one a WebSocket round trip
late and lands the reply as typed text at the prompt. See
`Sources/ClaudeRelayServer/CLAUDE.md`.

### NIO ↔ Swift Concurrency Bridge

`ChannelHandlerContext` is not `Sendable`. To use it inside `Task` blocks, wrap it in `UnsafeTransfer` (defined in `UnsafeTransfer.swift`) and only access `ctx.value` inside `eventLoop.execute { }`. Both `RelayMessageHandler` and `AdminHTTPHandler` use this pattern.

### Config Validation

The accepted port bound lives in exactly one place: `RelayConfig.portRange`
(1024–65535). All three checks below derive from it rather than restating the
literal — `config validate` had drifted to 1–65535 and reported privileged ports
as valid. Note nothing re-checks the range at **startup**: `main.swift` binds
whatever `config.json` holds and dies on the bind error.

Two-layer validation:
- **CLI client-side** (`ConfigSetCommand`): rejects unknown keys, out-of-range ports, invalid log levels, negative `maxSessionsPerToken`, and unreadable `tlsCert`/`tlsKey` paths before shipping to the admin API. The switch matches on `(key, ConfigValue)` pairs, so a **non-numeric** port infers as `.string`, misses the `.int` case, and falls through to the server to reject — client-side type checking is a fast path, not a guarantee.
- **Server-side** (`AdminRoutes.applyConfigValue()`): the authority. Ports must be in `RelayConfig.portRange`, `scrollbackSize` >= 1024, `detachTimeout` >= 0, `maxSessionsPerToken` >= 0, `logLevel` one of trace/debug/info/warning/error; push bools (`pushEnabled`/`pushNotifyOnFinished`/`apnsUseSandbox`) must parse as bool, and `apnsKeyPath`/`fcmServiceAccountPath` must be readable regular files.

`claude-relay config validate` is a third, **narrower and server-dependent**
check: it fetches `/config` over the admin API (so the service must be running)
and verifies only the two ports plus `wsPort != adminPort`. Two deliberate
details:
- A **non-numeric** port is reported as an error rather than skipped. This is defence in depth, not a reachable bug: `/config` encodes a typed `RelayConfig` with `UInt16` ports, so the wire never carries a non-numeric value — though it can still carry an out-of-range one like 80.
- An out-of-range port is still *returned* to the caller, so a `wsPort == adminPort` collision surfaces in the same pass instead of only after the range error is fixed.

The CLI's `ConfigValue.infer(from:)` handles type coercion from string arguments. `ConfigManager.load()` returns `RelayConfig.default` (logging to stderr) when `config.json` is corrupt, so a bad edit never takes launchd down.

### App Architecture (iOS + macOS)

Both apps share `SharedSessionCoordinator` (in ClaudeRelayClient) for session lifecycle, recovery, naming, and ownership. Platform subclasses add only platform-specific glue (e.g., macOS registers `SleepWakeObserver`; iOS uses `scenePhase`).

**iOS: a one-finger swipe is a wheel report while a program tracks the mouse, and
the scroll view's own gesture otherwise.** `RelayTerminalView.mouseModeChanged`
overrides SwiftTerm's (never calling `super`) and swaps its pan for ours. Three
facts make that the fix rather than a preference:

1. Claude Code runs in the **alternate screen buffer** (`CSI ?1049h`), which has
   no scrollback by definition. `contentSize.height` is then `rows * cellHeight`,
   so the `UIScrollView` a `TerminalView` *is* has nothing to scroll and a swipe
   only rubber-bands. The viewport was never the thing that moves — the agent's
   own transcript is.
2. What the agent listens for is a **wheel report** (buttons 4/5, SGR-encoded
   under `CSI ?1006h`). macOS's `scrollWheel` already sends these, which is why
   the Mac app scrolls the same session fine; iOS has no wheel event source, so
   nothing ever sent one. Verified against a live `claude` in a probe PTY: SGR
   wheel moves the transcript, X10 encoding / PageUp / shift+PageUp do not.
3. SwiftTerm's own `mouseModeChanged` installs a pan reporting the drag as
   press → motion → release. #586 (in the 1.13 → 1.15 bump) changed iOS drags
   from button 1 to button 0, turning that into a *selection* drag — a swipe
   highlighted text and the agent answered "copied 393 characters to clipboard".

So `sendWheel(travel:at:)` banks sub-row finger travel and emits whole notches at
the cell under the finger, and the pan is armed **only** while `mouseMode != .off`
— a disabled recognizer never enters the gesture graph, so in a plain shell the
`require(toFail:)` costs the real local scrollback nothing. Two traps: do not
"simplify" this to `allowMouseReporting = false` (the tap handlers consult that
flag separately and a tap is a click the user wants sent), and do not port macOS's
alt-buffer arrow-key fallback using a "nothing to scroll locally" proxy — that
predicate is also true for an empty *normal* buffer, where it would send arrow
keys to zsh and recall shell history.

`gestureRecognizerShouldBegin` is `UIView`'s hook, not the delegate's; the two
share a selector and `UIScrollView` implements it for its own pan, so every other
recognizer must fall through to `super`. Android's termlib engine takes input only
from the keyboard and has no mouse path at all, so it still has gap (1). Guarded
by `ClaudeRelayAppTests/TerminalSwipeScrollTests`.

### Connection Health & Quality Monitoring

`RelayConnection` maintains connection health via application-level ping/pong (`ClientMessage.ping` → `ServerMessage.pong`) on a 10-second interval. This exercises the full JSON message path rather than relying on WebSocket-level pings (opcode 0x9), which are silently dropped by some network configurations.

- **RTT tracking**: Sliding window of 6 measurements → `ConnectionQuality` enum (excellent/good/poor/veryPoor/disconnected) based on median RTT + success rate. All RTT append + window-cap + failure-counter bookkeeping is centralized in the private `recordRTT` helper — every call site is guaranteed to enforce the cap
- **Death detection**: 3 consecutive ping failures triggers `onSendFailed`, which the coordinator handles via `handleForegroundTransition`
- **Recovery ownership**: Only the coordinator (`SharedSessionCoordinator`) drives recovery. `forceReconnect()` deliberately does NOT enable auto-reconnect to prevent competing recovery loops
- **Recovery defer idempotency**: `handleForegroundTransition` uses a single outer `defer` guarded by `if isRecovering`. A mid-flight cancellation at any `await` (e.g., inside backoff sleep) still clears `isRecovering`, `suppressAllViewModelSends`, and `lastRecoveryEndedAt`. Without this, a cancelled recovery could strand `isRecovering=true` and permanently block future recoveries
- **Alive short-circuit**: If the connection is already alive when foreground fires (scenePhase `.active`, rotation, notification), transition skips the recovery path entirely and only calls `fetchSessions()`
- **Pong routing**: Pongs are intercepted via a dedicated `pendingPongContinuation` in `handleWebSocketMessage`, not through `onServerMessage`, so they don't conflict with `SessionController.sendAndWaitForResponse`

### Server-Side Activity Monitoring

The server monitors all PTY output continuously (even for detached sessions) via
`SessionActivityMonitor`, pushing `sessionActivity` messages to clients. See
`Sources/ClaudeRelayServer/CLAUDE.md` for the poll-cadence invariants and the
hook-based state authority (F6).

### Observer Cleanup (Server)

`SessionManager`'s observer dictionaries (`stateObservers`, `activityObservers`) are normally cleaned by `cleanupSession()`. A background task in `main.swift` purges entries older than 1 h every 30 min as a safety net for handlers that die without cleanup (crash, panic, network partition). Without this, observer entries grew unbounded.

### Graceful Shutdown

`main.swift` races `sessionManager.shutdown()` against a 10 s timer and force-exits with a log line on timeout rather than hanging on a stuck PTY. Final `wsServer`/`adminServer`/`eventLoopGroup` teardown uses `try?` so timeouts propagate to exit. `TokenStore.flushIfDirty()` cancels its 30 s sleep-then-flush task up-front (before writing) to avoid leaving a dangling Task after shutdown.

### Memory Bounds

Named caps across the stack:
- `RelayMessageHandler.maxInflightOutputBytes` — 2 MB inflight WebSocket-write per session (backpressure)
- `RelayMessageHandler.maxTextFrameSize` / `maxBinaryFrameSize` — 10 MB each (images are base64-in-JSON)
- `RingBuffer` — `scrollbackSize` bytes (config, default 512 KB)
- `PTYSession` pending-write queue — 4 MB
- `TerminalScreenModel.maxResponseBytesPerFeed` — 4 KB of terminal-query answers per PTY read (so a query flood can't evict real keystrokes from the queue above)
- `RateLimiter.maxTrackedIPs` — 10 k (LRU-evicts oldest 10 % on overflow). Bounds how many IPs are tracked; `recordFailure` separately retains only the `maxAttempts` most recent timestamps **per** IP, dropping the oldest so the window still slides forward with a sustained attack. Without that second bound one IP failing in a loop grows its array for the whole window, and `cleanup`'s `removeFirst()` is O(n²) in that length — on an actor every other caller serializes behind
- `LogStore` — compacts at 5 % overshoot above `maxEntries` (not +1000)
- `AdminHTTPServer.maxRequestBodyBytes` — 64 KB (returns 413)
- `TerminalViewModel.pendingOutputByteLimit` — 4 MB client-side (logs once-per-session on first drop)
- `AudioCaptureSession.maximumDuration` — 300 s (5 min) auto-stop to cap `Float`-sample memory growth
- `SharedSessionCoordinator` terminal-cache — LRU-bounded at 8 sessions
- `PushRegistrationStore` — `maxPerToken` (20) + `maxTotal` (5 k) registrations, TTL-reaped (90 d), atomic `0o600` write
- `PushDispatcher` — `previousSessionState`/`lastRevision` capped at 4 k sessions, debounce map at 2 k groups (age-reaped)
- `PushHTTP` — 64 KB response-body cap, 10 s request timeout, ≤2 retries; APNs/FCM provider-token caches ~50/55 min
- `RelayMessageHandler.maxPushMutations` — 20 registration mutations per connection (abuse bound)

### Push Notifications

Off by default (`pushEnabled=false`); device tokens are still accepted + stored so enabling later needs no reconnect. Pipeline: client `register_push_token` (platform/token/deviceId + per-device `enabled`/`notifyOnFinished`) → `RelayMessageHandler` (validated, rate-limited) → `PushRegistrationStore` (per-relay-token, capped, TTL-reaped, `0o600`) → a **global** `SessionManager` activity observer → `PushDispatcher`. The dispatcher does **per-session ordered edge detection**: `ActivityEvent`s carry the state at the edge and flow through an `AsyncStream` (single consumer), with a per-session revision guard, so a fast `working→blocked→idle` burst never loses the blocked edge and one session finishing fires even when a sibling stays `working`. It coalesces one push per `(token, workspace-group)` (debounced), keyed on a **hashed** collapse id (`ws_<sha256-prefix>` — never the raw host path), body/deep-link derived from the F2 rollup. Delivery: `APNsClient` (ES256 JWT/HTTP2, `Crypto`) and `FCMClient` (service-account RS256 → OAuth v1, `_CryptoExtras`) via the bounded/retrying `PushHTTP` (`AsyncHTTPClient`); a 410/`UNREGISTERED` result purges the dead token. Clients decide register-vs-update-vs-unregister via the shared `PushRegistrationController` (Swift + Kotlin) and send on connect / token rotation / settings change; taps route a `coderelay://session/<uuid>` deep link.

**Human/portal setup (required for real delivery):**
- **iOS/macOS:** enable the Push Notifications capability on the App ID in the Apple Developer portal (the `aps-environment` entitlement is already in `project.yml`/`.entitlements`; a signed build fails without the capability on the profile). Upload an APNs auth key (`.p8`) and set `apnsKeyPath/apnsKeyId/apnsTeamId/apnsBundleId` (+ `apnsUseSandbox` for dev).
- **Android:** shipped. `google-services.json` is tracked in `ClaudeRelayAndroid/app/`, the `com.google.gms.google-services` plugin is applied (`app/build.gradle.kts`), `RelayFirebaseMessagingService` is registered in `AndroidManifest.xml`, and `POST_NOTIFICATIONS` is requested at runtime (API 33+). Note the Gradle plugin *requires* the JSON — removing it breaks the build. Server side: set `fcmServiceAccountPath` + `fcmProjectId`.
- Secrets (`.p8`, service-account JSON) are server-only, never logged (`PushHTTP.redact` strips `bearer` tokens); device push tokens persist `0o600`.

### Key Pattern: sendAndWaitForResponse

`SessionController.sendAndWaitForResponse()` installs a response handler **before** sending the message (not after) to avoid a race condition where the server response arrives before the handler is in place.

**Corollary — a fire-and-forget request must never be answered with `.error`.**
Replies carry no request ids, so a waiter can only correlate on the response
*type*, and `error` is a legal reply to every request: every waiter's match set is
`expected ∪ {"error"}`. An `.error` produced by a request nobody is awaiting
therefore resolves whichever RPC is in flight, and that waiter cannot reject it.
`resize`/`refresh`/`paste_image` and binary terminal input are all
fire-and-forget, so the server drops them when unattached rather than replying
(`handleResize`/`handleRefresh` log at debug; `paste_image` uses its own
`.pasteImageResult(success: false)` — the rule is about the reply *type*, not
about staying silent). `detach` keeps its `.error(400, "No session attached")`: it
has a real waiter. Full rationale at the top of
`Sources/ClaudeRelayServer/Network/SessionRequestHandlers.swift`.

Clients enforce the same thing from the other end, for servers that predate the
above: `SessionController.isForeignError` (Swift + Kotlin) refuses to let an
`.error` whose message is exactly `"No session attached"` resolve any waiter
other than `detach`'s. Deliberately one exact string — dropping anything
*unrecognized* would hang the waiter to its 10 s timeout, and a timeout poisons
the socket (`desyncedGeneration`), which is worse than surfacing a wrong error.

### Speech Layer Concurrency

`TextCleaner` is `@MainActor`-isolated (not `@unchecked Sendable`). All real callers (`OnDeviceSpeechEngine`, `ClaudeRelayApp.preloadSpeechModels`, macOS `AppDelegate.applicationWillTerminate`) are or must be main-actor-isolated. This enforces "no concurrent `clean()`/`unload()`" at compile time instead of by convention.

`CloudPromptEnhancer` takes an optional `modelId` at init (defaults to the current Haiku inference profile; override for newer models). Error bodies are JSON-parsed for clean messages, and free-form bodies have `Bearer <token>` redacted before logging.

### Continuous Listening Pipeline

Always-on listening with a wake word, parallel to the push-to-talk
`OnDeviceSpeechEngine`. See `Sources/ClaudeRelaySpeech/CLAUDE.md` for the state
machine, the detector cascade, and the strict two-phase UX contract.

## Configuration

Config stored in `~/.claude-relay/config.json`. Default ports: WS=9200, Admin=9100. On this dev machine, admin port is configured as 9100.

**Config keys**: `wsPort`, `adminPort`, `detachTimeout`, `scrollbackSize`, `tlsCert`, `tlsKey`, `logLevel`, `maxSessionsPerToken` (default 50, 0 = unlimited), `bindAll` (default `true` — WebSocket server binds `0.0.0.0` and accepts connections from any interface. Set `false` to restrict to `127.0.0.1`. When `true` without TLS, startup logs a warning because tokens travel in the clear). **Push (all off/nil by default):** `pushEnabled`, `pushNotifyOnFinished` (server-wide default; per-device pref overrides), `apnsKeyPath`/`apnsKeyId`/`apnsTeamId`/`apnsBundleId`/`apnsUseSandbox`, `fcmServiceAccountPath`/`fcmProjectId`. See "Push Notifications" above.

App-side (not in `config.json`, stored via `@AppStorage`): `terminalScrollbackLines` (per-app, default 5000, max 25000). The server's `RingBuffer` still replays anything that falls off this edge on reattach. Continuous-listening settings persisted via `@AppStorage` are the on/off toggle and the wake word — `turnEndSilenceTimeout` is **not** user-tunable (defaults from `SpeechProcessingOptions`).

## Device Pairing (F11, second half)

This is the second, previously-deferred half of the F11 spec; the first half (Clipboard Bridging via OSC 52) shipped earlier and is documented above.

`claude-relay setup` mints a **single-use pairing code** (8 chars Crockford
Base32 = 40 bits, 5-minute TTL) via `POST /pair/create` on the localhost-only
admin API, and renders it as a terminal QR encoding
`coderelay://pair?host=&port=&tls=&code=`.

The device redeems it **pre-auth** over the WebSocket: `pair_request` →
`pair_success{token,tokenId,label}` → then the normal `auth_request` with the
minted token, all on one socket inside the existing 10 s auth timer. Pairing
never sets `isAuthenticated`; the client authenticates with the token it just
received, so there is exactly one path to an authenticated connection.

- `PairingCodeStore` is **in-memory and injected with no default parameter** —
  it is constructed once in `main.swift` and shared by the admin route (mint) and
  every `RelayMessageHandler` (redeem). A defaulted parameter would give each
  connection an empty store and no code would ever redeem.
- A bad code is a `RateLimiter.recordFailure(ip:)`, identical to a bad token
  (10 attempts / 60 s as `main.swift` configures it), plus a per-connection cap
  of 3 mirroring `maxAuthAttempts`.
- **The block is checked twice, and the second one is the gate — don't "dedupe"
  it.** `handlerAdded`'s check is only a fast path: `await isBlocked` is a
  suspension point, so a client that pipelines its first frame behind the HTTP
  upgrade has it delivered to `channelRead` before that check can close the
  channel — which handed a blocked IP one free credential check *per
  connection*, on a surface where connections cost nothing. The authoritative
  checks therefore live inside `handleAuth` and `handlePairRequest`, in the same
  async context that validates the credential, with no suspension between the
  verdict and its use. Pairing's runs **before** `redeem` so a blocked caller
  cannot burn a pending single-use code the real device still needs. A
  successful auth calls `reset(ip:)`, clearing the budget. Guarded by
  `RelayMessageHandlerTests` and `PairRequestHandlerTests`.
- The minted token is labeled `"<device> (paired)"` so it is revocable per device,
  unless the operator passed `setup --label`, in which case that label is used
  verbatim. Either way the label is sanitised identically on both paths
  (`AdminRoutes.handlePairCreate` and `RelayMessageHandler.handlePairRequest`):
  control characters and newlines stripped, capped at 60 scalars — a label reaches
  `TokenStore` and the log, so a `\n` in it could forge log lines.
- `PairingURL` + `PairingCode` live in ClaudeRelayKit and are shared with all
  three clients — validation of hostile QR input happens in one tested place.

### Service manager awareness

Two launchd managers can own the server: `homebrew.mxcl.clauderelay` (from
`brew services`) and `com.claude.relay` (from `claude-relay load`). They must
never both exist — both would bind `wsPort`. `ServiceManagerDetector` resolves
the owner and every service command nudges with the correct command instead of
driving the wrong label; `load` refuses to create a second manager unless
`--force` is passed. Before this existed, `start`/`stop`/`restart`/`unload`
failed outright on a Homebrew install while `status`/`health` worked, because
only the latter two go through the admin HTTP API.

<!-- code-review-graph MCP tools -->
## Linux client (`ClaudeRelayLinux/`)

A Compose Desktop (JVM) client for Arch/Omarchy that **compiles the Android
client's Kotlin sources in place** — `core-protocol`, `core-net`,
`core-session`, `terminal`, and the three `feature-*` screen modules are read
from `ClaudeRelayAndroid/` via `srcDirs` (spec AD-2). There is one copy of each
shared file on disk, so an Android-side edit is a Linux build input:
`linux.yml` triggers on both trees, and a shared-screen change must keep both
builds green. Build with `JAVA_HOME` pointing at a JDK 21 (`~/.local/jdk` on
the dev box; not on `PATH`) and `cmake`:

```bash
cd ClaudeRelayLinux && ./gradlew test            # 702 tests, real libvterm
./gradlew :app:run                               # launch against a live relay
./gradlew :app:createDistributable               # the jpackage image the release tars
```

Load-bearing details, each documented at its site:

- **Terminal** is libvterm through termlib's JNI bridge, cloned at a pinned
  commit and patched by `linux-terminal/patches/` (mouse dispatch, bracketed
  paste). The patch tasks declare the files they edit as outputs; without that
  the Kotlin sync after them reports up-to-date on a stale `TerminalNative.kt`.
  `LinuxTerminalEmulator` is a ~400-line emulator, not a port of termlib's
  Android one; callbacks never call back into the native side (deadlock).
- **Mouse rule** (xterm's): the program gets the pointer while `mouseMode != 0`
  unless Shift is held; otherwise clicks select, middle-click pastes PRIMARY,
  and the wheel scrolls the local scrollback. The alternate screen has no
  scrollback, so an agent transcript scrolls by wheel report only.
- **Accelerators are Ctrl+Shift / Ctrl+Alt only** — a bare Ctrl chord is
  terminal input. Dispatched at the `Window` (`onPreviewKeyEvent`) so they work
  with the sidebar focused.
- **Everything the shared `WorkspaceScreen` cannot pass to the terminal host
  arrives ambiently**: `LocalTerminalTheme` (palette) and `LocalTerminalHooks`
  (clipboard, title, paste, zoom, scrollback size), provided once by `Main.kt`.
- **No push provider** (AD-4): notifications come from the coordinator's
  `agentStates` stream via `notify-send`, off the AWT thread, with
  click-to-focus through `--action`.
- **One instance per user session**: `SingleInstance` binds a Unix socket in
  `$XDG_RUNTIME_DIR`; a second launch forwards argv and exits.
- **Secrets** go to the Secret Service via `secret-tool` on stdin; there is no
  plaintext fallback by design.

## MCP Tools: code-review-graph

**IMPORTANT: This project has a knowledge graph. ALWAYS use the
code-review-graph MCP tools BEFORE using Grep/Glob/Read to explore
the codebase.** The graph is faster, cheaper (fewer tokens), and gives
you structural context (callers, dependents, test coverage) that file
scanning cannot.

### When to use graph tools FIRST

- **Exploring code**: `semantic_search_nodes` or `query_graph` instead of Grep
- **Understanding impact**: `get_impact_radius` instead of manually tracing imports
- **Code review**: `detect_changes` + `get_review_context` instead of reading entire files
- **Finding relationships**: `query_graph` with callers_of/callees_of/imports_of/tests_for
- **Architecture questions**: `get_architecture_overview` + `list_communities`

Fall back to Grep/Glob/Read **only** when the graph doesn't cover what you need.

The graph auto-updates on file changes (via a PostToolUse hook).
