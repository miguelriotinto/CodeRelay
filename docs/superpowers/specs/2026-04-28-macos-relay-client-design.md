# macOS Relay Client — Design Specification

**Date:** 2026-04-28
**Status:** Draft
**Goal:** Build a native macOS terminal client for ClaudeRelay with full feature parity to the iOS app.

---

## 1. Overview

ClaudeRelayMac is a native macOS application that connects to an existing ClaudeRelay server over WebSocket. It is a pure relay client — architecturally identical to the iOS app. The server remains the source of truth for all sessions; the Mac app is one of many equal-peer clients.

The app provides persistent terminal sessions that survive disconnection, cross-device session attachment (move a session between Mac, iPhone, iPad), real-time Claude Code activity monitoring, on-device speech-to-text, and image paste relay — all within a keyboard-driven, menu-bar-resident Mac interface.

### Non-Goals

- The Mac app does NOT embed the server. The server runs separately (Homebrew or `claude-relay load`).
- No multiplatform SwiftUI target. The Mac and iOS apps are separate targets with their own Views and ViewModels.
- No shared ViewModel extraction until Phase 5 (after both apps exist and the seams are known).

---

## 2. Architecture

```
┌─────────────────────────────────────────────┐
│              ClaudeRelayMac                  │
│  ┌──────────┐  ┌───────────┐  ┌──────────┐  │
│  │  Views   │  │ ViewModels│  │ Speech   │  │
│  │ (SwiftUI │◄─┤ (macOS-   │  │ (Whisper │  │
│  │ +AppKit) │  │  specific)│  │  Kit+LLM)│  │
│  └──────────┘  └─────┬─────┘  └──────────┘  │
│                      │                       │
├──────────────────────┼───────────────────────┤
│         ClaudeRelayClient (SPM)              │
│  RelayConnection · SessionController ·       │
│  AuthManager · ConnectionConfig              │
├──────────────────────────────────────────────┤
│         ClaudeRelayKit (SPM)                 │
│  ClientMessage · ServerMessage · Envelope ·  │
│  SessionInfo · ActivityState · TokenInfo     │
└──────────────────────────────────────────────┘
```

- **ClaudeRelayKit** and **ClaudeRelayClient** are existing cross-platform SPM libraries. No changes needed.
- **ClaudeRelayMac** is a new Xcode target alongside the existing iOS target, both managed by XcodeGen via `project.yml`.
- Terminal emulation: **SwiftTerm** macOS variant (`TerminalView` backed by `NSView`).
- Speech: **WhisperKit** (CoreML/ANE) + **LLM.swift** (Metal) — same stack as iOS, works on Apple Silicon Macs.

---

## 3. Window & Navigation

### 3.1 Main Window

Single `NSWindow` using SwiftUI `NavigationSplitView`:

```
┌──────────────────────────────────────────────────────┐
│  ◉ ◉ ◉    ClaudeRelay — server-name         QR  ⚙️  │
├────────────┬─────────────────────────────────────────┤
│            │                                         │
│  Sessions  │                                         │
│            │                                         │
│  ● sess-1  │         Terminal View                   │
│  ◐ sess-2  │       (SwiftTerm NSView)                │
│  ○ sess-3  │                                         │
│            │                                         │
│            │                                         │
│            │                                         │
│            │                                         │
├────────────┴─────────────────────────────────────────┤
│  + New Session              ● Connected  ▲ Claude    │
└──────────────────────────────────────────────────────┘

● = claude active    ◐ = claude idle    ○ = idle/no claude
```

**Sidebar** (left, collapsible with `Cmd+0`):
- Session list with activity state icons (same visual language as iOS)
- Each row: activity icon, session name, short ID, uptime
- Right-click context menu: Rename, Detach, Terminate
- "+ New Session" button at bottom
- Server switcher dropdown at top (when multiple servers are configured)

**Detail pane** (right):
- SwiftTerm `TerminalView` wrapped in `NSViewRepresentable`
- Full terminal emulation: colors, cursor, scrollback, mouse events

**Title bar**: Current server name. Toolbar buttons for QR code and settings.

**Status bar** (bottom): Connection state, Claude activity for the focused session.

### 3.2 Server List Window

Separate window for server configuration (first-launch and accessible via Preferences):
- Table of saved servers with name, host:port, status indicator
- Add / Edit / Delete
- Double-click to connect

### 3.3 Menu Bar Icon

Persistent `MenuBarExtra` with `.window` style for a rich SwiftUI dropdown:

