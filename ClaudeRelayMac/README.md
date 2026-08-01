# ClaudeRelayMac

Native macOS terminal client for ClaudeRelay. Provides persistent terminal sessions with cross-device attach, Claude Code activity monitoring, on-device speech-to-text, image paste, and QR code session sharing.

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- A running ClaudeRelay server — `brew install miguelriotinto/clauderelay/clauderelay`

## Setup

1. **Generate the Xcode project** from the repo root:

   ```bash
   xcodegen generate
   ```

2. **Build and run** — open `ClaudeRelay.xcodeproj`, select the `ClaudeRelayMac` scheme, choose "My Mac" as the destination, and press `Cmd+R`.

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

- **General** — session naming theme (Game of Thrones / Viking / Star Wars / Dune / Lord of the Rings), terminal font size, **terminal scrollback lines** (default 5000, configurable up to 25000; lower = less RAM, higher = more in-client history), "Show window on launch" toggle, "Launch at login" toggle (uses `SMAppService` on macOS 13+).
- **Speech** — download Whisper and local cleanup LLM (~1 GB combined), toggle smart cleanup and Bedrock Haiku prompt enhancement, set AWS bearer token and region.
- **Servers** — embedded server list for CRUD.

## Foreground Recovery

When the Mac wakes from sleep or network connectivity is restored, the app:

1. Pings the WebSocket.
2. If dead, force-reconnects.
3. Re-authenticates.
4. Replays scrollback for the active session.

Observers are registered via `NSWorkspace.willSleepNotification` / `didWakeNotification` and `NWPathMonitor`.

## File Overview

```
ClaudeRelayMac/
  ClaudeRelayMacApp.swift           -- @main App with Window, MenuBarExtra, Settings scenes
  AppDelegate.swift                 -- NSApplicationDelegate: lifecycle, sleep/wake, window hiding
  ClaudeRelayMac.entitlements       -- Mic, camera, network-client entitlements
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
    SettingsView.swift              -- Preferences (General/Speech/Servers tabs)
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
    RecordingShortcutMonitor.swift  -- Global keyboard shortcut for speech recording
    KeyCaptureInterceptor.swift     -- Local NSEvent monitor (+ sendEvent swizzle fallback) for the Settings shortcut recorder
```

Shared types that previously lived here (`TerminalViewModel`, `ServerStatusChecker`,
`SavedConnectionStore`, `NetworkMonitor`, `AgentColorPalette`, `ActivityDot`,
`ConnectionQualityDot`, speech pipeline) now live in
`Sources/ClaudeRelayClient/` (Views/ + ViewModels/ + Helpers/) and
`Sources/ClaudeRelaySpeech/`. `AgentColorPalette` specifically was deduplicated
in the 2026-05-04 review pass — iOS and macOS had byte-identical copies.

## What the Mac Shares with iOS

Both apps build on:

- **ClaudeRelayKit** — wire protocol (`ClientMessage`, `ServerMessage`, `MessageEnvelope`), session models, tokens, config, `CodingAgent` registry.
- **ClaudeRelayClient** — WebSocket transport (`RelayConnection`), `SessionController`, `AuthManager`, `SharedSessionCoordinator` (cross-platform coordinator with recovery, LRU-bounded terminal cache, `activityState(for:)` helper), `SessionCoordinating` protocol, `SessionNaming` helpers, `TerminalViewModel`, `ServerStatusChecker`, `SavedConnectionStore`, `NetworkMonitor`, `ConnectionConfig`, `DeviceIdentifier`, plus shared UI atoms (`ConnectionQualityDot`, `ActivityDot`, `AgentColorPalette`) under `Views/`.
- **ClaudeRelaySpeech** — on-device speech pipeline: `OnDeviceSpeechEngine` orchestrator, `WhisperTranscriber`, `TextCleaner`, `CloudPromptEnhancer`, `AudioCaptureSession`, `SpeechModelStore`, `SpeechEngineState`. Platform differences (iOS `AVAudioSession`, iOS `UIApplication` memory-warning observer, per-OS model storage paths) are handled internally via `#if canImport(UIKit)` / `#if os(iOS)`.

Each app's `SessionCoordinator` is a thin subclass of `SharedSessionCoordinator` that adds only platform-specific glue (macOS: `SleepWakeObserver` and tab navigation; iOS: `scenePhase`).

## Troubleshooting

- **"No camera available" when scanning QR** — grant camera permission in System Settings → Privacy & Security → Camera.
- **Microphone not recording** — grant mic permission in System Settings → Privacy & Security → Microphone.
- **Can't connect via `ws://`** — the Info.plist includes `NSAllowsLocalNetworking=true`, which permits non-TLS WebSockets only to LAN/loopback addresses (see the main README's "When TLS is required"). If you rebuild with sandbox enabled, you may also need `com.apple.security.network.client` in the entitlements (already present).
- **Menu bar icon missing after launch-at-login** — make sure the app finished registering with `SMAppService.mainApp`. Toggle "Launch at login" off and on in Preferences once.
