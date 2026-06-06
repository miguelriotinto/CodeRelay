# Android Relay Client — Design

**Date:** 2026-06-06
**Status:** Approved (design); pending implementation plan
**Author:** Design session (Claude + Miguel)

## Goal

Build an Android version of Claude Relay with **exact feature parity** to the
iOS app. The macOS server and the WebSocket wire protocol are **frozen** — the
Android app is a pure new *client* that speaks the existing protocol
byte-for-byte. The server remains the single source of truth, exactly as it is
for the iOS and Mac apps. **No server-side changes.**

## Locked Decisions

| Decision | Choice |
|---|---|
| Speech pipeline | **Full on-device parity from day one** (whisper.cpp + Silero-VAD ONNX + SmartTurn v3 converted + llama.cpp cleanup + Bedrock cloud enhance + full wake-word/turn-end state machine) |
| Architecture | **Standalone native Kotlin + Jetpack Compose.** No shared Swift code. The WebSocket protocol is the contract. |
| Targets | **Phone + tablet/foldable**, adaptive layout. Modern minSdk (≈ 26–28). Material 3 + WindowSizeClass. |
| Release | **Phased internal/closed-beta** milestones M1→M4; public launch after parity. |

## Architecture Spine

### Module graph (mirrors the SPM target split 1:1)

```
ClaudeRelayAndroid/
├── :core-protocol     ← Kotlin port of ClaudeRelayKit (models + MessageEnvelope + token gen)
├── :core-net          ← RelayConnection equivalent: OkHttp WS, ping/pong, quality, generation
├── :core-session      ← SharedSessionCoordinator + Recovery + Activity + Auth + ownership stores
├── :core-storage      ← EncryptedSharedPreferences/DataStore (SavedConnection, Ownership, tokens)
├── :terminal          ← Termux terminal-emulator/terminal-view, wrapped + replay protocol
├── :speech            ← whisper.cpp + ONNX (Silero/SmartTurn) + llama.cpp JNI + state machine
├── :feature-servers   ← Compose: server list, add/edit, QR
├── :feature-workspace ← Compose: adaptive split view, terminal host, session sidebar, tabs
├── :feature-settings  ← Compose: settings, keyboard shortcuts
└── :app               ← Application, navigation, deep links, DI wiring (Hilt)
```

### Repository layout (monorepo)

The Android app lives **inside this existing repository**, in a top-level
`ClaudeRelayAndroid/` directory alongside `Sources/`, `ClaudeRelayApp/`, and
`ClaudeRelayMac/` — not in a separate repo. Rationale:

- This repo is already a deliberate multi-platform monorepo (server + CLI +
  iOS + macOS, the latter two being Xcode/XcodeGen projects, not SwiftPM). The
  graph already spans `swift, c, python, bash, ruby`; adding Kotlin/Gradle is
  consistent, not a category change.
- The hardest Android work depends on artifacts that live here: the
  CoreML→ONNX conversion + parity validation (§5, M3/M4) need the bundled
  models in `Sources/ClaudeRelaySpeech/Resources/` and the speech test fixtures
  in `Tests/ClaudeRelaySpeechTests/Fixtures` side-by-side with their ONNX
  outputs. Co-location keeps these as direct file references rather than a
  submodule/copy.
- `protocolVersion` exists because the wire protocol *will* evolve. A monorepo
  lets a protocol change land atomically across server + iOS + macOS + Android
  in one PR, with the contract test (M1) catching drift.
- The spec and plan docs already live in this repo; the code they describe
  belongs alongside them.

`ClaudeRelayAndroid/` has its **own** Gradle build (root `settings.gradle.kts`)
and its **own** CI workflow (a separate GitHub Actions job, not entangled with
the Swift build/test pipeline). Android Studio opens the nested Gradle root
directly. The Swift tooling (`.code-review-graph`, SwiftLint, the launchd/brew
flows) is unaffected — it simply ignores the Kotlin tree.

### Tech stack