```
┌─────────────────────────┐
│  ● Server: relay-1      │
│  ───────────────────     │
│  sess-1  ● Claude       │
│  sess-2  ○ Idle         │
│  ───────────────────     │
│  Open Window             │
│  Preferences...          │
│  Quit ClaudeRelay        │
└─────────────────────────┘
```

- Shows connection state and per-session activity
- Click a session to switch to it (opens main window if hidden)
- "Open Window" brings back the main window

### 3.4 Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+T` | New session |
| `Cmd+W` | Detach current session |
| `Cmd+Shift+W` | Terminate current session |
| `Cmd+1..9` | Switch to session by index |
| `Cmd+0` | Toggle sidebar |
| `Cmd+Shift+[` | Previous session |
| `Cmd+Shift+]` | Next session |
| `Cmd+,` | Preferences |
| `Cmd+K` | Clear terminal |

### 3.5 Menu Bar (Application Menu)

```
File
  New Session           Cmd+T
  Close Window          Cmd+W (when no session focused)

Session
  Detach                Cmd+W
  Terminate             Cmd+Shift+W
  Rename...             Cmd+E
  Share via QR Code     Cmd+Shift+Q
  ─────
  Next Session          Cmd+Shift+]
  Previous Session      Cmd+Shift+[
  ─────
  Session 1             Cmd+1
  Session 2             Cmd+2
  ...

View
  Toggle Sidebar        Cmd+0

Window
  (standard macOS window menu)
```

---

## 4. App Lifecycle

### 4.1 Launch

- **First launch**: Server List window. User adds a server and token.
- **Subsequent launches**: Auto-connects to last-used server. Opens main window with session sidebar.
- **Launch at Login** (optional setting): Starts minimized to menu bar only. Connects silently.

### 4.2 Window Close vs Quit

- **Closing the window** (red traffic light or `Cmd+W` with no session focused): hides the window. App stays in menu bar. WebSocket stays connected.
- **Quit** (`Cmd+Q`): gracefully detaches all sessions (server keeps them alive), tears down WebSocket, terminates app.
- **Dock icon click** while window is hidden: reopens main window.
- **Menu bar → "Open Window"**: reopens main window.

### 4.3 Connection Recovery

- **Reconnection**: same exponential backoff with jitter as iOS `RelayConnection` (1s, 2s, 4s... capped at 30s).
- **macOS sleep/wake**: observe `NSWorkspace.willSleepNotification` and `didWakeNotification`. On wake: ping WebSocket → reconnect if dead → re-authenticate → resume active session.
- **Network change**: `NWPathMonitor`. On connectivity restored after a drop: trigger immediate reconnect (skip backoff delay).

### 4.4 Multi-Server

- One active server connection at a time (same as iOS).
- Server list stored in `UserDefaults` (separate from iOS — each platform has its own bookmarks).
- Switching servers: detach all sessions on current server, disconnect, connect to new server.

---

## 5. Feature Details

### 5.1 Terminal Emulation

- SwiftTerm macOS `TerminalView` (NSView-based).
- Wrapped in `NSViewRepresentable` for SwiftUI embedding.
- `TerminalViewModel` bridges `RelayConnection` binary output → `terminal.feed(data:)` and captures terminal input → `connection.sendBinary(data:)`.
- Scrollback: SwiftTerm manages its own scrollback buffer. On session resume, server sends ring buffer contents as binary frames.

### 5.2 Session Management

Identical to iOS, all through the existing wire protocol:
- **Create**: `sessionCreate(name:)` → server spawns PTY → `sessionCreated` response
- **Attach**: `sessionAttach(sessionId:)` → server wires output → `sessionAttached` response + scrollback replay
- **Resume**: `sessionResume(sessionId:)` → `sessionResumed` + scrollback replay
- **Detach**: `sessionDetach` → server keeps PTY alive → `sessionDetached`
- **Terminate**: `sessionTerminate(sessionId:)` → server kills PTY → `sessionTerminated`
- **Cross-device attach**: `sessionListAll` → shows all sessions across all tokens → `sessionAttach` to take over
- **Rename**: `sessionRename(sessionId:, name:)` → server broadcasts `sessionRenamed` to all clients

### 5.3 Activity Monitoring

Server pushes `sessionActivity(sessionId:, activity:)` messages continuously. Mac app displays:
- **Sidebar icons**: `●` claude active, `◐` claude idle, `○` idle/no claude
- **Menu bar dropdown**: same icons per session
- **Status bar**: activity state for the focused session
- **Menu bar icon**: changes color/symbol when any session has Claude active

