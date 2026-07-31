# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
swift build                        # Build all SPM targets
swift test                         # Run all tests
swift test --filter ClaudeRelayKitTests        # Run a single test suite
swift test --filter testTokenGeneration        # Run a single test by name
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

Use `/coderelay-deploy [ios|android|mac|server|all]` to build, publish, and verify; `/coderelay-health` for a read-only "is everything published and running?" check.

**Version bump trio** (bump only what ships):
- iOS/macOS: build number in `project.yml`, then regenerate with `xcodegen`.
- Android: `versionCode` + `versionName` in `ClaudeRelayAndroid/app/build.gradle.kts`. Milestone naming: `0.3-mNN` (versionCode increments by 1 per milestone).
- Server: version constant + `Formula/clauderelay.rb` (Homebrew builds from HEAD; the Cellar dir name `HEAD-<commit>` encodes the built commit).
- Release commit message: `chore(release): server X.Y.Z, iOS build NNN, Android 0.3-mNN (versionCode NN)` — adjust to what shipped.

**Publish targets**:
- iOS/macOS → TestFlight via `xcodebuild archive` + `-exportArchive` with `build/ExportOptions.plist` (destination=upload). Success is proven by `UPLOAD SUCCEEDED` in `$TMPDIR/<AppName>_*.xcdistributionlogs/ContentDelivery.log` — Apple-side processing takes up to ~1 h after that.
- Android → GitHub Releases as a **pre-release** tagged `android-v<versionName>` with asset `CodeRelay-<versionName>.apk`. Main `vX.Y.Z` releases carry no binaries (server ships via Homebrew).
- **The user installs APKs by downloading from GitHub Releases on the phone — the Android device is NOT adb-connected to this machine.** Never assume `adb install` reaches the user's device.

**Verification is mandatory**: download the APK back from the release and check `aapt2 dump badging` versionCode (byte size is not proof); grep the ContentDelivery log for iOS; `claude-relay status` + `/health` for the server.

## Architecture

Six SPM targets + iOS app + macOS app (both XcodeGen-managed via `project.yml`):