| Concern | iOS | Android |
|---|---|---|
| UI | SwiftUI | Jetpack Compose + Material 3, WindowSizeClass adaptive |
| Concurrency | Swift actors / `@MainActor` / async-await | Kotlin Coroutines + StateFlow; main-thread confinement replaces `@MainActor` |
| WebSocket | URLSessionWebSocketTask | OkHttp WebSocket (text + binary frames) |
| JSON | Codable | kotlinx.serialization + custom serializers (envelope, UUID, Date) |
| Secure storage | Keychain | EncryptedSharedPreferences (Tink) + Keystore master key |
| Prefs | UserDefaults / `@AppStorage` | DataStore (tokens in EncryptedSharedPreferences) |
| DI | manual | Hilt |
| Terminal | SwiftTerm | Termux `terminal-view` + `terminal-emulator` (Apache-2.0), wrapped |
| Camera/QR | AVCapture / CoreImage | CameraX + ML Kit barcode (scan), ZXing (generate) |

## Section 2 — Protocol & Networking (`:core-protocol`, `:core-net`)

### Wire contract (reproduce exactly)

- **Envelope:** every control message is `{"type":"<string>","payload":{...}}`.
  `payload` is a nested JSON **object** (never a string). `ping`/`pong`/
  `session_detach`/`session_list` carry an **empty** `payload` object.
- **30 unique type strings** — 12 client, 18 server. Port as
  `sealed interface ClientMessage` / `ServerMessage` with a hand-written
  envelope serializer switching on `type`, plus a single `Map<String, Origin>`
  lookup mirroring `MessageEnvelope.typeOrigin`. Unknown type → throw.
- **Field casing is camelCase** inside payloads (`sessionId`,
  `protocolVersion`, `skipReplay`). The **type strings** are snake_case. Pin
  field names explicitly with `@SerialName` — do **not** auto-snake-case.
- **Optional-field asymmetry:** decode accepts both `null` and *missing*;
  encode **omits** when nil/false. `skipReplay` written only when `true`;
  `protocolVersion`/`name`/`agent` only when non-nil. Implement in custom
  serializers, not via defaults.
- **`ActivityState` backward-compat:** decode accepts legacy
  `claude_active`/`claude_idle` → `agentActive`/`agentIdle`; unknown → `active`
  (never throw). Encode **always** emits modern names. `SessionState` raw
  values are hyphenated (`active-attached`).
- **Types:** `UUID` → canonical lowercase-hyphenated string. `cols`/`rows` →
  `UShort` (JSON number 0–65535).

### CORRECTIONS to the subagent review (verified against source)

1. **`SessionInfo.createdAt` is a `Double` (epoch/reference seconds), NOT
   ISO-8601.** The WebSocket path uses the default `JSONEncoder` (Double
   timestamps); ISO-8601 is only the Admin HTTP API, which the app never
   touches. Write a Double-seconds serializer and verify against a live
   server frame.
2. **Terminal I/O is raw binary WebSocket frames** (both input and output),
   never enveloped. (The review claimed "JSON only / no binary frames" — wrong
   for the WS path.)
3. Add a **contract test** that round-trips a captured real server frame to
   guard both of the above.

### Token generation (`:core-protocol`)

Parity-only (the CLI mints tokens, not the app): `SecureRandom` 32 bytes →
Base64 URL-safe no-padding (43 chars) → SHA-256 hex. Low risk.

### Networking (`:core-net`) — port of `RelayConnection`

- OkHttp `WebSocket` + `WebSocketListener`. `onMessage(String)` → decode
  envelope; `onMessage(ByteString)` → raw terminal output. OkHttp callbacks
  arrive on its dispatcher thread → marshal **every** state mutation onto a
  single confinement dispatcher (`Dispatchers.Main.immediate`) to replicate
  `@MainActor` serial isolation.
- **Application-level ping/pong** (not WS-level): 10 s interval, 5 s pong
  timeout, 6-sample RTT sliding window → `ConnectionQuality`; **3 consecutive
  failures → "dead" → `onSendFailed`**. Pong routed through a dedicated
  single-flight await (`suspendCancellableCoroutine` + `withTimeoutOrNull`),
  mirroring `pendingPongContinuation` + `activePing` dedup.
- **Generation counter** (`Long`): bumped on every (re)connect; stale
  receive-loop / keepalive callbacks compare-and-bail.
- **`sendAndWaitForResponse`:** install the response subscriber **before**
  sending, with a `ResumeGuard`-equivalent so the continuation resumes exactly
  once even if the response beats the await. 10 s timeout.