### 5.4 Image Paste

Two input methods on Mac:

**Clipboard paste (`Cmd+V`)**:
- Intercept paste in the terminal view's key handler.
- Check `NSPasteboard.general` for image types (PNG, TIFF, JPEG).
- If image found: convert to PNG `Data`, base64-encode, send via `pasteImage` wire message.
- If text found: send as normal terminal input (binary frame).
- Server receives `paste_image`, writes to its `NSPasteboard`, sends bracketed paste to PTY.

**Drag and drop**:
- Register the terminal view as a drop target for image file types and image data.
- On drop: read image data, convert to PNG, base64-encode, send via `pasteImage`.

### 5.5 QR Code

**Generation (Mac → mobile)**:
- Toolbar button or `Session` → "Share via QR Code".
- Encodes `coderelay://<host>:<port>/attach?session=<id>&token=<token>` as a QR code.
- Rendered via `CIFilter("CIQRCodeGenerator")` + `CIContext` (same as iOS).
- Displayed as a popover anchored to the toolbar button.
- Dismisses on click outside or session change.

**Scanning (mobile → Mac)**:
- `Session` → "Scan QR Code" or toolbar button.
- Opens a sheet/popover with `AVCaptureSession` + `AVCaptureMetadataOutput` for QR detection.
- Wrapped in `NSViewRepresentable` (same pattern as iOS `UIViewRepresentable`).
- Parses `coderelay://` deep link, triggers session attach.
- Requires camera permission (`NSCameraUsageDescription`).

### 5.6 On-Device Speech

Same pipeline as iOS, adapted for macOS:

```
Mic → AudioCaptureSession → WhisperTranscriber → TextCleaner → Terminal
                                                       ↓
                                              CloudPromptEnhancer (optional)
```

- **WhisperKit**: CoreML models run on Apple Silicon ANE/GPU. Same models as iOS.
- **LLM.swift**: Metal GPU backend for text cleanup. Same as iOS.
- **CloudPromptEnhancer**: Foundation networking to Anthropic Haiku API. Works unchanged.
- **Activation**: configurable keyboard shortcut (default: `Fn+Space`) + toolbar mic icon.
- **Model storage**: `~/Library/Application Support/ClaudeRelay/Models/` (platform-appropriate location).
- **Permissions**: `NSMicrophoneUsageDescription` in Info.plist.
- **Model download**: same `SpeechModelStore` pattern with progress UI in Preferences.

### 5.7 Session Naming Themes

Same theme collections as iOS (Star Wars, Dune, Lord of the Rings). Stored in `AppSettings`, applied when creating new sessions via `SessionCoordinator`.

---

## 6. File Structure

```
ClaudeRelayMac/
├── ClaudeRelayMacApp.swift              — @main App: WindowGroup + MenuBarExtra + Settings
├── AppDelegate.swift                    — NSApplicationDelegate: menu bar icon, sleep/wake,
│                                          launch-at-login, dock icon click
├── Models/
│   ├── SavedConnection.swift            — Server bookmarks (UserDefaults)
│   └── AppSettings.swift                — Preferences (@AppStorage)
├── ViewModels/
│   ├── ServerListViewModel.swift        — Server list, status polling, connection
│   ├── AddEditServerViewModel.swift     — Add/edit server form validation
│   ├── SessionCoordinator.swift         — Auth, session lifecycle, I/O routing,
│   │                                      terminal VM cache, activity state
│   ├── TerminalViewModel.swift          — SwiftTerm macOS I/O bridge
│   ├── ServerStatusChecker.swift        — Periodic health polling
│   └── MenuBarViewModel.swift           — Menu bar dropdown state, session list
├── Views/
│   ├── MainWindow.swift                 — NavigationSplitView: sidebar + terminal
│   ├── ServerListWindow.swift           — Server configuration window
│   ├── AddEditServerView.swift          — Server config form (sheet)
│   ├── SessionSidebarView.swift         — Session list with activity indicators
│   ├── TerminalContainerView.swift      — NSViewRepresentable SwiftTerm wrapper
│   ├── SettingsView.swift               — Preferences window (Cmd+,)
│   ├── QRCodePopover.swift              — QR code generation popover
│   ├── QRScannerView.swift              — AVFoundation camera QR scanner
│   ├── StatusBarView.swift              — Bottom connection/activity bar
│   └── MenuBarDropdown.swift            — Menu bar icon dropdown view
├── Speech/
│   ├── OnDeviceSpeechEngine.swift       — WhisperKit orchestrator (macOS)
│   ├── AudioCaptureSession.swift        — AVAudioEngine wrapper (16kHz mono)
│   ├── WhisperTranscriber.swift         — WhisperKit CoreML/ANE transcription
│   ├── CloudPromptEnhancer.swift        — Anthropic Haiku text cleanup
│   ├── SpeechEngineState.swift          — Speech pipeline state enum
│   ├── SpeechModelStore.swift           — Model download and caching
│   └── TextCleaner.swift                — Regex text normalization
└── Helpers/
    ├── NetworkMonitor.swift             — NWPathMonitor connectivity wrapper
    ├── SleepWakeObserver.swift          — NSWorkspace sleep/wake notification handler
    └── ImagePasteHandler.swift          — Clipboard/drag-drop image detection + encoding
```