- **CPTYShim** — C shim for `forkpty` used by PTYSession.
- **ClaudeRelayKit** — Shared library: protocol models (`ClientMessage`, `ServerMessage`, `MessageEnvelope`), `SessionInfo`, `TokenInfo`, `RelayConfig`, `ConfigManager`, `ConnectionQuality`, `ActivityState`, `SessionState`, `CodingAgent` (pluggable agent registry). Used by all other targets.
- **ClaudeRelayServer** — NIO-based server: `WebSocketServer` (port 9200, optional TLS via NIO-SSL) + `AdminHTTPServer` (port 9100, localhost-only, 64 KB body cap → 413). Uses actors: `SessionManager`, `TokenStore`, `PTYSession`. Rate-limited via `RateLimiter` actor (LRU-capped at 10 k IPs). Shared static `JSONEncoder`/`JSONDecoder` in `RelayMessageHandler` (single pair across all connections).
- **ClaudeRelayCLI** — ArgumentParser CLI (`claude-relay`): token/session/config/service/log management. Talks to admin HTTP API. `AdminClient` requests timeout at 10 s (127.0.0.1-only).
- **ClaudeRelayClient** — URLSessionWebSocketTask client: `RelayConnection` (WebSocket transport + connection quality monitoring), `SessionController` (session lifecycle), `SharedSessionCoordinator` (cross-platform coordinator with recovery), `AuthManager` (auth flow). Also hosts `SessionCoordinating` protocol, `SessionNaming` helpers, `NetworkMonitor`, `DeviceIdentifier`, `ConnectionConfig`, and shared UI atoms (`ConnectionQualityDot`, `ActivityDot`, `AgentColorPalette` under `Views/`) used by both apps.
- **ClaudeRelaySpeech** — Cross-platform on-device speech pipeline shared by both apps: `OnDeviceSpeechEngine`, `WhisperTranscriber` (WhisperKit), `TextCleaner` (LLM.swift), `CloudPromptEnhancer` (Bedrock Haiku), `AudioCaptureSession`, `SpeechModelStore`, `SpeechEngineState`. iOS-only APIs (`AVAudioSession`, `UIApplication` memory-warning observer) are guarded by `#if canImport(UIKit)`; storage paths/keys are `#if os(iOS)`-branched to preserve existing user downloads.
- **ClaudeRelayApp/** — iOS SwiftUI app (not in SPM, uses Xcode project). Depends on ClaudeRelayClient + ClaudeRelaySpeech + SwiftTerm.
- **ClaudeRelayMac/** — macOS SwiftUI app (not in SPM, uses Xcode project). Depends on ClaudeRelayClient + ClaudeRelaySpeech + SwiftTerm. Menu-bar persistent, single-window with sidebar + native tab support, full iOS feature parity.

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

`PTYSession` is an actor that uses `forkpty` via the C shim (`CPTYShim`) to spawn an interactive zsh login shell. Output goes to a `RingBuffer` for session resume scrollback (zero-copy writes via `withUnsafeMutableBytes`). Sessions never expire by default (`detachTimeout=0`).

**Two-phase init**: `PTYSession.init()` creates the PTY but does not start reading. Call `startReading()` after init to activate the dispatch source (required for Swift 6 actor-initializer isolation).

**Non-blocking writes**: The master FD is set to `O_NONBLOCK`. A `DispatchSourceWrite` drains a 4 MB pending queue when the FD becomes writable. Overflow drops oldest bytes with a once-per-session warning. This prevents paste/rapid-input workloads from EAGAIN-spinning inside the actor and starving resize/output dispatch.

**Output backpressure**: `RelayMessageHandler` caps inflight WebSocket-write bytes per session at 2 MB (`maxInflightOutputBytes`). When the cap is hit the server skips frames until writes drain — the `RingBuffer` holds the authoritative copy and clients replay from it on resume.

**Per-token session cap**: `SessionManager.createSession` enforces `config.maxSessionsPerToken` (default 50, 0 = unlimited) and throws `SessionError.sessionLimitExceeded` when exceeded. Prevents runaway clients from fork-bombing the server.

### NIO ↔ Swift Concurrency Bridge

`ChannelHandlerContext` is not `Sendable`. To use it inside `Task` blocks, wrap it in `UnsafeTransfer` (defined in `UnsafeTransfer.swift`) and only access `ctx.value` inside `eventLoop.execute { }`. Both `RelayMessageHandler` and `AdminHTTPHandler` use this pattern.

### Config Validation

Two-layer validation:
- **CLI client-side** (`ConfigSetCommand`): rejects unknown keys, bad port ranges, non-numeric values, invalid log levels, and negative `maxSessionsPerToken` before shipping to the admin API. `claude-relay config validate` runs the same checks against the saved file without touching the server.
- **Server-side** (`AdminRoutes.applyConfigValue()`): ports must be 1024–65535, `scrollbackSize` >= 1024, `detachTimeout` >= 0, `maxSessionsPerToken` >= 0, `logLevel` one of trace/debug/info/warning/error; push bools (`pushEnabled`/`pushNotifyOnFinished`/`apnsUseSandbox`) must parse as bool, and `apnsKeyPath`/`fcmServiceAccountPath` must be readable regular files.

The CLI's `ConfigValue.infer(from:)` handles type coercion from string arguments. `ConfigManager.load()` returns `RelayConfig.default` (logging to stderr) when `config.json` is corrupt, so a bad edit never takes launchd down.

### App Architecture (iOS + macOS)

Both apps share `SharedSessionCoordinator` (in ClaudeRelayClient) for session lifecycle, recovery, naming, and ownership. Platform subclasses add only platform-specific glue (e.g., macOS registers `SleepWakeObserver`; iOS uses `scenePhase`).

- **ServerListView** — Primary screen: tap/click server to connect, swipe/right-click for edit/delete
- **AddEditServerView** — Modal sheet for server configuration (add/edit modes, with delete)
- **WorkspaceView** (iOS) / **MainWindow** (macOS) — NavigationSplitView: sidebar (sessions) + detail (terminal)
- **SharedSessionCoordinator** — Cross-platform: manages auth, session lifecycle, caches TerminalViewModels, routes I/O, handles recovery
- **SessionCoordinator** (per platform) — Thin subclass: iOS uses default; macOS adds sleep/wake recovery and tab navigation
- **OnDeviceSpeechEngine** — Offline speech-to-text via WhisperKit (CoreML/ANE), with LLM-based text cleanup and optional cloud prompt enhancement via Anthropic Haiku

### Connection Health & Quality Monitoring

`RelayConnection` maintains connection health via application-level ping/pong (`ClientMessage.ping` → `ServerMessage.pong`) on a 10-second interval. This exercises the full JSON message path rather than relying on WebSocket-level pings (opcode 0x9), which are silently dropped by some network configurations.

- **RTT tracking**: Sliding window of 6 measurements → `ConnectionQuality` enum (excellent/good/poor/veryPoor/disconnected) based on median RTT + success rate. All RTT append + window-cap + failure-counter bookkeeping is centralized in the private `recordRTT` helper — every call site is guaranteed to enforce the cap
- **Death detection**: 3 consecutive ping failures triggers `onSendFailed`, which the coordinator handles via `handleForegroundTransition`
- **Recovery ownership**: Only the coordinator (`SharedSessionCoordinator`) drives recovery. `forceReconnect()` deliberately does NOT enable auto-reconnect to prevent competing recovery loops
- **Recovery defer idempotency**: `handleForegroundTransition` uses a single outer `defer` guarded by `if isRecovering`. A mid-flight cancellation at any `await` (e.g., inside backoff sleep) still clears `isRecovering`, `suppressAllViewModelSends`, and `lastRecoveryEndedAt`. Without this, a cancelled recovery could strand `isRecovering=true` and permanently block future recoveries
- **Alive short-circuit**: If the connection is already alive when foreground fires (scenePhase `.active`, rotation, notification), transition skips the recovery path entirely and only calls `fetchSessions()`
- **Pong routing**: Pongs are intercepted via a dedicated `pendingPongContinuation` in `handleWebSocketMessage`, not through `onServerMessage`, so they don't conflict with `SessionController.sendAndWaitForResponse`

### Server-Side Activity Monitoring

The server monitors all PTY output continuously (even for detached sessions) via `SessionActivityMonitor`. It detects coding agent entry/exit and output silence, maintaining an `ActivityState` per session. Agents are identified via the `CodingAgent` registry (process-name matching + OSC title keywords); currently ships with Claude Code and Codex. State changes are pushed to clients via `sessionActivity` WebSocket messages. This ensures background tabs correctly reflect agent running/idle state even when the client is attached to a different session.

**Performance**: The foreground-process poll runs at 2 s when an agent is active and slows to 5 s when the session is detached. ANSI regex processing is skipped on the hot output path when no agent is running. `CodingAgent.processNames` is pre-lowercased at init so polling doesn't re-allocate strings on every tick.

**Hook-based state authority (F6)**: An optional local Claude Code hook can report authoritative lifecycle state, overriding screen detection while fresh. `PTYSession` injects `CLAUDE_RELAY_SESSION_ID` + `CLAUDE_RELAY_ADMIN_PORT` into each session's shell env (admin port threaded through the default `PTYFactory` closure; the `PTYFactory` typealias is unchanged so test mocks are unaffected). The shipped hook (`Scripts/hooks/claude-relay-state-hook.sh`) POSTs `{sessionId, state}` to the localhost-only `POST /hook/state` admin route → `SessionManager.reportHookState` → `SessionActivityMonitor.applyHookState`. Hook state is trusted for a 10 s TTL (`hookStateTTL`); `updateScreenDetection` no-ops while a fresh hook state exists, then screen detection resumes automatically when it goes stale. The hook reports **state only** — agent *identity* stays owned by the foreground poll, so a hook can never assert or evict an agent. With no hook installed, behavior is identical to screen-detection-only. Install docs: `Scripts/hooks/README.md`.

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
- `RateLimiter.maxTrackedIPs` — 10 k (LRU-evicts oldest 10 % on overflow)
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

Off by default (`pushEnabled=false`); device tokens are still accepted + stored so enabling later needs no reconnect. Pipeline: client `register_push_token` (platform/token/deviceId + per-device `enabled`/`notifyOnFinished`) → `RelayMessageHandler` (validated, rate-limited) → `PushRegistrationStore` (per-relay-token, capped, TTL-reaped, `0o600`) → a **global** `SessionManager` activity observer → `PushDispatcher`. The dispatcher does **per-session ordered edge detection**: `ActivityEvent`s carry the state at the edge and flow through an `AsyncStream` (single consumer), with a per-session revision guard, so a fast `working→blocked→idle` burst never loses the blocked edge and one session finishing fires even when a sibling stays `working`. It coalesces one push per `(token, workspace-group)` (debounced), keyed on a **hashed** collapse id (`ws_<sha256-prefix>` — never the raw host path), body/deep-link derived from the F2 rollup. Delivery: `APNsClient` (ES256 JWT/HTTP2, `Crypto`) and `FCMClient` (service-account RS256 → OAuth v1, `_CryptoExtras`) via the bounded/retrying `PushHTTP` (`AsyncHTTPClient`); a 410/`UNREGISTERED` result purges the dead token. Clients decide register-vs-update-vs-unregister via the shared `PushRegistrationController` (Swift + Kotlin) and send on connect / token rotation / settings change; taps route a `clauderelay://session/<uuid>` deep link.

**Human/portal setup (required for real delivery):**
- **iOS/macOS:** enable the Push Notifications capability on the App ID in the Apple Developer portal (the `aps-environment` entitlement is already in `project.yml`/`.entitlements`; a signed build fails without the capability on the profile). Upload an APNs auth key (`.p8`) and set `apnsKeyPath/apnsKeyId/apnsTeamId/apnsBundleId` (+ `apnsUseSandbox` for dev).
- **Android (deferred):** create a Firebase project, add `google-services.json` + the `com.google.gms.google-services` Gradle plugin + `firebase-messaging`, an FCM service, a notification channel, and the `POST_NOTIFICATIONS` runtime permission. The wire messages + `PushRegistrationController` exist; the messaging service is gated on that Firebase config (adding the plugin without the JSON breaks the Gradle build). Server side: set `fcmServiceAccountPath` + `fcmProjectId`.
- Secrets (`.p8`, service-account JSON) are server-only, never logged (`PushHTTP.redact` strips `bearer` tokens); device push tokens persist `0o600`.

### Key Pattern: sendAndWaitForResponse

`SessionController.sendAndWaitForResponse()` installs a response handler **before** sending the message (not after) to avoid a race condition where the server response arrives before the handler is in place.

### Speech Layer Concurrency

`TextCleaner` is `@MainActor`-isolated (not `@unchecked Sendable`). All real callers (`OnDeviceSpeechEngine`, `ClaudeRelayApp.preloadSpeechModels`, macOS `AppDelegate.applicationWillTerminate`) are or must be main-actor-isolated. This enforces "no concurrent `clean()`/`unload()`" at compile time instead of by convention.

`CloudPromptEnhancer` takes an optional `modelId` at init (defaults to the current Haiku inference profile; override for newer models). Error bodies are JSON-parsed for clean messages, and free-form bodies have `Bearer <token>` redacted before logging.

### Continuous Listening Pipeline

`ContinuousListeningEngine` is a parallel orchestrator to `OnDeviceSpeechEngine`
powering always-on listening with a wake word ("Claude" by default). Both
engines delegate post-processing (cleanup plus cloud enhancement) to the shared
`SpeechPostProcessor`, so `smartCleanupEnabled` and `promptEnhancementEnabled`
settings behave identically in push-to-talk and continuous modes.

**Strict two-phase UX.** The user says the wake word, the mic button turns
red to acknowledge, then they speak the command. Combined utterances like
"Claude, list my files" spoken in one breath are rejected — the red-light
handshake is the whole point of the design. An `.armed` state sits between
wake-word detection and command recording, timing out back to `.listening`
after 4 s if the user never starts the command.

State machine:
```
idle → listening (blue) ─ speechStart → detectingWakeWord (blue)
  ↓ (silence + wake-word match with empty residue)
armed (red, 4s timeout) ─ speechStart → recording (red)
  ↓ silenceStart (≥1 s)
detectingTurnEnd (red) ─ classifier: done → transcribing (yellow)
                      └ classifier: continuing → recording
transcribing → cleaning (yellow) → outputting (yellow) → listening
```

UI color buckets: **blue** for `listening`/`detectingWakeWord`, **red** for
`armed`/`recording`/`detectingTurnEnd`, **yellow** for
`transcribing`/`cleaning`/`outputting`.

Pipeline:
1. `StreamingAudioSource` (AVAudioEngine tap) → 16 kHz mono Float32 chunks
2. `StreamingAudioBuffer` (30 s ring, `OSAllocatedUnfairLock`) — zero-copy append
3. `VoiceActivityDetecting` — `SileroVoiceActivityDetector` wraps the bundled
   FluidInference Silero-VAD v6 unified CoreML model (stateful LSTM, 576-sample
   input = 64 context + 512 chunk). Falls back to the energy-based
   `VoiceActivityDetector` if the bundle resource fails to load.
4. On `speechStart` (listening → detectingWakeWord), ~0.5 s of pre-roll is
   fed to `WakeWordDetector` plus ongoing chunks until `silenceStart`
5. `WakeWordDetector.checkForWakeWord()` runs `WakeWordAudioPreprocessor`
   (peak-normalize to ~0.95 + pad to 3 s) before WhisperKit transcription,
   then matches with a cascade: alias table → Levenshtein (≤ 2) →
   Metaphone phonetic equality with first-letter guard
6. If matched with empty residue → `.armed` (red, 4 s). Non-empty residue
   is rejected in strict mode — user must pause before the command
7. `armed → recording` on next `speechStart`; `recording → detectingTurnEnd`
   on `silenceStart`. VAD `minSilenceDuration = 1.0 s` so transient breath
   pauses do not trigger turn-end
8. `TurnEndDetecting` — `SmartTurnTurnEndDetector` bundles Smart-Turn v3
   (Whisper-Tiny encoder + linear head, 8 s zero-padded-from-start context)
   and a Whisper log-mel preprocessor. Falls back to `HeuristicTurnEndDetector`
   if either `.mlpackage` fails to load or compile
9. `raceTurnEnd` returns `TurnEndDecision {done, continuing, inferenceTimedOut}`.
   **The classifier is authoritative.** The timer (`turnEndSilenceTimeout`,
   default 8 s) is a safety net against a hung CoreML prediction — when
   it fires the engine resumes `.recording` rather than forcing transcription
10. On `.done` → Whisper transcription → `SpeechPostProcessor.process(...)`
    → `onUtteranceReady` → `SessionCoordinator.vm.sendInput(text)`

`ContinuousListeningEngine.makeDefault(options:)` constructs the engine with
the best available detectors. `updateOptions(_:)` pushes settings changes
(incl. wake word, which triggers a `WakeWordDetector` rebuild) without
restarting. iOS responds to `AVAudioSession.interruptionNotification` by
pausing; macOS hooks `NSWorkspace.willSleepNotification` /
`didWakeNotification`.

Push-to-talk (`OnDeviceSpeechEngine`) remains as an alternative mode. When
`continuousListeningEnabled` is on: tap the mic to pause/resume; long-press
for a 2-second one-shot PTT capture without disabling continuous mode.

**Foreground-only:** audio engine starts on `scenePhase == .active` (iOS) or
the Settings toggle (macOS). No background audio entitlement is used.

## Configuration

Config stored in `~/.claude-relay/config.json`. Default ports: WS=9200, Admin=9100. On this dev machine, admin port is configured as 9100.

**Config keys**: `wsPort`, `adminPort`, `detachTimeout`, `scrollbackSize`, `tlsCert`, `tlsKey`, `logLevel`, `maxSessionsPerToken` (default 50, 0 = unlimited), `bindAll` (default `true` — WebSocket server binds `0.0.0.0` and accepts connections from any interface. Set `false` to restrict to `127.0.0.1`. When `true` without TLS, startup logs a warning because tokens travel in the clear). **Push (all off/nil by default):** `pushEnabled`, `pushNotifyOnFinished` (server-wide default; per-device pref overrides), `apnsKeyPath`/`apnsKeyId`/`apnsTeamId`/`apnsBundleId`/`apnsUseSandbox`, `fcmServiceAccountPath`/`fcmProjectId`. See "Push Notifications" above.

App-side (not in `config.json`, stored via `@AppStorage`): `terminalScrollbackLines` (per-app, default 5000, max 25000). The server's `RingBuffer` still replays anything that falls off this edge on reattach. Continuous-listening settings persisted via `@AppStorage` are the on/off toggle and the wake word — `turnEndSilenceTimeout` is **not** user-tunable (defaults from `SpeechProcessingOptions`).

## Device Pairing (F11, second half)

This is the second, previously-deferred half of the F11 spec; the first half (Clipboard Bridging via OSC 52) shipped earlier and is documented above.

`claude-relay setup` mints a **single-use pairing code** (8 chars Crockford
Base32 = 40 bits, 5-minute TTL) via `POST /pair/create` on the localhost-only
admin API, and renders it as a terminal QR encoding
`clauderelay://pair?host=&port=&tls=&code=`.

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
- The minted token is labeled `"<device> (paired)"` so it is revocable per device.
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

## Lint

SwiftLint config in `.swiftlint.yml`. Line length warning at 140, error at 200. Identifier min length: 2 (warning).

<!-- code-review-graph MCP tools -->
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

### Key Tools

| Tool | Use when |
|------|----------|
| `detect_changes` | Reviewing code changes — gives risk-scored analysis |
| `get_review_context` | Need source snippets for review — token-efficient |
| `get_impact_radius` | Understanding blast radius of a change |
| `get_affected_flows` | Finding which execution paths are impacted |
| `query_graph` | Tracing callers, callees, imports, tests, dependencies |
| `semantic_search_nodes` | Finding functions/classes by name or keyword |
| `get_architecture_overview` | Understanding high-level codebase structure |
| `refactor_tool` | Planning renames, finding dead code |

### Workflow

1. The graph auto-updates on file changes (via hooks).
2. Use `detect_changes` for code review.
3. Use `get_affected_flows` to understand impact.
4. Use `query_graph` pattern="tests_for" to check coverage.