- Recovery is **not** owned here. `forceReconnect()` reconnects without enabling
  any auto-loop, leaving recovery to the coordinator.

### TLS / cleartext scoping (Android-forced design decision)

iOS ATS `NSAllowsLocalNetworking` lets the **platform** permit `ws://` only to
RFC1918 / loopback / `.local` / link-local, and refuse plaintext to Tailscale
CGNAT (`100.64/10`) / ULA / public (those require `wss://`). **Android's
Network Security Config cannot express CIDR allowlists.** Replicate the policy
in app logic: a `isPrivateNetworkHost(host)` checker mirroring the iOS CIDR
rules, enforced at connect/validation time (reject `ws://` to non-private hosts,
steer to TLS). Keeps the exact iOS security stance without fighting the platform.

## Section 3 — Session Coordination, Recovery & Storage (`:core-session`, `:core-storage`)

iOS `@MainActor ObservableObject`s become a **main-thread-confined coordinator
exposing `StateFlow`s**, owned by a `ViewModel` (survives config changes),
cleanup in `onCleared()`.

### SessionCoordinator (port of `SharedSessionCoordinator`)

Owns: session list, active-session slot, recovery UI state, LRU-8 terminal
cache, and the three sub-controllers. Session ops (`create/switch/attach/
terminate`) follow the exact iOS sequence (detach prev → act → claim → wire
output → set active → `touch` cache → `enforceLimit` → fetch), each wrapped in
`withAuth { }` and guarded by `!isRecovering`. **Eager output wiring:** set the
binary-frame output closure to the active VM **before** `resume` completes.

### RecoveryController (circuit-breaker state machine)

- `recoveryGeneration: Long` captured at entry; every `await` checkpoint
  (backoff, auth, resume) re-checks `myGen == currentGen` and bails if newer.
- **Two distinct guards:** `isRecoveryDispatched` (synchronous entry lock, gates
  scheduling) vs. `isRecovering` (UI flag, gates work). Both as `StateFlow`s.
- **`isAlive()` short-circuit:** before full backoff, probe with a ping (~2 s);
  if alive, skip recovery and just `fetchSessions()`. Makes foreground-after-
  sleep correct.
- **Circuit breaker:** 3 consecutive *auto*-triggered failures →
  `autoRecoverySuspended`; only explicit user signals (foreground /
  network-restored / manual) reset it. Backoff `[0,1,2,4,8,15]s`; final failure
  → `connectionTimedOut`.
- **Defer-idempotency:** a single coroutine `try/finally` clears `isRecovering`
  + send-suppression + `lastRecoveryEndedAt` even if cancelled mid-`await`.
- **Foreground:** `scenePhase == .active` → `Lifecycle.Event.ON_RESUME`
  (`repeatOnLifecycle`). Network restore: `NWPathMonitor` →
  `ConnectivityManager.NetworkCallback`, marshalled to the confinement
  dispatcher.

### ActivityCoordinator

Live agent state (`Map<UUID, agentId>`), awaiting-input set, session-stolen
alert flags. Persists agent map to DataStore for instant sidebar badge render
on reconnect.

### AuthCoordinator

Single-flight `authJob` (concurrent `ensureAuthenticated()` await the same job);
`withAuth { }` retry-once on `notAuthenticated` (handles server restart
invalidating auth post-reconnect).

### Storage (`:core-storage`)

- **`SavedConnectionStore`** — server bookmarks (DataStore) with **legacy-key
  migration** (one-time, on first launch — analog of iOS `com.coderemote.*`
  migration).
- **`SessionOwnershipStore`** — `sessionNames`, `ownedSessionIds`
  (**device-scoped key**), `agentSessions`, with **diff-checked writes**.
- **Token storage** — **EncryptedSharedPreferences** for per-server tokens
  (keyed by connection UUID) + Bedrock bearer token, with **500 ms debounced
  write** on the Bedrock field (`Flow.debounce(500)`).

### Device identifier (accepted divergence)

iOS `identifierForVendor` is stable across reinstalls; Android has no equal.
**Generate a UUID once on first launch, persist in EncryptedSharedPreferences.**
Namespaces per-device ownership keys (prevents two devices on one Google account
colliding) — all the iOS code uses it for. Slightly less stable (cleared on
app-data-clear): documented, accepted divergence.