### 6.1 XcodeGen Project Setup

New `ClaudeRelayMac` target added to the existing `project.yml`:

- **Platform**: macOS 14+
- **Bundle ID**: `com.claude.relay.mac`
- **Dependencies**: `ClaudeRelayClient` (local SPM), `ClaudeRelayKit` (local SPM), SwiftTerm (remote SPM), WhisperKit (remote SPM), LLM.swift (remote SPM)
- **Frameworks**: AVFoundation, CoreImage, Network, AppKit
- **Info.plist entries**: `NSMicrophoneUsageDescription`, `NSCameraUsageDescription`, `LSUIElement` (for menu-bar-only launch mode)
- **Separate scheme**: `ClaudeRelayMac`

---

## 7. Phased Implementation Plan

### Phase 1 — Core Shell

**Goal**: Connect to a server, create a session, use a terminal. Menu bar icon shows connection state.

| # | Task | Files | Details |
|---|------|-------|---------|
| 1.1 | Create directory structure | `ClaudeRelayMac/` tree | Create all directories: root, Models, ViewModels, Views, Speech, Helpers. Empty placeholders not needed — files created in subsequent tasks. |
| 1.2 | Add macOS target to project.yml | `project.yml` | Add `ClaudeRelayMac` target: macOS 14+, bundle ID `com.claude.relay.mac`, dependencies on ClaudeRelayClient, ClaudeRelayKit, SwiftTerm. Add scheme. Run `xcodegen generate`. |
| 1.3 | Create app entry point | `ClaudeRelayMacApp.swift` | `@main` App struct with `WindowGroup` for main window, `MenuBarExtra` with `.window` style for menu bar, `Settings` scene for preferences. Use `@NSApplicationDelegateAdaptor` for AppDelegate. |
| 1.4 | Create AppDelegate | `AppDelegate.swift` | `NSApplicationDelegate`. Handle `applicationShouldTerminateAfterLastWindowClosed` → return `false` (stay in menu bar). Handle dock icon click → reopen main window. Placeholder for sleep/wake (Phase 3). |
| 1.5 | Create SavedConnection model | `Models/SavedConnection.swift` | Struct with `id: UUID`, `name: String`, `host: String`, `port: UInt16`, `useTLS: Bool`. UserDefaults persistence via `@AppStorage` or manual JSON encode/decode. Same shape as iOS but independent storage. |
| 1.6 | Create AppSettings model | `Models/AppSettings.swift` | `@AppStorage` wrapper for preferences: last server ID, naming theme, speech shortcut, launch-at-login flag, prompt improvement toggle. Start with just `lastServerId`. |
| 1.7 | Create ServerStatusChecker | `ViewModels/ServerStatusChecker.swift` | Timer-based health polling. Takes a `ConnectionConfig`, calls `AdminClient.isServiceRunning()` or a direct HTTP GET to `/health`. Publishes `isReachable: Bool`. Same pattern as iOS. |
| 1.8 | Create ServerListViewModel | `ViewModels/ServerListViewModel.swift` | Manages `[SavedConnection]` array, CRUD operations, status polling via `ServerStatusChecker`. Publishes `connections`, `selectedConnection`, `connectionStatuses: [UUID: Bool]`. |
| 1.9 | Create AddEditServerViewModel | `ViewModels/AddEditServerViewModel.swift` | Form state for add/edit: `name`, `host`, `port`, `useTLS` fields. Validation (non-empty host, valid port range). Save/delete actions that call back to `ServerListViewModel`. |
| 1.10 | Create ServerListWindow | `Views/ServerListWindow.swift` | SwiftUI `List` of saved servers with status indicators. Toolbar buttons for Add/Remove. Double-click to connect. Shown on first launch or via Preferences. |
| 1.11 | Create AddEditServerView | `Views/AddEditServerView.swift` | Form sheet for server configuration. Text fields for name, host, port. Toggle for TLS. Save/Cancel/Delete buttons. Presented as `.sheet` from ServerListWindow. |
| 1.12 | Create TerminalViewModel | `ViewModels/TerminalViewModel.swift` | Bridges `RelayConnection` to SwiftTerm macOS `TerminalView`. Receives binary data from `connection.onTerminalOutput` → calls `terminal.feed(byteArray:)`. Captures terminal input → `connection.sendBinary()`. Handles resize events → `connection.sendResize()`. |
| 1.13 | Create TerminalContainerView | `Views/TerminalContainerView.swift` | `NSViewRepresentable` wrapping SwiftTerm's macOS `TerminalView`. Coordinator handles `TerminalViewDelegate` callbacks. Binds to `TerminalViewModel` for I/O. Configures appearance: black background, font, cursor style. |
| 1.14 | Create MainWindow with basic auth + single session | `Views/MainWindow.swift`, `ViewModels/SessionCoordinator.swift` (minimal) | Basic main window with just a terminal view. On appear: connect to last-used server using `RelayConnection`, authenticate with stored token via `SessionController`, create a single session, wire terminal I/O. Minimal `SessionCoordinator` with `connect()`, `authenticate()`, `createSession()`. Menu bar icon shows connected/disconnected. |

