# ClaudeRelay

A remote terminal relay server and CLI over WebSocket, enabling secure terminal access with session management and authentication.

## Features

- **WebSocket-based terminal relay** - Real-time bidirectional communication
- **Session management** - Create, list, attach, and detach terminal sessions with tab-based switching
- **Token-based authentication** - Secure access control with configurable tokens
- **PTY sessions** - Interactive shell sessions with full terminal emulation
- **Session persistence** - Detach and reattach to running sessions
- **TLS encryption** - Optional NIO-SSL support for secure WebSocket connections
- **Service management** - Run as a background service with launchd/brew services
- **iOS client** - Native iOS app with terminal emulation, session tabs, and coding agent detection
- **macOS client** - Native macOS app with menu-bar persistence, full keyboard shortcuts, and iOS feature parity
- **Multi-agent detection** - Pluggable coding agent registry (Claude Code, Codex) with per-agent tab colors
- **On-device speech engine** - Offline speech-to-text via WhisperKit (CoreML/ANE) with LLM text cleanup (iOS + macOS)
- **Cloud prompt enhancement** - Optional rewriting of transcriptions into clear prompts via Anthropic Haiku
- **Admin API** - Localhost-only HTTP API for service management and monitoring (64 KB request body cap)
- **Config validation** - Two-layer validation: CLI client-side (fails fast on typos/bad values) + server-side (authoritative)
- **Per-token session cap** - Configurable `maxSessionsPerToken` (default 50) prevents runaway clients from exhausting server resources

## Architecture

ClaudeRelay consists of six main components:

- **ClaudeRelayServer** - WebSocket server (port 9200) and Admin HTTP API (port 9100)
- **ClaudeRelayCLI** - Command-line interface for managing tokens, sessions, and service
- **ClaudeRelayKit** - Shared library with protocol definitions, utilities, and `CodingAgent` registry
- **ClaudeRelayClient** - Swift client library for building custom clients (includes shared `SessionCoordinating` protocol and `SessionNaming` helpers)
- **ClaudeRelayApp** - iOS application with terminal emulation
- **ClaudeRelayMac** (branded "ClaudeDock") - Native macOS application with menu-bar persistence and full feature parity with iOS

## Installation

### Homebrew (macOS)

```bash
brew install miguelriotinto/claude-relay/clauderelay
```

### From Source

Requires Xcode 15.0+ and macOS 14+:

```bash
git clone https://github.com/miguelriotinto/ClaudeRelay.git
cd ClaudeRelay
swift build -c release
```

Binaries will be in `.build/release/`:
- `claude-relay` - CLI tool
- `claude-relay-server` - Server daemon

## Quick Start

### 1. Start the Server

Using Homebrew services:
```bash
brew services start clauderelay
```

Or manually:
```bash
claude-relay load --ws-port 9200
```

### 2. Create an Authentication Token

```bash
claude-relay token create --label "my-device"
```

Copy the generated token - you'll need it to authenticate clients.

### 3. Check Service Status

```bash
claude-relay status
claude-relay health
```

### 4. View Logs

```bash
claude-relay logs show
claude-relay logs tail
```

## CLI Commands

### Service Management
```bash
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
claude-relay config validate                         # Validate the saved config file
```