### ServerStatusChecker

15 s background poll across bookmarks; each probe spins a short-lived
connect+auth with a 5 s timeout in a `supervisorScope` with `try/finally`
disconnect. Feeds the picker's live/offline dots.

## Section 4 — Terminal Rendering (`:terminal`)

**Engine:** Termux `terminal-emulator` + `terminal-view` (Apache-2.0). Vendored
(no SSH/plugin deps), wrapped. Provides byte-level `feed`, a real scrollback
ring, OSC-title callbacks — SwiftTerm's semantics without a custom VT100 build.

### What we wrap and reproduce

- **`TerminalViewModel` port** — buffering state machine: `receiveOutput` routes
  live bytes only when `!isReplaying && terminalSized`, else buffers;
  `terminalReady()` (first size callback, idempotent) flushes; `beginReplay`/
  `endReplay`; `prepareForSwitch`/`prepareForReplay` cleanup. **4 MB
  `pendingOutput` cap** with FIFO drop-oldest + once-per-session warning.
- **Replay protocol (match exactly):** `beginReplay` → buffer all → on
  `replay_complete`, `endReplay` flushes accumulated bytes as **one contiguous
  `feed()`** (single display pass, no history scrolling past). `terminalReady`
  sends **RIS (`ESC c` = `0x1B 0x63`)** to blank, deferred to first-ready.
  **Add unit tests** (iOS has none here — close the gap).
- **Input-prompt silence detector:** coroutine `delay` + `Job` cancel replacing
  the Swift debounce; **1000 ms normal / 2000 ms agent-active**, feeding
  `awaitingInput` → tab attention-flash.
- **Resize:** recompute cols/rows from view bounds ÷ monospace cell metrics on
  layout change; send `resize` immediately (not debounced); `resize_ack`
  reconciles.
- **Keyboard accessory bar** — Compose `LazyRow` of special keys sending raw
  bytes: ESC `0x1B`, Tab `0x09`, arrows (`1B 5B 41/42/43/44`), Ctrl-C/R/A/E/D/Z/L,
  Return `0x0D`, literals `| / ~ - _`, clear-to-prompt cycle.
- **Hardware keyboard:** Android `onKeyEvent` + `KeyEvent.META_*`. The iOS
  Obj-C runtime hooks (`hasText`/`deleteBackward`/`canPerformAction`) are
  iOS-UITextInput-specific and **not needed** on Android — but explicitly test
  continuous backspace key-repeat and clipboard paste.
- **Theming:** 16-color ANSI palette (8 basic + 8 bright) → packed ARGB;
  monospace font; configurable size (8–16 pt); carry over the brighter-palette /
  pure-black-background values.
- **Copy/paste & image paste:** `ClipboardManager`; image → PNG base64 →
  `paste_image`.
- **Per-session scrollback** (1k/5k/10k/25k) → emulator ring size; server ring
  replays beyond it.

## Section 5 — On-Device Speech, Full Parity (`:speech`)

### Native inference (JNI)

- **whisper.cpp** — same Whisper `small.en` weights as iOS. Background-dispatcher
  inference as a suspend fun; port repetition-hallucination collapse
  (Levenshtein/char-unit) from `WhisperTranscriber`.
- **llama.cpp** — same Qwen GGUF for `TextCleaner`. 512-token context, **8 s
  timeout race**, revert-on-timeout/hallucination. Memory unload:
  `didReceiveMemoryWarning` → `ComponentCallbacks2.onTrimMemory`.

### CoreML → ONNX conversion sub-project (gated, validated)

- **Silero VAD** — public ONNX weights exist (FluidInference Silero v6); low
  risk. Stateful LSTM hidden/cell threading preserved. ONNX Runtime Mobile.
  Energy-VAD fallback (`VoiceActivityDetector`: speech 0.015 / silence 0.008,
  250 ms / 1 s debounce) ported as documented fallback.