**Phase 1 exit criteria**: App launches, connects to server, creates a session, terminal works (type commands, see output). Menu bar icon present. Closing window keeps app alive.

---

### Phase 2 — Session Management

**Goal**: Full session lifecycle with sidebar, cross-device attach, activity monitoring.

| # | Task | Files | Details |
|---|------|-------|---------|
| 2.1 | Expand SessionCoordinator | `ViewModels/SessionCoordinator.swift` | Full implementation: auth flow, session create/attach/resume/detach/terminate, terminal ViewModel cache (dictionary of `[UUID: TerminalViewModel]`), active session tracking. Wire `RelayConnection` callbacks: `onServerMessage`, `onTerminalOutput`, `onSessionActivity`, `onSessionStolen`, `onSessionRenamed`. Publish: `sessions: [SessionInfo]`, `activeSessionId: UUID?`, `activityStates: [UUID: ActivityState]`, `isAuthenticated: Bool`. |
| 2.2 | Create SessionSidebarView | `Views/SessionSidebarView.swift` | SwiftUI `List` with selection binding to `activeSessionId`. Each row: activity icon (●/◐/○), session name (or short ID), uptime. Right-click context menu: Rename, Detach, Terminate. "+ New Session" button at bottom. Selection changes switch the terminal in the detail pane. |
| 2.3 | Update MainWindow to NavigationSplitView | `Views/MainWindow.swift` | Refactor from single terminal to `NavigationSplitView` with `SessionSidebarView` in sidebar and `TerminalContainerView` in detail. Sidebar visibility toggleable. Wire selection to `SessionCoordinator.activeSessionId`. |
| 2.4 | Implement session create | `ViewModels/SessionCoordinator.swift` | `createSession(name:)`: call `sessionController.createSession(name:)`, create new `TerminalViewModel`, wire PTY output, add to cache, set as active, refresh session list. Handle `sessionCreated` response. |
| 2.5 | Implement session attach | `ViewModels/SessionCoordinator.swift` | `attachSession(id:)`: call `sessionController.attachSession(id:)`, create `TerminalViewModel` if not cached, wire PTY output, set as active. Handle scrollback replay (binary data received after `sessionAttached`). |
| 2.6 | Implement session resume | `ViewModels/SessionCoordinator.swift` | `resumeSession(id:)`: call `sessionController.resumeSession(id:)`, feed scrollback data to terminal (`terminal.feed`), wire live output. Handle terminal reset before replay to avoid rendering artifacts. |
| 2.7 | Implement session detach | `ViewModels/SessionCoordinator.swift` | `detachSession(id:)`: call `sessionController.detach()`, clear output handler on `TerminalViewModel`, keep VM in cache (for reattach). Update sidebar state. |
| 2.8 | Implement session terminate | `ViewModels/SessionCoordinator.swift` | `terminateSession(id:)`: call `sessionController` via `connection.send(.sessionTerminate)`, remove from cache, clean up TerminalViewModel. If terminated session was active, switch to next session or show empty state. |
| 2.9 | Implement cross-device attach | `ViewModels/SessionCoordinator.swift`, `Views/SessionSidebarView.swift` | Add "Attach Remote Session" action in sidebar or Session menu. Calls `sessionController.listAllSessions()` to show all sessions across all tokens. Display in a sheet with session list. Select to attach. Handle `sessionStolen` notification on the other device. |
| 2.10 | Implement session rename | `ViewModels/SessionCoordinator.swift`, `Views/SessionSidebarView.swift` | Double-click session name in sidebar or right-click → Rename. Show text field or alert. Call `sessionController.renameSession(id:, name:)`. Handle incoming `sessionRenamed` broadcasts from server to update other sessions renamed from other devices. |
| 2.11 | Implement activity state display | `Views/SessionSidebarView.swift`, `Views/StatusBarView.swift` | Map `ActivityState` to SF Symbols and colors in sidebar rows. `StatusBarView` at bottom of main window shows connection state + activity for focused session. Wire `SessionCoordinator.activityStates` to both views. |
| 2.12 | Create StatusBarView | `Views/StatusBarView.swift` | Bottom bar: left side shows "+ New Session" button, right side shows connection indicator (green dot + "Connected" / red dot + "Reconnecting...") and Claude activity text for active session ("Claude Running" / "Claude Idle" / "Idle"). |

