# CodeRelayMac

Native macOS terminal client for CodeRelay. Provides persistent terminal sessions with cross-device attach, Claude Code activity monitoring, server-side prompt optimization, image paste, and QR code session sharing.

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- A running CodeRelay server — `brew install miguelriotinto/clauderelay/clauderelay`

## Setup

1. **Generate the Xcode project** from the repo root:

   ```bash
   xcodegen generate
   ```

2. **Build and run** — open `CodeRelay.xcodeproj`, select the `CodeRelayMac` scheme, choose "My Mac" as the destination, and press `Cmd+R`.

## First Launch

The Server List sheet appears. Add a server (name, host, port, TLS toggle, auth token). Click **Connect**. The main terminal window opens.

Tokens are stored in the macOS Keychain (per-connection UUID).

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+T` | New session |
| `Cmd+W` | Detach current session |
| `Cmd+Shift+W` | Terminate current session |
| `Cmd+1..9` | Switch to session by index |
| `Cmd+0` | Toggle sidebar |
| `Cmd+Shift+[` / `Cmd+Shift+]` | Previous / next session |
| `Cmd+Shift+Q` | Scan QR code |
| `Cmd+,` | Preferences |

## Menu Bar

Closing the main window keeps the app running in the menu bar. Click the menu bar icon (`⌨︎` terminal symbol) for the dropdown with:

- Current server and connection status
- Session list with live activity icons (agent active / idle / awaiting input, per-agent colors)
- Quick switch — clicking a session activates it and focuses the main window
- Open Window, Preferences, Quit

`Cmd+Q` fully quits the app.

## Preferences

`Cmd+,` opens a tabbed settings window:

- **General** — session naming theme (Game of Thrones / Viking / Star Wars / Dune / Lord of the Rings), terminal font size, **terminal scrollback lines** (default 5000, configurable up to 25000; lower = less RAM, higher = more in-client history), "Show window on launch" toggle, "Launch at login" toggle (uses `SMAppService` on macOS 13+). It also holds two optimizer sections: **Prompt Optimizer** — the "Share terminal screen with the optimizer" toggle (default on; the footer states what is sent) — and **Optimizer Shortcut** — the keyboard shortcut that triggers the wand.
- **About** — version and build information.

Servers are managed in their own window (`ServerListWindow`), not in a Preferences tab.

## Foreground Recovery

When the Mac wakes from sleep or network connectivity is restored, the app:

1. Pings the WebSocket.
2. If dead, force-reconnects.
3. Re-authenticates.
4. Replays scrollback for the active session.

Observers are registered via `NSWorkspace.willSleepNotification` / `didWakeNotification` and `NWPathMonitor`.

## File Overview

```
CodeRelayMac/
  CodeRelayMacApp.swift           -- @main App with Window, MenuBarExtra, Settings scenes
  AppDelegate.swift                 -- NSApplicationDelegate: lifecycle, sleep/wake, window hiding
  CodeRelayMac.entitlements       -- Camera, network-client, sandboxing, file access, push entitlements
  Info.plist                        -- NSAppTransportSecurity (allows ws://) + CFBundleURLTypes
  Models/
    AppSettings.swift               -- User preferences (@AppStorage)
  ViewModels/
    ServerListViewModel.swift       -- Server list CRUD + status polling
    AddEditServerViewModel.swift    -- Add/edit form validation
    SessionCoordinator.swift        -- Auth, session lifecycle, I/O routing (conforms to SessionCoordinating)
    MenuBarViewModel.swift          -- Menu bar dropdown state mirror
  Views/
    MainWindow.swift                -- NavigationSplitView: sidebar + terminal + status bar
    ServerListWindow.swift          -- Server configuration window
    AddEditServerView.swift         -- Server config form (sheet)
    SessionSidebarView.swift        -- Session list with activity indicators
    TerminalContainerView.swift     -- NSViewRepresentable SwiftTerm wrapper + PasteAwareTerminalView
    SettingsView.swift              -- Preferences (General/About tabs; General holds the optimizer share-screen toggle + shortcut)
    StatusBarView.swift             -- Bottom connection/activity bar
    MenuBarDropdown.swift           -- Menu bar icon dropdown view
    QRCodePopover.swift             -- QR code generation popover
    QRScannerView.swift             -- AVFoundation camera QR scanner sheet
    AttachRemoteSessionSheet.swift  -- Cross-device attach picker
  Helpers/
    SleepWakeObserver.swift         -- NSWorkspace sleep/wake observer
    ImagePasteHandler.swift         -- Clipboard/drag-drop image extraction + PNG conversion
    AppCommands.swift               -- Menu bar commands with FocusedValue routing
    LaunchAtLogin.swift             -- SMAppService wrapper
    RecordingShortcutMonitor.swift  -- Global keyboard shortcut for the prompt optimizer
    KeyCaptureInterceptor.swift     -- Local NSEvent monitor for the Settings shortcut recorder (+ a diagnostic-only sendEvent swizzle)
```

Shared types that previously lived here (`TerminalViewModel`, `ServerStatusChecker`,
`SavedConnectionStore`, `NetworkMonitor`, `AgentColorPalette`, `ActivityDot`,
`ConnectionQualityDot`, `WandButton`) now live in `Sources/CodeRelayClient/`
(Views/ + ViewModels/ + Helpers/). `AgentColorPalette` specifically was
deduplicated in the 2026-05-04 review pass — iOS and macOS had byte-identical copies.

## What the Mac Shares with iOS

Both apps build on:

- **CodeRelayKit** — wire protocol (`ClientMessage`, `ServerMessage`, `MessageEnvelope`), session models, tokens, config, `CodingAgent` registry.
- **CodeRelayClient** — WebSocket transport (`RelayConnection`), `SessionController`, `AuthManager`, `SharedSessionCoordinator` (cross-platform coordinator with recovery, LRU-bounded terminal cache, `activityState(for:)` helper), `SessionCoordinating` protocol, `SessionNaming` helpers, `TerminalViewModel`, `ServerStatusChecker`, `SavedConnectionStore`, `NetworkMonitor`, `ConnectionConfig`, `DeviceIdentifier`, plus shared UI atoms (`ConnectionQualityDot`, `ActivityDot`, `AgentColorPalette`, `WandButton`) under `Views/`.

Each app's `SessionCoordinator` is a thin subclass of `SharedSessionCoordinator` that adds only platform-specific glue (macOS: `SleepWakeObserver` and tab navigation; iOS: `scenePhase`).

## Troubleshooting

- **"No camera available" when scanning QR** — grant camera permission in System Settings → Privacy & Security → Camera.
- **Can't connect via `ws://`** — the Info.plist includes `NSAllowsLocalNetworking=true`, which permits non-TLS WebSockets only to LAN/loopback addresses (see the main README's "When TLS is required"). If you rebuild with sandbox enabled, you may also need `com.apple.security.network.client` in the entitlements (already present).
- **Menu bar icon missing after launch-at-login** — make sure the app finished registering with `SMAppService.mainApp`. Toggle "Launch at login" off and on in Preferences once.