- **WhisperLogMel8s** (audio → `[1,80,800]` log-mel) and **SmartTurn v3**
  (Whisper-Tiny encoder + linear head → sigmoid, 0.5 threshold) — converted via
  `coremltools` graph introspection → ONNX, then **numeric-parity-validated**
  against iOS models on a reference audio set **before being trusted**;
  `HeuristicTurnEndDetector` is the fallback. **Gate:** do not ship until parity
  validation passes (VAD edges within tolerance; turn-end TPR/FPR within ±5%).

### Pure-Kotlin ports (no native deps)

- **Continuous-listening state machine** — full `idle → listening →
  detectingWakeWord → armed(red, 4 s) → recording → detectingTurnEnd →
  transcribing → cleaning → outputting`, incl. the **strict two-phase
  red-handshake** (combined "Claude, do X" rejected — non-empty residue
  refused), the `raceTurnEnd` "classifier authoritative, timer safety-net" rule,
  and blue/red/yellow color buckets.
- **Wake-word matching** — alias table → Levenshtein (≤2) → **Metaphone**
  phonetic + first-letter guard. Pure logic.
- **`SpeechPostProcessor`** — cloud-enhance (Bedrock Haiku, if token) → local
  cleanup → passthrough; never throws.

### Audio + platform

- **Capture:** `AVAudioEngine` → **Oboe** (or `AudioRecord`), resampled to
  **16 kHz mono Float32**; `StreamingAudioBuffer` ring (lock-free reads). 5-min
  auto-stop cap retained.
- **`CloudPromptEnhancer`** — Bedrock Converse REST via OkHttp + bearer token;
  error-body sanitization (`Bearer` redaction) ported.
