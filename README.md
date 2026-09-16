# CodeRelay

A remote terminal relay server and CLI over WebSocket, enabling secure terminal access with session management and authentication.

## Features

- **WebSocket-based terminal relay** - Real-time bidirectional communication
- **Session management** - Create, list, attach, and detach terminal sessions with tab-based switching
- **Token-based authentication** - Secure access control with configurable tokens
- **PTY sessions** - Interactive shell sessions with full terminal emulation
- **Session persistence** - Detach and reattach to running sessions
- **TLS encryption** - Optional NIO-SSL support for secure WebSocket connections
- **Service management** - Run as a background service with launchd/brew services (macOS) or a systemd user unit (Linux)
- **iOS client** - Native iOS app with terminal emulation, session tabs, and coding agent detection
- **macOS client** - Native macOS app with menu-bar persistence, full keyboard shortcuts, and iOS feature parity
- **Android client** - Native Android app (Jetpack Compose) with a real VT100 terminal, session tabs, recovery, and the prompt-optimizer wand (in test-build distribution; see [CodeRelayAndroid](CodeRelayAndroid/))
- **Multi-agent detection** - Pluggable coding agent registry (Claude Code, Codex, opencode, Copilot CLI, Cursor Agent, Droid) with per-agent tab colors
- **Device pairing** - `claude-relay setup` prints a QR carrying a single-use, 5-minute pairing code; the app redeems it for its own revocable per-device token
- **Push notifications** - Optional APNs/FCM alerts when an agent finishes or needs input, coalesced per workspace (off by default)
- **Clipboard bridging** - Two-way: device→host image paste, and host→device via OSC 52, so tmux/vim/kitty copies land on the device clipboard
- **Workspace rollups** - Sessions group by git root in the sidebar with an aggregate status badge
- **Prompt optimizer** - The wand button (or the keyboard shortcut you used for recording) asks the relay to rewrite whatever you have typed at the agent's input line into a well-structured coding-agent prompt. The relay types the rewrite for you and never presses Enter; a 10-second Undo puts your original back. Enable it on the relay with `claude-relay config set promptOptimizerEnabled true` plus an API key file (see Configuration). To dictate, use your device's own dictation into the terminal — the apps no longer ship a speech engine.
- **Admin API** - Localhost-only HTTP API for service management and monitoring (64 KB request body cap)
- **Config validation** - Two-layer validation: CLI client-side (fails fast on typos/bad values) + server-side (authoritative)
- **Per-token session cap** - Configurable `maxSessionsPerToken` (default 50) prevents runaway clients from exhausting server resources

## Architecture

The macOS server/CLI and the two Apple clients are built from one Swift package; the Android client is a separate Gradle project under `CodeRelayAndroid/`.

**Swift package (server, CLI, shared libraries, Apple clients):**

- **CodeRelayServer** - WebSocket server (port 9200) and Admin HTTP API (port 9100)
- **CodeRelayCLI** - Command-line interface for managing tokens, sessions, and service
- **CodeRelayKit** - Shared library with protocol definitions, utilities, and `CodingAgent` registry
- **CodeRelayClient** - Swift client library for building custom clients (includes shared `SessionCoordinating` protocol and `SessionNaming` helpers)
- **CodeRelayApp** - iOS application with terminal emulation
- **CodeRelayMac** - Native macOS application with menu-bar persistence and full feature parity with iOS (both apps ship as **Code[Relay]**)

**Android client (separate Gradle project, `CodeRelayAndroid/`):**