**Phase 2 exit criteria**: Multiple sessions in sidebar, full lifecycle (create/attach/resume/detach/terminate), cross-device attach works, Claude activity indicators visible in sidebar and status bar, session rename works.

---

### Phase 3 — Mac-Native Polish

**Goal**: Keyboard-driven workflow, menu bar dropdown, preferences, network recovery. Feels like a native Mac app.

| # | Task | Files | Details |
|---|------|-------|---------|
| 3.1 | Build menu bar structure | `ClaudeRelayMacApp.swift` | Add `.commands` modifier to `WindowGroup`. Define `CommandGroup` and `CommandMenu` for File (New Session), Session (Detach, Terminate, Rename, Share QR, session list), View (Toggle Sidebar). Wire each to `SessionCoordinator` actions. |
| 3.2 | Implement keyboard shortcuts | `ClaudeRelayMacApp.swift`, `Views/MainWindow.swift` | Register shortcuts: `Cmd+T` (new session), `Cmd+W` (detach — override default close behavior when session is focused), `Cmd+Shift+W` (terminate), `Cmd+1..9` (session switch), `Cmd+0` (sidebar), `Cmd+Shift+[/]` (prev/next session), `Cmd+K` (clear terminal). Use `.keyboardShortcut` on `Button` in commands. |
| 3.3 | Create MenuBarViewModel | `ViewModels/MenuBarViewModel.swift` | Published state for menu bar dropdown: server name, connection state, session list with activity states. Driven by `SessionCoordinator`. Actions: switch session, open window, open preferences. |
| 3.4 | Create MenuBarDropdown | `Views/MenuBarDropdown.swift` | SwiftUI view rendered inside `MenuBarExtra(.window)`. Shows server name + connection state, divider, session list with activity icons (click to switch + open window), divider, "Open Window", "Preferences...", "Quit ClaudeRelay". |
| 3.5 | Create SettingsView | `Views/SettingsView.swift` | macOS Settings scene (`Cmd+,`). Tabs: General (launch at login, default server, naming theme), Speech (model download, shortcut config, prompt improvement toggle), Servers (embedded server list for management). Use `TabView` with `.tabViewStyle(.automatic)` for native macOS settings look. |
| 3.6 | Create NetworkMonitor | `Helpers/NetworkMonitor.swift` | Wraps `NWPathMonitor`. Publishes `isConnected: Bool`. On transition from disconnected → connected: notify `SessionCoordinator` to trigger immediate reconnect (bypass backoff delay). |
| 3.7 | Create SleepWakeObserver | `Helpers/SleepWakeObserver.swift` | Observes `NSWorkspace.shared.notificationCenter` for `willSleepNotification` and `didWakeNotification`. On wake: notify `SessionCoordinator` to run foreground recovery (ping → reconnect → re-auth → resume). |
| 3.8 | Implement foreground recovery | `ViewModels/SessionCoordinator.swift` | `recoverConnection()`: ping WebSocket via `connection.isAlive()`. If dead: `connection.forceReconnect()` → `sessionController.resetAuth()` → `authenticate()` → resume active session. Triggered by `SleepWakeObserver` and `NetworkMonitor`. Same logic as iOS `scenePhase` `.active` handler. |
| 3.9 | Implement session naming themes | `Models/AppSettings.swift`, `ViewModels/SessionCoordinator.swift` | Port naming theme lists from iOS (Star Wars, Dune, Lord of the Rings). Store selected theme in `AppSettings`. `SessionCoordinator.createSession()` picks next unused name from the active theme. Prune stale names (same logic as iOS fix in build 76). |
| 3.10 | Implement launch-at-login | `AppDelegate.swift`, `Views/SettingsView.swift` | Use `SMAppService.mainApp` (macOS 13+) to register/unregister launch at login. Toggle in Settings. When launched at login: start with window hidden, menu bar icon only, connect silently. |