- **Android 14+ realities (divergence):** continuous listening needs a
  **foreground service** with `foregroundServiceType="microphone"` + persistent
  notification (Android can't mic in background silently), `RECORD_AUDIO` runtime
  permission, `POST_NOTIFICATIONS` (API 33+). Same foreground-only *spirit* as
  iOS but Android requires the explicit FG-service + notification.
- **`SpeechModelStore`** — model download/cache/disk-lifecycle with progress UI;
  large resumable downloads (Whisper + ~2.4 GB Qwen).

## Section 6 — UI, Navigation & Platform Integration (`:feature-*`, `:app`)

### Adaptive navigation (iPad split-view parity)

Material 3 `WindowSizeClass` via `currentWindowAdaptiveInfo()`:
- **Expanded** (tablet/foldable): two-pane sidebar `|` terminal.
- **Compact** (phone): terminal full-screen, sidebar as dismissible
  drawer / `ModalBottomSheet` (the `.medium`/`.large` detent analog).
- Reflows live on fold/unfold and rotation.

### Screen parity map

| iOS | Android | Notes |
|---|---|---|
| `ServerListView` | `ServersScreen` | `LazyColumn`, pull-to-refresh, swipe edit(blue)/delete(red) via `SwipeToDismissBox`, live/offline dot, empty-state |
| `AddEditServerView` | `AddEditServerSheet` | `ModalBottomSheet` form: name/host/port/TLS/token (`PasswordVisualTransformation`), host validation, delete-confirm |
| `WorkspaceView` | `WorkspaceScreen` | Adaptive split host; `ON_RESUME` recovery, pending-deep-link attach, recovery overlay |
| `ActiveTerminalView` | `TerminalScreen` | Terminal host + floating mic + keyboard toggle + status bar (quality dot, uptime, tabs, QR share, name badge) |
| `SessionSidebarView` | `SessionSidebar` | New/Attach, session list with state badges, rename dialog, swipe-delete, long-press context menu (rename / share QR), attach sheet + scanner |
| `SettingsView` | `SettingsScreen` | Full settings (below) |
| `SplashScreenView` | `SplashScreen` | Animated logo via `Animatable`/`LaunchedEffect`; preloads speech models on dismiss |
| `QRCodeSheet` | `QrShareSheet` | ZXing QR of `clauderelay://session/{UUID}` + selectable deeplink |
| `QRScannerView` | `QrScannerScreen` | CameraX + ML Kit barcode; haptic on detect; parse → attach |

### Settings parity (18 `@AppStorage` keys → DataStore; Bedrock token → EncryptedSharedPreferences)

- **Speech-to-Text:** Smart Cleanup, Prompt Enhancement, Continuous Listening +
  wake-word display
- **AWS Bedrock:** bearer token (masked, 500 ms debounced write) + region;
  validation alert if enhancement on but token empty
- **Connection:** Auto-Connect (reconnect to `lastConnectedServerId` on launch)
- **General:** Haptic Feedback, Session-Naming theme picker (GoT/Viking/Star
  Wars/Dune/LOTR/Star Trek), Terminal Font Size stepper (8–16), Scrollback
  picker (1k/5k/10k/25k)
- **Keyboard Shortcuts:** recording-shortcut toggle + key-capture
  (`KeyEvent.META_*` + keycode)
- **About:** version/build from `BuildConfig`

### Shared UI atoms (ClaudeRelayClient `Views/` → Compose)

- **`ConnectionQualityDot`** — excellent/good=green, poor/veryPoor=yellow(blink),
  disconnected=red; blink via `rememberInfiniteTransition`
- **`ActivityDot`** — active/idle=green, agent* = agent color (idle blinks);
  **`AgentColorPalette`** ported (Claude/Codex tab coloring)
- **Session tabs** — numbered, agent-colored, flash when awaiting input;
  `LazyRow`
- **`MicButton`** — dual-mode (PTT tap / continuous + long-press one-shot),
  state-driven icon+color, download-progress ring

### Cross-cutting platform integration

- **Deep links:** `clauderelay://session/{UUID}` → `intent-filter`
  (`VIEW`/`BROWSABLE`); handle cold-start (`onCreate`) and warm (`onNewIntent`)
  → `pendingSessionId`, consumed on workspace entry.
- **Lifecycle:** `scenePhase` → `Lifecycle` events; recovery on `ON_RESUME`,
  speech-cancel on background.
- **Haptics:** `HapticFeedback` / `VibrationEffect` (+ `VIBRATE`).
- **Manifest/permissions:** `INTERNET`, `RECORD_AUDIO`, `CAMERA`,
  `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`,
  `VIBRATE`; runtime flows via `ActivityResultContracts`.
- **DI/navigation:** Hilt; Compose Navigation with the deep-link graph.

## Phased Release Milestones

| Milestone | Scope | Closed-beta deliverable |
|---|---|---|
| **M1** | `:core-protocol`, `:core-net`, `:core-storage`, basic connect + live terminal (Termux engine), TLS scoping | Connect to a server, see and type in a live terminal |
| **M2** | `:core-session` (full recovery state machine), sessions/tabs, sidebar, QR share+scan, deep links, adaptive layout, settings | Full session management + recovery parity (no speech) |
| **M3** | `:speech` — capture, whisper.cpp, Silero VAD (ONNX + energy fallback), PTT + continuous state machine, Bedrock + llama.cpp cleanup; **conversion sub-project** for LogMel + SmartTurn behind parity gate | On-device speech input working; turn-end via heuristic until models pass the parity gate |
| **M4** | SmartTurn/LogMel parity-validated & enabled, full polish, accessibility, haptics, animations, edge-case hardening | 100% feature parity → public launch |

## Risk Register

| Risk | Severity | Mitigation |
|---|---|---|
| CoreML→ONNX conversion (SmartTurn, LogMel) degrades accuracy | High | Parity gate: numeric validation on reference audio set before enabling; `HeuristicTurnEndDetector` fallback ships meanwhile |
| Termux engine integration friction | Medium | Vendored, battle-tested; fallback is custom VT100 (10–12 wk) only if integration fails |
| Double-timestamp / binary-frame protocol misreads | Medium | Contract test round-tripping a captured live server frame |
| Continuous-listening FG-service UX divergence from iOS | Medium | Documented divergence; persistent notification required by platform |
| Device-identifier instability vs iOS | Low | Generated UUID in EncryptedSharedPreferences; documented |
| Large model downloads (~2.4 GB Qwen) | Medium | Resumable downloads, progress UI, cloud-only fallback if download fails |

## Out of Scope

- Any server-side change (protocol frozen).
- Kotlin Multiplatform shared core (explicitly deferred; contract is the wire
  protocol).
- macOS/iOS app changes (other than, eventually, atomic protocol-version bumps
  that the monorepo makes possible — none planned in M1–M4).
- A separate Android repository (decided against — see "Repository layout").