`config set` validates keys and value ranges locally before forwarding to the admin API — unknown keys, out-of-range ports, and bad log levels are rejected immediately. `config validate` runs the same checks against `~/.claude-relay/config.json` without needing the server to be running.

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
  "bindAll": true
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
swift test                                    # All SPM tests (703 tests across 5 targets)
swift test --filter ClaudeRelayKitTests       # Specific suite
swift test --filter testTokenGeneration       # Specific test
```

The SPM suite covers the protocol layer (envelope + client/server messages +
activity/session state + token generation + connection quality), the server
actors (`SessionManager`, `TokenStore`, `PTYSession` via `MockPTYSession`,
`SessionActivityMonitor`, `RateLimiter`, `RingBuffer`, `LogStore`,
`AdminRoutes` endpoints, config validation), the client (auth coordinator,
saved connections, session naming, session ownership, terminal view model +
LRU cache, recovery controller, WebSocket integration round-trip), the CLI
(output formatter, admin client), and the speech pipeline
(`ClaudeRelaySpeechTests` — text cleaning, wake-word matching, turn-end
heuristics, and other UIKit/Keychain-free units). Tests that require
UIKit/AppKit or the Keychain live in the Xcode test bundles
(`ClaudeRelayAppTests` on iOS) — build the `ClaudeRelayApp` scheme and run
tests in Xcode to exercise them.

Contributions that add a new public API or a new branch should come with a
test in the corresponding `Tests/<Module>Tests/` directory (or
`ClaudeRelayAppTests/` for app-target code). Follow the existing patterns —
most suites use the `ProtocolTestCase` (Kit) or `SessionManagerTestCase`
(Server) base classes.

### iOS & Mac Apps

Both apps are configured in the same `project.yml` and generated by XcodeGen. Open `ClaudeRelay.xcodeproj` in Xcode and select a scheme:

- `ClaudeRelayApp` — iOS app, build for iPhone/iPad simulator or device
- `ClaudeRelayMac` — macOS app, build for "My Mac"

After modifying `ClaudeRelayClient` or `ClaudeRelayKit` sources, rebuild the app in Xcode to pick up changes.

See `ClaudeRelayMac/README.md` for Mac-specific setup notes (keyboard shortcuts, menu bar behavior, entitlements).

**Note for contributors:**
- `project.yml` contains a hardcoded `DEVELOPMENT_TEAM` — update this to your own Apple Developer Team ID.
- Run `xcodegen generate` after modifying `project.yml` to regenerate the Xcode project.

### Project Structure

```
ClaudeRelay/
├── Sources/
│   ├── CPTYShim/               # C shim for forkpty PTY operations
│   ├── ClaudeRelayKit/         # Shared protocol models, CodingAgent registry, utilities
│   ├── ClaudeRelayServer/      # WebSocket + HTTP server (NIO-based)
│   ├── ClaudeRelayCLI/         # Command-line interface (ArgumentParser)
│   ├── ClaudeRelayClient/      # Swift client library (shared across apps)
│   │   ├── Protocols/          # SessionCoordinating protocol
│   │   ├── Helpers/            # SessionNaming, SavedConnectionStore, NetworkMonitor, DeviceIdentifier
│   │   ├── ViewModels/         # SharedSessionCoordinator, TerminalViewModel, ServerStatusChecker
│   │   └── Views/              # Shared UI atoms: ConnectionQualityDot, ActivityDot, AgentColorPalette
│   └── ClaudeRelaySpeech/      # Cross-platform on-device speech pipeline (WhisperKit + LLM + SpeechEngineState)
├── ClaudeRelayApp/             # iOS application (SwiftUI, XcodeGen-managed)
│   ├── Views/                  # SwiftUI views + components
│   ├── ViewModels/             # Observable view models
│   └── Models/                 # App settings, saved connections
├── ClaudeRelayMac/             # macOS application (SwiftUI, XcodeGen-managed)
│   ├── Views/                  # SwiftUI views + menu-bar dropdown
│   ├── ViewModels/             # Observable view models
│   ├── Models/                 # App settings, saved connections
│   └── Helpers/                # NetworkMonitor, SleepWakeObserver, image paste
├── Tests/
│   ├── ClaudeRelayKitTests/    # Protocol, CodingAgent, ActivityState, SessionState, TokenGenerator, ConnectionQuality, RelayConfig, MessageEnvelope
│   ├── ClaudeRelayServerTests/ # SessionManager, TokenStore, RateLimiter, RingBuffer, ConfigValidation, ActivityMonitor, AdminRoutesEndpoint
│   ├── ClaudeRelayCLITests/    # OutputFormatter, AdminClient
│   ├── ClaudeRelayClientTests/ # Auth, Connection, SessionNaming, TerminalViewModel, LRU cache, RecoveryController
│   └── ClaudeRelaySpeechTests/ # TextCleaner, WakeWordDetector, turn-end heuristics, speech post-processing
├── ClaudeRelayAppTests/        # iOS app unit tests (AppSettings, SpeechEngineState, WhisperHallucination, TextCleaner, OnDeviceSpeechEngine)
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
- `auth_request` - Authenticate with token (includes optional `protocolVersion`)
- `session_create` - Create new session (optional `name`)
- `session_attach` - Attach to session
- `session_resume` - Resume detached session with scrollback replay
- `session_detach` - Detach from session
- `session_terminate` - Terminate a session
- `session_list` - List own sessions
- `session_list_all` - List sessions across all tokens (for cross-device attach)
- `session_rename` - Rename a session
- `resize` - Resize terminal
- `paste_image` - Paste image data (base64)
- `ping` - Keep-alive ping

**Server Messages:**
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

All responses are JSON. Token creation returns `201 Created`; all other successes return `200 OK`.

## Security

- All WebSocket connections require token-based authentication
- Tokens are stored securely with SHA-256 hashing (never plaintext)
- Optional TLS encryption for WebSocket connections (NIO-SSL, TLS 1.2 minimum)
- Admin API binds to localhost only (`127.0.0.1`) with a 64 KB request body cap
- Session isolation prevents cross-session access; `maxSessionsPerToken` caps fork-bomb risk per token
- IP-based rate limiting on failed authentication attempts (LRU-capped tracking dictionary to bound memory under scanning traffic)
- Server-side config validation prevents invalid/dangerous values; CLI validates client-side before forwarding
- Bearer tokens in speech/Bedrock error bodies are redacted before logging
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
4. Run `swift test` before submitting (all 703 SPM tests must pass; the
   pre-existing Keychain-dependent `AuthManagerTests` and one timing
   `SessionActivityMonitor` test may fail in sandboxed environments —
   they're environmental, not regressions)
5. Ensure `swiftlint` passes (see `.swiftlint.yml`)

## License

MIT License - see [LICENSE](LICENSE) for details.

## Links

- **GitHub**: https://github.com/miguelriotinto/ClaudeRelay
- **Homebrew Tap**: https://github.com/miguelriotinto/homebrew-claude-relay
- **Issues**: https://github.com/miguelriotinto/ClaudeRelay/issues