**Phase 3 exit criteria**: Full menu bar with session commands, keyboard-driven workflow, preferences window, automatic reconnection on wake/network change, session naming themes, launch-at-login option.

---

### Phase 4 — Media & Speech

**Goal**: Image paste, QR code generation + scanning, on-device speech engine. Full feature parity with iOS.

| # | Task | Files | Details |
|---|------|-------|---------|
| 4.1 | Create ImagePasteHandler | `Helpers/ImagePasteHandler.swift` | Utility that inspects `NSPasteboard.general` for image data. `static func extractImage() -> Data?`: checks for PNG, TIFF, JPEG types, converts to PNG `Data`. Used by both clipboard paste and drag-and-drop paths. |
| 4.2 | Implement clipboard image paste | `Views/TerminalContainerView.swift`, `ViewModels/TerminalViewModel.swift` | Override paste handling in the terminal view's coordinator. On `Cmd+V`: check `ImagePasteHandler.extractImage()`. If image found: base64-encode, call `connection.sendPasteImage(base64Data:)`. If no image: let SwiftTerm handle the paste as text. |
| 4.3 | Implement drag-and-drop image paste | `Views/TerminalContainerView.swift` | Register terminal view for drop of `UTType.image` and `UTType.fileURL` (with image extensions). On drop: read image data via `NSItemProvider`, convert to PNG, base64-encode, send via `pasteImage`. Show brief visual feedback (border flash or drop indicator). |
| 4.4 | Create QRCodePopover | `Views/QRCodePopover.swift` | Generate QR code for `coderelay://<host>:<port>/attach?session=<id>&token=<token>`. Use `CIFilter("CIQRCodeGenerator")` + `CIContext` to render `NSImage`. Display in a popover anchored to toolbar button. Dismiss on click outside or session change. |
| 4.5 | Create QRScannerView | `Views/QRScannerView.swift` | `NSViewRepresentable` wrapping `AVCaptureSession` with `AVCaptureMetadataOutput` for QR code detection. Camera preview in a sheet. On scan: parse `coderelay://` URL, extract session ID and connection info, trigger session attach via `SessionCoordinator`. Requires `NSCameraUsageDescription`. |
| 4.6 | Create SpeechEngineState | `Speech/SpeechEngineState.swift` | Enum: `.idle`, `.loading`, `.recording`, `.transcribing`, `.cleaning`, `.enhancing`, `.inserting`, `.error(String)`. Same as iOS. |
| 4.7 | Create TextCleaner | `Speech/TextCleaner.swift` | Regex-based text normalization. Port from iOS — pure Foundation string processing, no platform dependencies. Removes filler words, normalizes whitespace, fixes common transcription artifacts. |
| 4.8 | Create AudioCaptureSession | `Speech/AudioCaptureSession.swift` | AVAudioEngine wrapper. Configures input node for 16kHz mono Float32 samples. `start()` / `stop()` control recording. Publishes audio buffer chunks. macOS-specific: may need to select input device if multiple mics available (use default input). |
| 4.9 | Create WhisperTranscriber | `Speech/WhisperTranscriber.swift` | WhisperKit CoreML/ANE wrapper. Loads model from `SpeechModelStore` path. Accepts `[Float]` audio samples, returns transcribed text. Includes silence hallucination filtering (same as iOS). |
| 4.10 | Create SpeechModelStore + CloudPromptEnhancer | `Speech/SpeechModelStore.swift`, `Speech/CloudPromptEnhancer.swift` | **SpeechModelStore**: Download and cache WhisperKit models in `~/Library/Application Support/ClaudeRelay/Models/`. Progress reporting for download UI in Settings. **CloudPromptEnhancer**: optional Anthropic Haiku API call to rewrite transcription into a clear prompt. Pure Foundation networking — port from iOS unchanged. |
| 4.11 | Create OnDeviceSpeechEngine | `Speech/OnDeviceSpeechEngine.swift` | Orchestrates the full pipeline: audio capture → Whisper transcription → text cleanup → optional cloud enhancement → terminal insertion. Published state via `SpeechEngineState`. Activated by configurable keyboard shortcut or toolbar mic button. `start()` begins recording, `stop()` processes and inserts result. |