- A native Jetpack Compose app that re-implements the client stack in Kotlin (protocol, WebSocket transport via OkHttp, session coordinator + recovery, a real VT100 terminal via ConnectBot `termlib`, and the same prompt-optimizer wand as the Apple clients). It speaks the identical wire protocol to the same server. The APK is published with every [release](https://github.com/miguelriotinto/CodeRelay/releases) (`vX.Y.Z` tags, under its own **Android client** section) next to the Linux client and server; interim test builds also appear as `android-v*` pre-releases — see [`CodeRelayAndroid/RELEASE.md`](CodeRelayAndroid/RELEASE.md).

## Installation

### Homebrew (macOS)

```bash
brew install miguelriotinto/clauderelay/clauderelay
```

### Arch Linux / Omarchy

The server and CLI also run natively on Linux under a **systemd user service**.
Install the prebuilt package (statically linked; depends only on `curl`, with
`wl-clipboard`/`xclip` optional for image paste):

```bash
# from the AUR
yay -S coderelay-server-bin
claude-relay setup                 # starts the service, prints a pairing QR
```

Or download the tarballs straight from the [Releases](https://github.com/miguelriotinto/CodeRelay/releases)
page — every release has a **Linux server + CLI** section
(`claude-relay-vX.Y.Z-linux-x86_64.tar.gz`), a **Linux client** section
(`coderelay-vX.Y.Z-linux-x86_64.tar.gz`, the Compose Desktop app; also
`yay -S coderelay-bin`), and an **Android client** section with the APK.

`setup` installs and starts `claude-relay.service` for your user and prints the
pairing QR. The service runs while you are logged in; for a headless host that
must serve with nobody logged in, run `loginctl enable-linger`. Manage it with
the same commands as macOS — `claude-relay status | start | stop | restart |
logs show` — and read the service log with
`journalctl --user -u claude-relay -f`.

See [`docs/linux-server-spec.md`](docs/linux-server-spec.md) for the full design.

### From Source

**macOS** requires Xcode 15.0+ and macOS 14+:

```bash
git clone https://github.com/miguelriotinto/CodeRelay.git
cd CodeRelay
swift build -c release
```

**Linux** requires a Swift 6 toolchain and `cmake` (for the PTY C shim). The
Apple client libraries are excluded from the Linux build automatically:

```bash
swift build -c release --static-swift-stdlib --product claude-relay-server -Xlinker -lcurl
swift build -c release --static-swift-stdlib --product claude-relay -Xlinker -lcurl
```

Binaries will be in `.build/release/`:
- `claude-relay` - CLI tool
- `claude-relay-server` - Server daemon

## Quick Start

### 1. Install and pair

```bash
brew install miguelriotinto/clauderelay/clauderelay
claude-relay setup
```

`setup` starts the service (using whichever manager owns it — Homebrew or a
launchd agent), then prints a QR code.

The QR carries a **single-use pairing code** that expires in five minutes, not
your auth token. The app exchanges it over the WebSocket for its own per-device
token, which shows up in `claude-relay token list` under the device's name and
can be revoked individually.

Scan it from the app's server list: iOS and Android open a camera scanner. On
macOS, use the **Pair** button in the server list and type the host and code by
hand (port defaults to 9200) — the Mac's `Cmd+Shift+Q` scanner reads
session-attach QRs only, not pairing QRs. A `coderelay://pair?…` deep link
does fill in every field.

> **Prefer to connect manually?** Mint a token instead and paste it into the
> app's Add Server sheet (labelled **Auth Token** on iOS, **Token** on macOS):
>
> ```bash
> claude-relay token create --label "my-device"
> ```

### 2. Optional: authoritative agent state

```bash
claude-relay hook install
```

Lets Claude Code report its lifecycle directly instead of the server inferring
state from the terminal screen. Safe to re-run; reverse with `hook uninstall`.

### 3. Check on it

```bash
claude-relay status     # includes which manager owns the service
claude-relay health
claude-relay logs show
```

> **Which service manager?** A Homebrew install is managed by `brew services`;
> `claude-relay load` installs its own launchd agent instead. Only ever use one
> — two managers would compete for the same port. The CLI detects which one owns
> your service and tells you the right command if you reach for the wrong one.

## CLI Commands

### Service Management
```bash
claude-relay setup         # Start service + generate pairing QR code
claude-relay hook install  # Install Claude Code state hook (optional)
claude-relay load          # Install and start launchd service
claude-relay unload        # Remove launchd service
claude-relay start         # Start the service
claude-relay stop          # Stop the service
claude-relay restart       # Restart the service
claude-relay status        # Check service status
claude-relay health        # Health check
```

### Token Management
```bash
claude-relay token create --label "device-name"     # Create new token
claude-relay token list                              # List all tokens
claude-relay token delete <token-id>                 # Delete a token
claude-relay token rotate <token-id>                 # Rotate (regenerate) a token
claude-relay token rename <token-id> --label "new"   # Rename a token
claude-relay token inspect <token-id>                # Show token details
```

### Session Management
```bash
claude-relay session list                            # List active sessions
claude-relay session inspect <session-id>            # Show session details
claude-relay session terminate <session-id>          # Terminate a session
```

### Logs
```bash
claude-relay logs show                               # Show recent logs
claude-relay logs tail                               # Follow log output
```

### Configuration
```bash
claude-relay config show                             # Show current config
claude-relay config set wsPort 9200                  # Set WebSocket port
claude-relay config set adminPort 9100               # Set admin API port
claude-relay config set bindAll false                # Restrict to 127.0.0.1 (default is 0.0.0.0, all interfaces)
claude-relay config set maxSessionsPerToken 50       # Cap sessions per token (0 = unlimited)
claude-relay config set logLevel info                # trace/debug/info/warning/error
claude-relay config validate                         # Sanity-check the running server's config
```

`config set` validates keys and value ranges locally before forwarding to the admin API — unknown keys, out-of-range ports, and bad log levels are rejected immediately. `config validate` is a lighter, separate check: it reads the config back over the admin API (so the service must be running) and verifies that each port is an integer in the 1024–65535 range the admin API accepts (the same bound `config set` enforces), and that `wsPort` and `adminPort` differ. It checks ports only — a clean `validate` is not full semantic validation of the config.

## Configuration

Configuration is stored at `~/.claude-relay/config.json`:

```json
{
  "wsPort": 9200,
  "adminPort": 9100,
  "detachTimeout": 0,
  "scrollbackSize": 524288,
  "tlsCert": "~/.claude-relay/certs/cert.pem",
  "tlsKey": "~/.claude-relay/certs/key.pem",
  "logLevel": "info",
  "maxSessionsPerToken": 50,
  "bindAll": true,
  "pushEnabled": false
}
```

**Configuration Options:**
- `wsPort` - WebSocket server port (default: 9200)
- `adminPort` - Admin HTTP API port (default: 9100)
- `detachTimeout` - Session timeout in seconds, 0 = never expire (default: 0)
- `scrollbackSize` - Maximum server-side scrollback ring-buffer size in bytes per session (default: 524288)
- `tlsCert` - Path to TLS certificate file for WebSocket server (optional)
- `tlsKey` - Path to TLS private key file for WebSocket server (optional)
- `logLevel` - Logging verbosity: "trace", "debug", "info", "warning", "error" (default: "info")
- `maxSessionsPerToken` - Maximum active (non-terminal) sessions per token; 0 = unlimited (default: 50)
- `bindAll` - When `true` (default), the WebSocket server binds `0.0.0.0` — it accepts connections from any interface (loopback, LAN, VPN, bridges). Set to `false` to bind `127.0.0.1` only. Startup logs an explicit warning when `bindAll=true` without TLS, because tokens travel in plaintext on the bound network.

**Push notification options** (all off/unset by default):
- `pushEnabled` - Master switch for sending pushes (default: `false`). Device tokens are accepted and stored even while this is off, so enabling it later needs no client reconnect.
- `pushNotifyOnFinished` - Server-wide default for "notify when an agent finishes"; a per-device preference overrides it (default: `false`)
- `apnsKeyPath` / `apnsKeyId` / `apnsTeamId` / `apnsBundleId` - APNs auth-key credentials for iOS/macOS delivery. `apnsKeyPath` must point at a readable `.p8`.
- `apnsUseSandbox` - Target the APNs sandbox host, for development builds (default: `false`)
- `fcmServiceAccountPath` / `fcmProjectId` - Firebase service-account JSON path and project id for Android delivery

**Prompt optimizer options** (off by default):
- `promptOptimizerEnabled` - Master switch for the wand (default: `false`)
- `promptOptimizerProvider` - `anthropic` | `bedrock` (default: `anthropic`)
- `promptOptimizerModel` - default `claude-sonnet-5` on Anthropic, `anthropic.claude-sonnet-5` on Bedrock
- `promptOptimizerRegion` - Bedrock only (default: `us-east-1`)
- `promptOptimizerKeyPath` - File holding the API key, `chmod 600`; the key is read once at startup and never logged
- `promptOptimizerShareScreen` - The server-side gate on sending the last 40 screen lines to the model (default: `true`); the device has its own toggle

`promptOptimizer*` changes take effect only after a relay restart — the key is read once at startup, so `config set promptOptimizerEnabled true` alone leaves the capability absent:

```bash
claude-relay config set promptOptimizerEnabled true
claude-relay config set promptOptimizerKeyPath ~/.claude-relay/optimizer.key   # chmod 600
claude-relay restart                                 # the key is read once, at startup
```

**What leaves the host when you use the optimizer:** the draft you typed and its working directory are always sent to the configured model provider — that is the point of the feature. When the per-device toggle "Share terminal screen with the optimizer" *and* the server-side `promptOptimizerShareScreen` kill switch are both on, up to the last 40 lines of the terminal screen are sent as well; turning either one off stops that. Nothing about the draft, the working directory or the screen is logged, at any log level, and the API key is never sent to clients.

A corrupt `config.json` is tolerated: the server logs to stderr and falls back to `RelayConfig.default` so launchd-managed services stay up. App-side, `terminalScrollbackLines` (iOS + macOS Settings, default 5000, max 25000) controls the client's in-memory terminal history independent of the server's ring buffer.

### TLS Configuration

To enable TLS encryption for the WebSocket server (recommended for network access):

1. **Generate a self-signed certificate** (for development/testing):
   ```bash
   mkdir -p ~/.claude-relay/certs
   openssl req -x509 -newkey rsa:4096 \
     -keyout ~/.claude-relay/certs/key.pem \
     -out ~/.claude-relay/certs/cert.pem \
     -days 365 -nodes -subj "/CN=localhost"
   ```

2. **Update config to enable TLS**:
   ```bash
   claude-relay config set tlsCert "~/.claude-relay/certs/cert.pem"
   claude-relay config set tlsKey "~/.claude-relay/certs/key.pem"
   ```

3. **Restart the server**:
   ```bash
   claude-relay restart
   ```

4. **iOS App**: Enable "Use TLS" toggle in the server configuration and use `wss://` URL scheme.

**Production TLS:**
For production deployments, use a valid certificate from a trusted CA (Let's Encrypt, etc.) instead of a self-signed certificate. The iOS app will require proper certificate trust for `wss://` connections.

**Note:** TLS is only applied to the WebSocket server (port 9200). The Admin API (port 9100) remains localhost-only without TLS.

### When TLS is required

Both the iOS and macOS apps scope App Transport Security via `NSAllowsLocalNetworking`, which permits plaintext WebSocket (`ws://`) only to:

- Loopback (`127.0.0.1`, `::1`)
- `.local` mDNS hostnames
- RFC 1918 private IPv4 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`)
- Link-local IPv6 (`fe80::/10`)

Plaintext `ws://` to any other address — including **Tailscale CGNAT addresses (`100.64.0.0/10`)**, IPv6 ULA (`fc00::/7`), VPN overlays whose endpoints sit outside the ranges above, and public hostnames — is refused by iOS/macOS before the WebSocket handshake reaches the server. If you reach the server from a non-private network, you must configure TLS on the server (see the steps above) and use a `wss://` URL in the app.

This is an iOS/macOS platform constraint: the `NSAppTransportSecurity` plist entry does not support CIDR ranges, so we cannot transparently allow CGNAT or ULA plaintext. TLS is the supported path for any non-LAN deployment.

## Development

### Build

```bash
swift build
```

### Run Tests

```bash
swift test                                    # All SPM tests (5 targets)
swift test --filter CodeRelayKitTests       # Specific suite
swift test --filter testTokenGeneration       # Specific test
```

The SPM suite covers the protocol layer (envelope + client/server messages +
activity/session state + token generation + connection quality), the server
actors (`SessionManager`, `TokenStore`, `PTYSession` via `MockPTYSession`,
`SessionActivityMonitor`, `RateLimiter`, `RingBuffer`, `LogStore`,
`AdminRoutes` endpoints, config validation), the client (auth coordinator,
saved connections, session naming, session ownership, terminal view model +
LRU cache, recovery controller, WebSocket integration round-trip), and the CLI
(output formatter, admin client). Tests that require UIKit/AppKit or the
Keychain live in the Xcode test bundles (`CodeRelayAppTests` on iOS) — build
the `CodeRelayApp` scheme and run tests in Xcode to exercise them.

Contributions that add a new public API or a new branch should come with a
test in the corresponding `Tests/<Module>Tests/` directory (or
`CodeRelayAppTests/` for app-target code). Follow the existing patterns —
most suites use the `ProtocolTestCase` (Kit) or `SessionManagerTestCase`
(Server) base classes.

### iOS & Mac Apps

Both apps are configured in the same `project.yml` and generated by XcodeGen. Open `CodeRelay.xcodeproj` in Xcode and select a scheme:

- `CodeRelayApp` — iOS app, build for iPhone/iPad simulator or device
- `CodeRelayMac` — macOS app, build for "My Mac"

After modifying `CodeRelayClient` or `CodeRelayKit` sources, rebuild the app in Xcode to pick up changes.

See `CodeRelayMac/README.md` for Mac-specific setup notes (keyboard shortcuts, menu bar behavior, entitlements).

**Note for contributors:**
- `project.yml` contains a hardcoded `DEVELOPMENT_TEAM` — update this to your own Apple Developer Team ID.
- Run `xcodegen generate` after modifying `project.yml` to regenerate the Xcode project.

### Project Structure

```
CodeRelay/
├── Sources/
│   ├── CPTYShim/               # C shim for forkpty PTY operations
│   ├── CodeRelayKit/         # Shared protocol models, CodingAgent registry, utilities
│   ├── CodeRelayServer/      # WebSocket + HTTP server (NIO-based)
│   ├── CodeRelayCLI/         # Command-line interface (ArgumentParser)
│   ├── CodeRelayClient/      # Swift client library (shared across apps)
│   │   ├── Protocols/          # SessionCoordinating protocol
│   │   ├── Helpers/            # SessionNaming, SavedConnectionStore, NetworkMonitor, DeviceIdentifier
│   │   ├── ViewModels/         # SharedSessionCoordinator, TerminalViewModel, ServerStatusChecker
│   │   └── Views/              # Shared UI atoms: ConnectionQualityDot, ActivityDot, AgentColorPalette, WandButton
├── CodeRelayApp/             # iOS application (SwiftUI, XcodeGen-managed)
│   ├── Views/                  # SwiftUI views + components
│   ├── ViewModels/             # Observable view models
│   └── Models/                 # App settings, saved connections
├── CodeRelayMac/             # macOS application (SwiftUI, XcodeGen-managed)
│   ├── Views/                  # SwiftUI views + menu-bar dropdown
│   ├── ViewModels/             # Observable view models
│   ├── Models/                 # App settings, saved connections
│   └── Helpers/                # SleepWakeObserver, image paste, key capture, launch-at-login
├── CodeRelayAndroid/         # Android application (Jetpack Compose, Gradle — separate build)
│   ├── core-protocol/          # Kotlin wire-protocol models (ClientMessage/ServerMessage/MessageEnvelope)
│   ├── core-net/               # OkHttp WebSocket transport + SessionController
│   ├── core-session/           # SessionCoordinator, RecoveryController, NetworkObserver (pure-JVM)
│   ├── core-storage/           # Token / ownership / saved-connection stores
│   ├── terminal/               # VT100 terminal (ConnectBot termlib) + session view model
│   ├── feature-servers|workspace|settings/  # Compose UI features
│   └── app/                    # Nav graph, MainActivity, connection wiring
├── Tests/
│   ├── CodeRelayKitTests/    # Protocol, CodingAgent, ActivityState, SessionState, TokenGenerator, ConnectionQuality, RelayConfig, MessageEnvelope
│   ├── CodeRelayServerTests/ # SessionManager, TokenStore, RateLimiter, RingBuffer, ConfigValidation, ActivityMonitor, AdminRoutesEndpoint
│   ├── CodeRelayCLITests/    # OutputFormatter, AdminClient
│   └── CodeRelayClientTests/ # Auth, Connection, SessionNaming, TerminalViewModel, LRU cache, RecoveryController
├── CodeRelayAppTests/        # iOS app unit tests (AppSettings, terminal swipe scroll)
├── Formula/
│   └── clauderelay.rb          # Homebrew formula
├── docs/                       # Design specs and implementation plans
└── Package.swift
```

## Wire Protocol

All WebSocket messages use `MessageEnvelope` with JSON encoding:

```json
{
  "type": "message_type",
  "payload": { ... }
}
```

**Client Messages:**
- `pair_request` - Redeem a single-use pairing code for a per-device token (sent **pre-auth**)
- `auth_request` - Authenticate with token (includes optional `protocolVersion`)
- `session_create` - Create new session (optional `name`, `cols`, `rows`)
- `session_attach` - Attach to session (optional `cols`, `rows`)
- `session_resume` - Resume detached session with scrollback replay (optional `skipReplay`, `cols`, `rows`)
- `session_detach` - Detach from session
- `session_terminate` - Terminate a session
- `session_list` - List own sessions
- `session_list_all` - List sessions across all tokens (for cross-device attach)
- `session_rename` - Rename a session
- `refresh` - Ask the server to force a screen repaint (delivers SIGWINCH so the foreground app re-emits its screen)
- `resize` - Resize terminal
- `paste_image` - Paste image data (base64)
- `register_push_token` - Register/update this device's push token and per-device preferences
- `unregister_push_token` - Remove this device's push registration
- `ping` - Keep-alive ping

**Server Messages:**
- `pair_success` - Pairing code redeemed; carries the minted `token`, `tokenId`, and `label`
- `auth_success` / `auth_failure` - Authentication result (includes optional `protocolVersion`)
- `session_created` - Session creation result
- `session_attached` - Attachment confirmation
- `session_resumed` - Resume confirmation
- `session_detached` - Detach confirmation
- `session_terminated` - Session terminated notification
- `session_expired` - Session expired notification
- `session_state` - Session state change
- `session_activity` - Coding agent running/idle activity push
- `session_stolen` - Another device attached to your session
- `session_renamed` - Session name changed
- `replay_complete` - Server has finished sending scrollback for an attach/resume; client may stop buffering and render
- `session_list_result` - List of own sessions
- `session_list_all_result` - List of all sessions
- `resize_ack` - Terminal resize acknowledged
- `paste_image_result` - Image paste success/failure
- `clipboard_update` - Host clipboard write captured from the PTY via OSC 52 (active session only)
- `push_token_ack` - Push registration accepted/rejected
- `pong` - Keep-alive response
- `error` - Error message

**Note:** Terminal I/O (`input`/`output`) is sent as raw binary WebSocket frames, not through the `MessageEnvelope` JSON protocol.

## Admin API

The Admin HTTP API (default port 9100) binds to `127.0.0.1` only. No authentication beyond localhost binding.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check (`{"status": "ok"}`) |
| `GET` | `/status` | Server PID, uptime, session count |
| `GET` | `/sessions` | List all active sessions |
| `GET` | `/sessions/{id}` | Get session details |
| `DELETE` | `/sessions/{id}` | Terminate a session |
| `POST` | `/tokens` | Create token (body: `{"label": "...", "expiryDays": N}`) |
| `GET` | `/tokens` | List all tokens (metadata only) |
| `GET` | `/tokens/{id}` | Get token details |
| `DELETE` | `/tokens/{id}` | Delete a token |
| `POST` | `/tokens/{id}/rotate` | Rotate (regenerate) a token |
| `PATCH` | `/tokens/{id}` | Update token label (body: `{"label": "..."}`) |
| `GET` | `/config` | Get current configuration |
| `PUT` | `/config/{key}` | Update config value (body: `{"value": ...}`) |
| `GET` | `/logs` | Get recent logs (query: `?lines=N`, max 2000) |
| `POST` | `/pair/create` | Mint a single-use pairing code (used by `claude-relay setup`) |
| `POST` | `/hook/state` | Report authoritative agent lifecycle state (body: `{"sessionId": "...", "state": "..."}`) |

All responses are JSON. Token creation returns `201 Created`; all other successes return `200 OK`.

## Security

- All WebSocket connections require token-based authentication
- Tokens are stored securely with SHA-256 hashing (never plaintext)
- Optional TLS encryption for WebSocket connections (NIO-SSL, TLS 1.2 minimum)
- Admin API binds to localhost only (`127.0.0.1`) with a 64 KB request body cap
- Session isolation prevents cross-session access; `maxSessionsPerToken` caps fork-bomb risk per token
- IP-based rate limiting on failed authentication attempts (LRU-capped tracking dictionary to bound memory under scanning traffic)
- Server-side config validation prevents invalid/dangerous values; CLI validates client-side before forwarding
- Configure firewall rules if exposing ports externally

### Folder Permissions

The service runs as a LaunchAgent in your user context with full access to your home directory and user folders. The launchd plist includes:

- **Working Directory**: Set to your home directory
- **Environment Variables**: HOME, USER, and PATH properly configured
- **User Context**: Runs under your user account with standard permissions

**For access to protected folders (Documents, Desktop, Downloads, etc.):**

If you need the service to access macOS protected folders, grant Full Disk Access:

1. Open **System Settings** → **Privacy & Security** → **Full Disk Access**
2. Click the **+** button
3. Navigate to the server binary location:
   - Homebrew: `/opt/homebrew/bin/claude-relay-server` (Apple Silicon) or `/usr/local/bin/claude-relay-server` (Intel)
   - From source: `.build/release/claude-relay-server`
4. Add the binary and toggle it on

Note: This is only required if the terminal sessions need to access protected system folders.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Guidelines

1. Follow existing code style
2. Add tests for new features — at minimum, cover boundary values, error
   paths, and any backward-compat decoding (see how `RelayConfigTests`
   pins defaults across missing-field JSON)
3. Update documentation (README, CHANGELOG, CLAUDE.md)
4. Run `swift test` before submitting (the full SPM suite must pass; the
   pre-existing Keychain-dependent `AuthManagerTests` and one timing
   `SessionActivityMonitor` test may fail in sandboxed environments —
   they're environmental, not regressions). Android changes: run
   `./gradlew test` from `CodeRelayAndroid/`.
5. Ensure `swiftlint` passes (see `.swiftlint.yml`)

## License

MIT License - see [LICENSE](LICENSE) for details.

## Links

- **GitHub**: https://github.com/miguelriotinto/CodeRelay
- **Homebrew Tap**: https://github.com/miguelriotinto/homebrew-clauderelay
- **Issues**: https://github.com/miguelriotinto/CodeRelay/issues