**Phase 4 exit criteria**: Image paste works via clipboard and drag-and-drop. QR code can be generated and scanned. Speech-to-text works with WhisperKit. All iOS features have Mac equivalents.

---

### Phase 5 — Cross-Platform Refinement

**Goal**: Extract shared logic, align behavior, add test coverage.

| # | Task | Files | Details |
|---|------|-------|---------|
| 5.1 | Audit ViewModel differences | (analysis only) | Compare iOS and Mac ViewModels side-by-side. Document: which methods are identical, which have platform-specific wiring, which are fundamentally different. Identify extraction candidates. |
| 5.2 | Define shared protocols | `Sources/ClaudeRelayClient/` (new files) | Extract protocols for shared ViewModel interfaces: `SessionCoordinating`, `ServerListManaging`, `TerminalBridging`. Place in `ClaudeRelayClient` since they depend on `RelayConnection` and `SessionController`. Both apps conform to these protocols. |
| 5.3 | Extract shared business logic | `Sources/ClaudeRelayClient/` or new shared directory | Move platform-agnostic logic (auth flow, session lifecycle state machine, naming theme lists, activity state mapping) into shared types. Platform-specific code stays in each app with `#if os` only where minimal divergence exists. |
| 5.4 | Align wire protocol behavior | Both apps | Verify: both apps send identical wire messages for every operation. Check edge cases: reconnection timing, scrollback handling, activity state transitions, session stolen handling. Fix any divergence. |
| 5.5 | Add shared ViewModel tests | `Tests/ClaudeRelayClientTests/` (new) | Unit tests for extracted protocols and shared logic. Mock `RelayConnection` and `SessionController`. Test: auth flow, session lifecycle, naming themes, activity state mapping, reconnection logic. |
| 5.6 | Documentation update | `README.md`, `CLAUDE.md`, `CHANGELOG.md`, `ClaudeRelayApp/README.md` | Update all docs: add Mac app to architecture description, update project structure, add Mac build instructions, create `ClaudeRelayMac/README.md` setup guide. Update CHANGELOG with Mac app release. |

**Phase 5 exit criteria**: Shared logic extracted, both apps pass tests, documentation current, no behavioral divergence between iOS and Mac clients.

---

## 8. Dependencies

| Dependency | Version | Used For | Platform |
|------------|---------|----------|----------|
| ClaudeRelayKit | local SPM | Protocol models, types | macOS + iOS |
| ClaudeRelayClient | local SPM | WebSocket, auth, sessions | macOS + iOS |
| SwiftTerm | remote SPM | Terminal emulation (NSView) | macOS |
| WhisperKit | remote SPM | On-device speech transcription | macOS (CoreML) |
| LLM.swift | remote SPM | Text cleanup (Metal) | macOS |
| swift-argument-parser | remote SPM | (not used by Mac app, existing dep) | — |

No new external dependencies beyond what the iOS app already uses.

---

## 9. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| SwiftTerm macOS `TerminalView` behavior differs from iOS | Test early in Phase 1 — terminal is the critical path. SwiftTerm's macOS support is mature (used by its own sample app). |
| WhisperKit/LLM.swift on macOS ANE performance | Apple Silicon Macs have the same ANE as iPads. Test in Phase 4; if ANE isn't available (Intel Macs), fall back to CPU. |
| `MenuBarExtra` limitations | If `.window` style is too constrained, fall back to `NSStatusItem` + `NSPopover` with embedded SwiftUI view. Same visual result, more control. |
| Keyboard shortcut conflicts with terminal | Terminal needs raw key input. Shortcuts like `Cmd+W` must be intercepted at the app level before reaching SwiftTerm. Use SwiftUI `.commands` which take priority over view key handlers. |
| QR camera scanning UX on Mac | MacBook cameras point at the user, not at a phone screen. User needs to hold the phone up to the camera. This is acceptable — the primary flow is Mac generating QR for phone to scan. Camera scanning is the reverse convenience. |
