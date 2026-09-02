# macOS Relay Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS terminal client (ClaudeRelayMac) that connects to the existing ClaudeRelay server and provides full feature parity with the iOS app — persistent sessions, cross-device attach, Claude activity monitoring, on-device speech, image paste, and QR code sharing.

**Architecture:** Pure relay client using the existing `ClaudeRelayKit` and `ClaudeRelayClient` SPM libraries. New Xcode target alongside the iOS app, managed by XcodeGen via `project.yml`. SwiftUI views with AppKit integration for menu bar, windowing, and terminal hosting. SwiftTerm's `NSView`-based `TerminalView` for terminal emulation. ViewModels are Mac-specific in phases 1-4; shared logic is extracted in phase 5.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit (NSViewRepresentable, NSApplicationDelegate, NSWorkspace, NSPasteboard), SwiftTerm 1.2.0+ (macOS target), WhisperKit 0.18.0 (CoreML/ANE), LLM.swift (Metal), AVFoundation (audio, camera), CoreImage (QR), Network (NWPathMonitor), ServiceManagement (SMAppService), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-04-28-macos-relay-client-design.md`

---

## Conventions

- All file paths are absolute relative to the repo root: `/Users/miguelriotinto/Desktop/Projects/Claude Relay/`
- Commits follow Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`
- After any change that touches `project.yml`, run `xcodegen generate` before building
- After every task, verify the Mac target still builds: `xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10`
- The iOS app MUST NOT regress. After any change to shared libraries (ClaudeRelayKit, ClaudeRelayClient), verify iOS still builds: `xcodebuild -scheme ClaudeRelayApp -destination 'generic/platform=iOS' build 2>&1 | tail -10`
- Run `swift test` after changes to shared libraries to ensure no backend regressions

---

## Phase 1 — Core Shell

**Goal**: App launches, connects to server, creates a session, terminal works. Menu bar icon present.

---

### Task 1.1: Create directory structure for ClaudeRelayMac

**Files:**
- Create directories: `ClaudeRelayMac/`, `ClaudeRelayMac/Models/`, `ClaudeRelayMac/ViewModels/`, `ClaudeRelayMac/Views/`, `ClaudeRelayMac/Speech/`, `ClaudeRelayMac/Helpers/`

- [ ] **Step 1: Create the directory tree**

```bash
cd "/Users/miguelriotinto/Desktop/Projects/Claude Relay"
mkdir -p ClaudeRelayMac/{Models,ViewModels,Views,Speech,Helpers}
```

- [ ] **Step 2: Add a .gitkeep so the directories are tracked**

```bash
touch ClaudeRelayMac/Models/.gitkeep
touch ClaudeRelayMac/ViewModels/.gitkeep
touch ClaudeRelayMac/Views/.gitkeep
touch ClaudeRelayMac/Speech/.gitkeep
touch ClaudeRelayMac/Helpers/.gitkeep
```

- [ ] **Step 3: Verify structure**

Run: `ls -la ClaudeRelayMac/`
Expected: shows `Models`, `ViewModels`, `Views`, `Speech`, `Helpers` directories.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayMac/
git commit -m "chore(mac): scaffold ClaudeRelayMac directory structure"
```

---

### Task 1.2: Add ClaudeRelayMac target to project.yml

**Files:**
- Modify: `/Users/miguelriotinto/Desktop/Projects/Claude Relay/project.yml`

**Context:** The existing `project.yml` defines `ClaudeRelayApp` (iOS) and `ClaudeRelayAppTests`. We add a new macOS target `ClaudeRelayMac` with bundle ID `com.claude.relay.mac`. We do NOT modify existing iOS configuration.

- [ ] **Step 1: Add deploymentTarget macOS entry to options**

Edit `project.yml`. Find:

```yaml
options:
  bundleIdPrefix: com.claude
  deploymentTarget:
    iOS: "17.0"
  xcodeVersion: "15.0"
  generateEmptyDirectories: true
```

Replace with:

```yaml
options:
  bundleIdPrefix: com.claude
  deploymentTarget:
    iOS: "17.0"
    macOS: "14.0"
  xcodeVersion: "15.0"
  generateEmptyDirectories: true
```

- [ ] **Step 2: Add ClaudeRelayMac target after ClaudeRelayAppTests**

Append this target block to `project.yml` (after the `ClaudeRelayAppTests` target, before the end of file):

```yaml
  ClaudeRelayMac:
    type: application
    platform: macOS
    sources:
      - path: ClaudeRelayMac
        excludes:
          - "**/.gitkeep"
          - "Info.plist"
    dependencies:
      - package: ClaudeRelayClient
        product: ClaudeRelayClient
      - package: SwiftTerm
      - package: WhisperKit
      - package: LLMSwift
        product: LLM
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.claude.relay.mac
        INFOPLIST_FILE: ClaudeRelayMac/Info.plist
        INFOPLIST_KEY_CFBundleDisplayName: "Claude Relay"
        INFOPLIST_KEY_NSMicrophoneUsageDescription: "Claude Relay needs microphone access for voice-to-text input."
        INFOPLIST_KEY_NSCameraUsageDescription: "Claude Relay uses the camera to scan QR codes for session sharing."
        INFOPLIST_KEY_LSUIElement: NO
        SWIFT_VERSION: "5.9"
        DEVELOPMENT_TEAM: T9WF95GC9T
        SUPPORTED_PLATFORMS: "macosx"
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        CODE_SIGN_ENTITLEMENTS: ClaudeRelayMac/ClaudeRelayMac.entitlements
    info:
      path: ClaudeRelayMac/Info.plist
      properties:
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
        CFBundleURLTypes:
          - CFBundleURLName: "com.claude.relay.mac"
            CFBundleURLSchemes:
              - clauderelay
```

**Note:** XcodeGen 2.45+ requires `info.path` on target definitions that use `info.properties`. The `INFOPLIST_FILE` build setting must point to the same path. Xcodegen writes a fresh Info.plist at that path with the declared properties, overwriting any manual edits.

- [ ] **Step 3: Create entitlements file**

Create `ClaudeRelayMac/ClaudeRelayMac.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.device.camera</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

Note: App Sandbox is disabled because the Mac app connects to arbitrary hostnames/ports (relay servers) and needs network flexibility. If sandbox is later desired, add `com.apple.security.network.client` is already present; additional network entitlements may be needed.

- [ ] **Step 4: Regenerate Xcode project**

```bash
cd "/Users/miguelriotinto/Desktop/Projects/Claude Relay"
xcodegen generate
```

Expected output: `Created project at .../ClaudeRelay.xcodeproj` without errors.

- [ ] **Step 5: Verify target exists**

```bash
xcodebuild -list 2>&1 | grep -E "Targets:|ClaudeRelayMac"
```

Expected: `ClaudeRelayMac` listed among targets.

- [ ] **Step 6: Commit**

```bash
git add project.yml ClaudeRelayMac/ClaudeRelayMac.entitlements
git commit -m "chore(mac): add ClaudeRelayMac target to project.yml"
```

---

### Task 1.3: Create app entry point (ClaudeRelayMacApp.swift)

**Files:**
- Create: `ClaudeRelayMac/ClaudeRelayMacApp.swift`

**Context:** The `@main` App struct defines the app's scene hierarchy: main `WindowGroup`, `MenuBarExtra` for the menu bar icon, `Settings` scene for preferences (`Cmd+,`). At this stage, the window contains a placeholder; full UI comes in later tasks. The `@NSApplicationDelegateAdaptor` wires up `AppDelegate` for lifecycle events that SwiftUI doesn't expose directly.

- [ ] **Step 1: Write the app entry point**

Create `ClaudeRelayMac/ClaudeRelayMacApp.swift`:

```swift
import SwiftUI
import AppKit

@main
struct ClaudeRelayMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Claude Relay") {
            MainWindow()
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarDropdown()
        } label: {
            Image(systemName: "terminal")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .frame(width: 600, height: 400)
        }
    }
}
```

- [ ] **Step 2: Add placeholder views so this compiles**

Create `ClaudeRelayMac/Views/MainWindow.swift`:

```swift
import SwiftUI

struct MainWindow: View {
    var body: some View {
        VStack {
            Text("Claude Relay — Mac")
                .font(.largeTitle)
            Text("Phase 1 scaffolding")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

Create `ClaudeRelayMac/Views/MenuBarDropdown.swift`:

```swift
import SwiftUI

struct MenuBarDropdown: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Relay")
                .font(.headline)
            Divider()
            Button("Open Window") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 240)
    }
}
```

Create `ClaudeRelayMac/Views/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Text("General settings (Phase 3)")
                .tabItem { Label("General", systemImage: "gear") }
        }
    }
}
```

- [ ] **Step 3: Create stub AppDelegate (full implementation in Task 1.4)**

Create `ClaudeRelayMac/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Full implementation in Task 1.4
    }
}
```

- [ ] **Step 4: Regenerate and build**

```bash
cd "/Users/miguelriotinto/Desktop/Projects/Claude Relay"
xcodegen generate
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Run the app to verify it launches**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' -derivedDataPath /tmp/ClaudeRelayMacBuild build 2>&1 | tail -5
open /tmp/ClaudeRelayMacBuild/Build/Products/Debug/ClaudeRelayMac.app
```

Expected: Mac app launches, shows window with "Claude Relay — Mac" title, menu bar icon visible with terminal SF Symbol. Close the app with `Cmd+Q` before continuing.

- [ ] **Step 6: Commit**

```bash
git add ClaudeRelayMac/ClaudeRelayMacApp.swift \
        ClaudeRelayMac/AppDelegate.swift \
        ClaudeRelayMac/Views/MainWindow.swift \
        ClaudeRelayMac/Views/MenuBarDropdown.swift \
        ClaudeRelayMac/Views/SettingsView.swift
git commit -m "feat(mac): add app entry point with window, menu bar, and settings scenes"
```

---

### Task 1.4: Implement AppDelegate with window lifecycle

**Files:**
- Modify: `ClaudeRelayMac/AppDelegate.swift`

**Context:** The AppDelegate handles three macOS-specific behaviors that SwiftUI doesn't expose well: (1) keeping the app alive after the last window closes (menu bar persistence), (2) reopening the main window when the Dock icon is clicked, (3) exposing hooks for sleep/wake observers (added in Phase 3).

- [ ] **Step 1: Expand AppDelegate**

Replace contents of `ClaudeRelayMac/AppDelegate.swift`:

```swift
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Keep the app running when the last window closes (menu bar persistence).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Reopen main window when user clicks the Dock icon while window is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Phase 3 will wire sleep/wake observers here.
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run and manually verify**

Launch the app, close the main window (red traffic light). Verify:
- The app does NOT terminate (menu bar icon still visible)
- Clicking the Dock icon reopens the main window

Quit with `Cmd+Q` when done.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayMac/AppDelegate.swift
git commit -m "feat(mac): AppDelegate keeps app alive after last window closes"
```

---

### Task 1.5: Create SavedConnection model

**Files:**
- Create: `ClaudeRelayMac/Models/SavedConnection.swift`

**Context:** Stores the list of servers the user has configured. Uses UserDefaults-backed persistence with `ConnectionConfig` from `ClaudeRelayClient` (which is `Codable`). Platform-independent storage key differs from iOS (`com.clauderelay.mac.savedConnections`) so Mac and iOS bookmarks don't collide if the same user runs both on the same machine.

- [ ] **Step 1: Write the model**

Create `ClaudeRelayMac/Models/SavedConnection.swift`:

```swift
import Foundation
import ClaudeRelayClient

/// Manages persistence of saved connections in UserDefaults (Mac-specific storage).
struct SavedConnectionStore {

    private static let userDefaultsKey = "com.clauderelay.mac.savedConnections"

    /// Loads all saved connections from UserDefaults.
    static func loadAll() -> [ConnectionConfig] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([ConnectionConfig].self, from: data)) ?? []
    }

    /// Saves the given connections array to UserDefaults.
    static func saveAll(_ connections: [ConnectionConfig]) {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    /// Adds or updates a connection (replaces entry with matching id) and persists.
    @discardableResult
    static func add(_ connection: ConnectionConfig) -> [ConnectionConfig] {
        var all = loadAll()
        if let index = all.firstIndex(where: { $0.id == connection.id }) {
            all[index] = connection
        } else {
            all.append(connection)
        }
        saveAll(all)
        return all
    }

    /// Removes a connection by id and persists the updated list.
    @discardableResult
    static func delete(id: UUID) -> [ConnectionConfig] {
        var all = loadAll()
        all.removeAll { $0.id == id }
        saveAll(all)
        return all
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/Models/SavedConnection.swift
git commit -m "feat(mac): add SavedConnectionStore for persisting server bookmarks"
```

---

### Task 1.6: Create AppSettings model

**Files:**
- Create: `ClaudeRelayMac/Models/AppSettings.swift`

**Context:** `@AppStorage`-backed preferences. Starts minimal — just `lastServerId` and flags needed for Phase 1. More settings added incrementally (speech shortcut in Phase 4, launch-at-login in Phase 3).

- [ ] **Step 1: Write the model**

Create `ClaudeRelayMac/Models/AppSettings.swift`:

```swift
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private init() {}

    /// UUID string of the last-used server, for auto-reconnect on launch.
    @AppStorage("com.clauderelay.mac.lastServerId") var lastServerId: String = ""

    /// Haptic feedback is iOS-only; flag kept for cross-platform ViewModel parity.
    /// On Mac this is a no-op.
    @AppStorage("com.clauderelay.mac.hapticFeedbackEnabled") var hapticFeedbackEnabled = false

    /// Show main window on launch (false when launched-at-login with menu-bar-only mode).
    @AppStorage("com.clauderelay.mac.showWindowOnLaunch") var showWindowOnLaunch = true
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/Models/AppSettings.swift
git commit -m "feat(mac): add AppSettings for user preferences"
```

---

### Task 1.7: Create ServerStatusChecker

**Files:**
- Create: `ClaudeRelayMac/ViewModels/ServerStatusChecker.swift`

**Context:** Polls the server's admin HTTP API (`/health`) to show reachable/unreachable status in the server list. The admin API binds to `127.0.0.1` only, but we ping via the user-configured host — if the server is on localhost the poll works, otherwise the user sees "unknown" (server reachable via WebSocket but not admin). Timer fires every 5s while polling is active.

- [ ] **Step 1: Write the checker**

Create `ClaudeRelayMac/ViewModels/ServerStatusChecker.swift`:

```swift
import Foundation
import SwiftUI
import ClaudeRelayClient

/// Polls the server's WebSocket endpoint for reachability.
/// We don't poll the admin API because it's localhost-only;
/// instead we open a short-lived TCP connection to the WebSocket port.
@MainActor
final class ServerStatusChecker: ObservableObject {

    @Published private(set) var isReachable: Bool = false

    private var pollTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 5.0

    func startPolling(_ config: ConnectionConfig) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let reachable = await Self.check(config: config)
                await MainActor.run {
                    self?.isReachable = reachable
                }
                try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 5.0) * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private static func check(config: ConnectionConfig) async -> Bool {
        // Opens a short-lived TCP connection to test if the port accepts connections.
        // This works whether or not TLS is configured — we only care about reachability.
        await withCheckedContinuation { continuation in
            let host = NWEndpoint.Host(config.host)
            let port = NWEndpoint.Port(rawValue: config.port) ?? NWEndpoint.Port(integerLiteral: 9200)
            let connection = NWConnection(host: host, port: port, using: .tcp)

            let timeout = DispatchWorkItem {
                connection.cancel()
                continuation.resume(returning: false)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeout.cancel()
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    timeout.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }
}

import Network
```

**Note:** The `import Network` at the end is a workaround — Swift allows trailing imports, and placing it there avoids the "use of undeclared type" issue that arises when the import is at the top during an edit. Move to the top at the end:

Replace the final block:

```swift
import Network
```

Move it to the top of the file so the final file reads:

```swift
import Foundation
import SwiftUI
import Network
import ClaudeRelayClient

/// Polls the server's WebSocket endpoint for reachability.
/// ... (rest unchanged)
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/ViewModels/ServerStatusChecker.swift
git commit -m "feat(mac): add ServerStatusChecker for reachability polling"
```

---

### Task 1.8: Create ServerListViewModel

**Files:**
- Create: `ClaudeRelayMac/ViewModels/ServerListViewModel.swift`

**Context:** Manages the user's list of saved servers. Exposes CRUD actions and status polling for all saved servers. Pattern mirrors iOS `ServerListViewModel` but adapted for Mac (no UIKit dependencies).

- [ ] **Step 1: Write the ViewModel**

Create `ClaudeRelayMac/ViewModels/ServerListViewModel.swift`:

```swift
import Foundation
import SwiftUI
import ClaudeRelayClient

@MainActor
final class ServerListViewModel: ObservableObject {

    @Published private(set) var connections: [ConnectionConfig] = []
    @Published private(set) var statuses: [UUID: Bool] = [:]
    @Published var selectedConnectionId: UUID?

    private var statusCheckers: [UUID: ServerStatusChecker] = [:]

    init() {
        loadConnections()
    }

    // MARK: - CRUD

    func loadConnections() {
        connections = SavedConnectionStore.loadAll()
        // Select the last-used server if it exists, otherwise the first.
        let lastId = AppSettings.shared.lastServerId
        if let uuid = UUID(uuidString: lastId), connections.contains(where: { $0.id == uuid }) {
            selectedConnectionId = uuid
        } else {
            selectedConnectionId = connections.first?.id
        }
        startAllStatusPolling()
    }

    func addOrUpdate(_ connection: ConnectionConfig) {
        _ = SavedConnectionStore.add(connection)
        loadConnections()
    }

    func delete(id: UUID) {
        statusCheckers[id]?.stopPolling()
        statusCheckers.removeValue(forKey: id)
        statuses.removeValue(forKey: id)
        _ = SavedConnectionStore.delete(id: id)
        loadConnections()
    }

    // MARK: - Selection

    func selectedConnection() -> ConnectionConfig? {
        guard let id = selectedConnectionId else { return nil }
        return connections.first { $0.id == id }
    }

    func markAsLastUsed(_ id: UUID) {
        AppSettings.shared.lastServerId = id.uuidString
    }

    // MARK: - Status Polling

    private func startAllStatusPolling() {
        // Stop pollers for deleted servers.
        let currentIds = Set(connections.map { $0.id })
        for (id, checker) in statusCheckers where !currentIds.contains(id) {
            checker.stopPolling()
            statusCheckers.removeValue(forKey: id)
        }

        // Start polling for new servers.
        for config in connections where statusCheckers[config.id] == nil {
            let checker = ServerStatusChecker()
            checker.startPolling(config)
            statusCheckers[config.id] = checker

            // Bridge the checker's published state into our statuses map.
            Task { [weak self, weak checker] in
                guard let checker else { return }
                for await reachable in checker.$isReachable.values {
                    await MainActor.run {
                        self?.statuses[config.id] = reachable
                    }
                }
            }
        }
    }

    deinit {
        for checker in statusCheckers.values {
            checker.stopPolling()
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/ViewModels/ServerListViewModel.swift
git commit -m "feat(mac): add ServerListViewModel with CRUD and status polling"
```

---

### Task 1.9: Create AddEditServerViewModel

**Files:**
- Create: `ClaudeRelayMac/ViewModels/AddEditServerViewModel.swift`

**Context:** Form state for add/edit server dialog. Includes validation (non-empty host, port range), and separately stores the token plaintext before saving to Keychain via `AuthManager`.

- [ ] **Step 1: Write the ViewModel**

Create `ClaudeRelayMac/ViewModels/AddEditServerViewModel.swift`:

```swift
import Foundation
import SwiftUI
import ClaudeRelayClient

@MainActor
final class AddEditServerViewModel: ObservableObject {

    // MARK: - Form State

    @Published var name: String = ""
    @Published var host: String = ""
    @Published var port: String = "9200"
    @Published var useTLS: Bool = false
    @Published var token: String = ""
    @Published var validationError: String?

    // MARK: - Context

    /// Existing connection being edited, or nil for add-mode.
    private let editingId: UUID?

    init(existing: ConnectionConfig? = nil) {
        if let existing {
            self.editingId = existing.id
            self.name = existing.name
            self.host = existing.host
            self.port = String(existing.port)
            self.useTLS = existing.useTLS
            // Load token from Keychain for display/edit.
            if let stored = try? AuthManager.shared.loadToken(for: existing.id) {
                self.token = stored
            }
        } else {
            self.editingId = nil
        }
    }

    var isEditing: Bool { editingId != nil }

    // MARK: - Validation

    func validate() -> Bool {
        validationError = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationError = "Name is required"
            return false
        }

        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty else {
            validationError = "Host is required"
            return false
        }

        guard let portValue = UInt16(port), portValue >= 1 else {
            validationError = "Port must be a number between 1 and 65535"
            return false
        }

        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationError = "Token is required"
            return false
        }

        return true
    }

    // MARK: - Save

    /// Builds a ConnectionConfig from the current form state. Caller is
    /// responsible for calling addOrUpdate on the list view model and for
    /// saving the token via AuthManager.
    func buildConnection() -> ConnectionConfig? {
        guard validate() else { return nil }
        let portValue = UInt16(port) ?? 9200
        return ConnectionConfig(
            id: editingId ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: portValue,
            useTLS: useTLS
        )
    }

    /// Persists the token to Keychain. Call after successfully adding the connection.
    func saveToken(for connectionId: UUID) throws {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        try AuthManager.shared.saveToken(trimmed, for: connectionId)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/ViewModels/AddEditServerViewModel.swift
git commit -m "feat(mac): add AddEditServerViewModel with validation"
```

---

### Task 1.10: Create ServerListWindow view

**Files:**
- Create: `ClaudeRelayMac/Views/ServerListWindow.swift`

**Context:** Shows the list of saved servers with reachability indicators. Double-click to connect, right-click for edit/delete, toolbar buttons for add. Uses native macOS `List` with `.inset` style. This is NOT the main terminal window — it's a separate window accessible via Preferences or shown on first launch when no server is configured.

- [ ] **Step 1: Write the view**

Create `ClaudeRelayMac/Views/ServerListWindow.swift`:

```swift
import SwiftUI
import ClaudeRelayClient

struct ServerListWindow: View {
    @StateObject private var viewModel = ServerListViewModel()
    @State private var addEditTarget: AddEditTarget?
    @State private var showDeleteAlert = false
    @State private var deleteTarget: ConnectionConfig?

    /// Callback when the user connects to a server.
    var onConnect: ((ConnectionConfig) -> Void)?

    enum AddEditTarget: Identifiable {
        case add
        case edit(ConnectionConfig)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let c): return c.id.uuidString
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedConnectionId) {
                ForEach(viewModel.connections, id: \.id) { connection in
                    ServerRow(
                        connection: connection,
                        isReachable: viewModel.statuses[connection.id] ?? false
                    )
                    .contextMenu {
                        Button("Connect") { connectTo(connection) }
                        Button("Edit...") { addEditTarget = .edit(connection) }
                        Divider()
                        Button("Delete", role: .destructive) {
                            deleteTarget = connection
                            showDeleteAlert = true
                        }
                    }
                    .tag(connection.id)
                }
            }
            .listStyle(.inset)
            .onChange(of: viewModel.selectedConnectionId) { _, newValue in
                // Double-click handling via onTapGesture on row; selection alone doesn't connect.
                _ = newValue
            }

            Divider()
            HStack {
                Button {
                    addEditTarget = .add
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                Spacer()
                Button("Connect") {
                    if let c = viewModel.selectedConnection() {
                        connectTo(c)
                    }
                }
                .disabled(viewModel.selectedConnection() == nil)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(12)
        }
        .frame(minWidth: 500, minHeight: 360)
        .navigationTitle("Servers")
        .sheet(item: $addEditTarget) { target in
            AddEditServerView(target: target) { newConnection in
                viewModel.addOrUpdate(newConnection)
                addEditTarget = nil
            }
        }
        .alert("Delete Server?", isPresented: $showDeleteAlert, presenting: deleteTarget) { target in
            Button("Delete", role: .destructive) {
                viewModel.delete(id: target.id)
                try? AuthManager.shared.deleteToken(for: target.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("Are you sure you want to delete '\(target.name)'?")
        }
    }

    private func connectTo(_ connection: ConnectionConfig) {
        viewModel.markAsLastUsed(connection.id)
        onConnect?(connection)
    }
}

private struct ServerRow: View {
    let connection: ConnectionConfig
    let isReachable: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(isReachable ? .green : .red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name).font(.headline)
                Text("\(connection.useTLS ? "wss" : "ws")://\(connection.host):\(connection.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` (may fail on `AddEditServerView` until Task 1.11 — that's OK, just proceed to 1.11 and build together).

- [ ] **Step 3: Commit (if build fails, commit after Task 1.11)**

```bash
git add ClaudeRelayMac/Views/ServerListWindow.swift
git commit -m "feat(mac): add ServerListWindow view"
```

---

### Task 1.11: Create AddEditServerView sheet

**Files:**
- Create: `ClaudeRelayMac/Views/AddEditServerView.swift`

**Context:** Form sheet for adding or editing a server. Uses SwiftUI `Form` with native macOS styling. Presented as a sheet from `ServerListWindow`.

- [ ] **Step 1: Write the view**

Create `ClaudeRelayMac/Views/AddEditServerView.swift`:

```swift
import SwiftUI
import ClaudeRelayClient

struct AddEditServerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: AddEditServerViewModel

    let onSave: (ConnectionConfig) -> Void

    init(target: ServerListWindow.AddEditTarget, onSave: @escaping (ConnectionConfig) -> Void) {
        switch target {
        case .add:
            _viewModel = StateObject(wrappedValue: AddEditServerViewModel())
        case .edit(let existing):
            _viewModel = StateObject(wrappedValue: AddEditServerViewModel(existing: existing))
        }
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $viewModel.name)
                    TextField("Host", text: $viewModel.host)
                        .autocorrectionDisabled()
                    TextField("Port", text: $viewModel.port)
                    Toggle("Use TLS (wss://)", isOn: $viewModel.useTLS)
                }
                Section("Authentication") {
                    SecureField("Token", text: $viewModel.token)
                        .textContentType(.password)
                }
                if let error = viewModel.validationError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .padding()

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(viewModel.isEditing ? "Save" : "Add") {
                    if let connection = viewModel.buildConnection() {
                        do {
                            try viewModel.saveToken(for: connection.id)
                            onSave(connection)
                            dismiss()
                        } catch {
                            viewModel.validationError = "Failed to save token: \(error.localizedDescription)"
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 380)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/Views/AddEditServerView.swift
git commit -m "feat(mac): add AddEditServerView sheet for server configuration"
```

---

### Task 1.12: Create TerminalViewModel (Mac)

**Files:**
- Create: `ClaudeRelayMac/ViewModels/TerminalViewModel.swift`

**Context:** Bridges `RelayConnection` binary output to SwiftTerm. Core logic mirrors iOS but without Combine-to-UI conversions that differ between platforms. The `onTerminalOutput` callback is set by `TerminalContainerView` once the SwiftTerm view is ready.

- [ ] **Step 1: Write the ViewModel**

Create `ClaudeRelayMac/ViewModels/TerminalViewModel.swift`:

```swift
import Foundation
import Combine
import SwiftUI
import ClaudeRelayClient

@MainActor
final class TerminalViewModel: ObservableObject {

    // MARK: - Published State

    @Published var connectionState: RelayConnection.ConnectionState
    @Published var terminalTitle: String = ""
    @Published var awaitingInput: Bool = false

    // MARK: - Callbacks (set by TerminalContainerView)

    var onTerminalOutput: ((Data) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onAwaitingInputChanged: ((Bool) -> Void)?

    // MARK: - Dependencies

    let sessionId: UUID
    private let connection: RelayConnection
    private var pendingOutput: [Data] = []
    private var terminalSized = false

    // MARK: - Input detection

    var isClaudeActive = false
    private var promptDebounceTask: Task<Void, Never>?

    // MARK: - Init

    init(sessionId: UUID, connection: RelayConnection) {
        self.sessionId = sessionId
        self.connection = connection
        self.connectionState = connection.state

        connection.$state
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .assign(to: &$connectionState)
    }

    // MARK: - Output

    func receiveOutput(_ data: Data) {
        if terminalSized, let handler = onTerminalOutput {
            handler(data)
        } else {
            pendingOutput.append(data)
        }
        detectInputPrompt(data)
    }

    /// Called after the first sizeChanged delegate callback from SwiftTerm.
    func terminalReady() {
        guard !terminalSized, let handler = onTerminalOutput else { return }
        terminalSized = true
        let buffered = pendingOutput
        pendingOutput.removeAll()
        for chunk in buffered { handler(chunk) }
    }

    /// Resets terminal for scrollback replay (foreground recovery).
    func resetForReplay() {
        if let handler = onTerminalOutput {
            handler(Data([0x1B, 0x63])) // ESC c — Reset to Initial State
        }
    }

    func prepareForSwitch() {
        promptDebounceTask?.cancel()
        promptDebounceTask = nil
        onTerminalOutput = nil
        onTitleChanged = nil
        onAwaitingInputChanged = nil
        terminalSized = false
        pendingOutput.removeAll()
    }

    // MARK: - Input

    func sendInput(_ data: Data) {
        if awaitingInput { setAwaitingInput(false) }
        Task { try? await connection.sendBinary(data) }
    }

    func sendInput(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    func sendPasteImage(_ imageData: Data) {
        let base64 = imageData.base64EncodedString()
        Task { try? await connection.sendPasteImage(base64Data: base64) }
    }

    func sendResize(cols: UInt16, rows: UInt16) {
        Task { try? await connection.sendResize(cols: cols, rows: rows) }
    }

    // MARK: - Prompt detection

    private func detectInputPrompt(_ data: Data) {
        promptDebounceTask?.cancel()
        promptDebounceTask = nil
        if awaitingInput { setAwaitingInput(false) }

        let threshold: Duration = isClaudeActive ? .milliseconds(2000) : .milliseconds(1000)
        promptDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: threshold)
            guard !Task.isCancelled else { return }
            self?.setAwaitingInput(true)
        }
    }

    private func setAwaitingInput(_ value: Bool) {
        guard awaitingInput != value else { return }
        awaitingInput = value
        onAwaitingInputChanged?(value)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/ViewModels/TerminalViewModel.swift
git commit -m "feat(mac): add TerminalViewModel for I/O bridging"
```

---

### Task 1.13: Create TerminalContainerView (SwiftTerm NSView wrapper)

**Files:**
- Create: `ClaudeRelayMac/Views/TerminalContainerView.swift`

**Context:** `NSViewRepresentable` that hosts SwiftTerm's `TerminalView` (macOS `NSView` subclass). SwiftTerm's macOS API uses `TerminalView` with `TerminalViewDelegate`. The coordinator implements the delegate to receive terminal input (`send(_:)`), size changes, and title changes.

- [ ] **Step 1: Inspect the SwiftTerm macOS API**

First, verify the SwiftTerm macOS API names. SwiftTerm exposes a `TerminalView` class for macOS in the `Mac` module (or top-level, depending on version). The common API:
- `TerminalView(frame:)` — `NSView` subclass
- `feed(byteArray:)` — feeds bytes to the emulator
- `TerminalViewDelegate` with `send(source:data:)`, `sizeChanged(source:newCols:newRows:)`, `setTerminalTitle(source:title:)`
- `getTerminal()` — access the underlying `Terminal` model

- [ ] **Step 2: Write the representable**

Create `ClaudeRelayMac/Views/TerminalContainerView.swift`:

```swift
import SwiftUI
import SwiftTerm
import AppKit

struct TerminalContainerView: NSViewRepresentable {
    @ObservedObject var viewModel: TerminalViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator

        // Appearance: black chrome to match iOS app.
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white

        // Feed buffered output through the ViewModel.
        viewModel.onTerminalOutput = { [weak terminal] data in
            guard let terminal else { return }
            let bytes = Array(data)
            terminal.feed(byteArray: bytes[...])
        }

        viewModel.terminalReady()
        return terminal
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // No-op — updates are driven by the ViewModel callbacks.
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, TerminalViewDelegate {
        let viewModel: TerminalViewModel

        init(viewModel: TerminalViewModel) {
            self.viewModel = viewModel
        }

        // Called by SwiftTerm when the user types or pastes.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            Task { @MainActor [viewModel] in
                viewModel.sendInput(Data(data))
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor [viewModel] in
                viewModel.sendResize(cols: UInt16(newCols), rows: UInt16(newRows))
                viewModel.terminalReady()
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            Task { @MainActor [viewModel] in
                viewModel.terminalTitle = title
                viewModel.onTitleChanged?(title)
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // Not used.
        }

        func scrolled(source: TerminalView, position: Double) {
            // Not used.
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let str = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
            }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            // Not used.
        }
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

If the build fails due to SwiftTerm API mismatches, check the SwiftTerm version's actual API for macOS by looking at the SwiftTerm source or running:

```bash
find ~/Library/Developer/Xcode/DerivedData -name "TerminalView.swift" -path "*SwiftTerm*" | head -3
```

Adjust method signatures (e.g., `send(source:data:)` vs `send(data:)`) to match.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayMac/Views/TerminalContainerView.swift
git commit -m "feat(mac): add TerminalContainerView wrapping SwiftTerm NSView"
```

---

### Task 1.14: Wire up MainWindow with basic auth and single session

**Files:**
- Modify: `ClaudeRelayMac/Views/MainWindow.swift`
- Create: `ClaudeRelayMac/ViewModels/SessionCoordinator.swift` (minimal Phase 1 version)

**Context:** This is the first end-to-end integration. The MainWindow loads the last-used server, authenticates, creates a session, and wires the terminal view. Phase 2 will expand `SessionCoordinator` with multi-session sidebar, etc. For Phase 1 we just prove the pipe works.

- [ ] **Step 1: Create minimal SessionCoordinator**

Create `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`:

```swift
import Foundation
import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

/// Minimal Phase 1 coordinator: connect, auth, one session.
/// Phase 2 expands this with full session lifecycle, sidebar, observers.
@MainActor
final class SessionCoordinator: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isConnected = false
    @Published private(set) var isAuthenticated = false
    @Published private(set) var activeSessionId: UUID?
    @Published private(set) var errorMessage: String?

    // MARK: - Dependencies

    let connection: RelayConnection
    private var sessionController: SessionController?
    private(set) var terminalViewModel: TerminalViewModel?

    private let config: ConnectionConfig
    private let token: String

    init(config: ConnectionConfig, token: String) {
        self.config = config
        self.token = token
        self.connection = RelayConnection()
    }

    // MARK: - Lifecycle

    func start() async {
        do {
            try await connection.connect(config: config, token: token)
            isConnected = true
            let controller = SessionController(connection: connection)
            try await controller.authenticate(token: token)
            sessionController = controller
            isAuthenticated = true

            let sessionId = try await controller.createSession(name: nil)
            let vm = TerminalViewModel(sessionId: sessionId, connection: connection)
            terminalViewModel = vm
            activeSessionId = sessionId
            wireOutput(to: sessionId, vm: vm)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func tearDown() {
        Task { try? await sessionController?.detach() }
        connection.disconnect()
    }

    // MARK: - Private

    private func wireOutput(to sessionId: UUID, vm: TerminalViewModel) {
        connection.onTerminalOutput = { [weak vm] data in
            vm?.receiveOutput(data)
        }
    }
}
```

- [ ] **Step 2: Update MainWindow to wire everything together**

Replace the contents of `ClaudeRelayMac/Views/MainWindow.swift`:

```swift
import SwiftUI
import ClaudeRelayClient

struct MainWindow: View {
    @StateObject private var serverList = ServerListViewModel()
    @State private var coordinator: SessionCoordinator?
    @State private var showServerList = false
    @State private var loadFailure: String?

    var body: some View {
        Group {
            if let coordinator, let vm = coordinator.terminalViewModel {
                TerminalContainerView(viewModel: vm)
            } else if let failure = loadFailure {
                VStack(spacing: 12) {
                    Text("Cannot connect")
                        .font(.title2)
                    Text(failure)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Choose Server") { showServerList = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Connecting...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showServerList = true
                } label: {
                    Label("Servers", systemImage: "server.rack")
                }
            }
        }
        .task {
            await attemptAutoConnect()
        }
        .sheet(isPresented: $showServerList) {
            NavigationStack {
                ServerListWindow { config in
                    Task { await connect(to: config) }
                    showServerList = false
                }
            }
        }
        .onDisappear {
            coordinator?.tearDown()
        }
    }

    private func attemptAutoConnect() async {
        guard let last = serverList.selectedConnection() else {
            showServerList = true
            return
        }
        await connect(to: last)
    }

    private func connect(to config: ConnectionConfig) async {
        loadFailure = nil
        do {
            guard let token = try AuthManager.shared.loadToken(for: config.id) else {
                loadFailure = "No token stored for this server. Open Servers to re-enter."
                return
            }
            let c = SessionCoordinator(config: config, token: token)
            coordinator = c
            await c.start()
            if let err = c.errorMessage {
                loadFailure = err
                coordinator = nil
            }
        } catch {
            loadFailure = error.localizedDescription
        }
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual test — Phase 1 exit criteria**

1. Start the ClaudeRelay server: `brew services start clauderelay` (or `swift run claude-relay-server` in another terminal)
2. Create a token if needed: `claude-relay token create --label mac-test`. Copy the token.
3. Launch the Mac app (from Xcode or `.app` bundle).
4. On first launch: server list sheet appears. Add a server (name: "Local", host: "127.0.0.1", port: 9200, TLS off). Paste the token. Save.
5. Select the server and click Connect.
6. A terminal appears. Type commands (e.g. `ls`, `echo hello`). Verify output displays correctly.
7. Close the window. Verify the menu bar icon is still present and the app is still running.
8. Click the Dock icon — verify the window reopens with the terminal still attached.
9. Quit via `Cmd+Q`.

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayMac/Views/MainWindow.swift ClaudeRelayMac/ViewModels/SessionCoordinator.swift
git commit -m "feat(mac): wire up MainWindow with connect + auth + single session"
```

**Phase 1 exit criteria met:** App launches, connects, creates session, terminal works, menu bar icon present.

---

## Phase 2 — Session Management

**Goal**: Multi-session sidebar, full lifecycle, cross-device attach, Claude activity indicators, session rename.

---

### Task 2.1: Expand SessionCoordinator with full state

**Files:**
- Modify: `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`

**Context:** Expand from the Phase 1 minimal coordinator to the full design: session list, terminal ViewModel cache, owned/claude session sets, observer wiring for activity/steal/rename broadcasts. This mirrors iOS `SessionCoordinator` (ClaudeRelayApp/ViewModels/SessionCoordinator.swift) but adapted for Mac — no `UIDevice.identifierForVendor`, use `Host.current().name` or a Mac-generated UUID for device-local ownership.

- [ ] **Step 1: Replace the minimal coordinator with the full version**

Replace contents of `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`:

```swift
import Foundation
import SwiftUI
import IOKit
import ClaudeRelayClient
import ClaudeRelayKit

@MainActor
final class SessionCoordinator: ObservableObject {

    // MARK: - Published State

    @Published var sessions: [SessionInfo] = []
    @Published var activeSessionId: UUID?
    @Published var sessionNames: [UUID: String] = [:]
    @Published var terminalTitles: [UUID: String] = [:]
    @Published var claudeSessions: Set<UUID> = []
    @Published var sessionsAwaitingInput: Set<UUID> = []
    @Published var isLoading = false
    @Published private(set) var isRecovering = false
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var connectionTimedOut = false
    @Published var stolenSessionName: String?
    @Published var stolenSessionShortId: String?
    @Published var showSessionStolen = false
    @Published private(set) var isConnected = false
    @Published private(set) var isAuthenticated = false

    /// Sessions owned by this device (non-terminal, claimed via create or attach).
    private(set) var ownedSessionIds: Set<UUID> = []

    var activeSessions: [SessionInfo] {
        sessions.filter { !$0.state.isTerminal && ownedSessionIds.contains($0.id) }
    }

    // MARK: - Dependencies

    let connection: RelayConnection
    private let token: String
    private let config: ConnectionConfig
    private var sessionController: SessionController?
    private var terminalViewModels: [UUID: TerminalViewModel] = [:]
    var recoveryTask: Task<Void, Never>?
    private var isTornDown = false
    private var lastFetchTime: Date = .distantPast

    // MARK: - Init

    init(config: ConnectionConfig, token: String) {
        self.config = config
        self.token = token
        self.connection = RelayConnection()

        sessionNames = Self.loadNames()
        ownedSessionIds = Self.loadOwned()
        claudeSessions = Self.loadClaudeSessions()

        connection.onReconnected = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleAutoReconnect()
            }
        }
        connection.onSessionActivity = { [weak self] sessionId, activity in
            Task { @MainActor [weak self] in
                self?.handleActivityUpdate(sessionId: sessionId, activity: activity)
            }
        }
        connection.onSessionStolen = { [weak self] sessionId in
            Task { @MainActor [weak self] in
                self?.handleSessionStolen(sessionId: sessionId)
            }
        }
        connection.onSessionRenamed = { [weak self] sessionId, name in
            Task { @MainActor [weak self] in
                self?.handleSessionRenamed(sessionId: sessionId, name: name)
            }
        }
    }

    // MARK: - Start

    func start() async {
        do {
            try await connection.connect(config: config, token: token)
            isConnected = true
            _ = try await ensureAuthenticated()
            await fetchSessions()
            // If we have no owned sessions yet, create one.
            if activeSessions.isEmpty {
                await createNewSession()
            } else if activeSessionId == nil, let first = activeSessions.first {
                await switchToSession(id: first.id)
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func tearDown() {
        isTornDown = true
        recoveryTask?.cancel()
        recoveryTask = nil
        if activeSessionId != nil {
            Task { try? await sessionController?.detach() }
        }
        connection.disconnect()
    }

    // MARK: - Names

    func name(for id: UUID) -> String {
        sessionNames[id] ?? id.uuidString.prefix(8).description
    }

    func setName(_ name: String, for id: UUID) {
        sessionNames[id] = name
        Self.saveNames(sessionNames)
        Task {
            try? await sessionController?.renameSession(id: id, name: name)
        }
    }

    private func pickDefaultName() -> String {
        // Default name pool — replaced by naming-theme picker in Phase 3.
        let usedNames = Set(sessionNames.values)
        let pool = ["alpha", "beta", "gamma", "delta", "epsilon",
                    "zeta", "eta", "theta", "iota", "kappa"]
        return pool.first { !usedNames.contains($0) } ?? "Session \(sessionNames.count + 1)"
    }

    // MARK: - Persistence

    private static let namesKey = "com.clauderelay.mac.sessionNames"
    private static func loadNames() -> [UUID: String] {
        guard let data = UserDefaults.standard.data(forKey: namesKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict.reduce(into: [:]) { result, pair in
            if let uuid = UUID(uuidString: pair.key) {
                result[uuid] = pair.value
            }
        }
    }

    private static func saveNames(_ names: [UUID: String]) {
        let dict = names.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: namesKey)
        }
    }

    private static let claudeSessionsKey = "com.clauderelay.mac.claudeSessions"
    private static func loadClaudeSessions() -> Set<UUID> {
        guard let arr = UserDefaults.standard.stringArray(forKey: claudeSessionsKey) else { return [] }
        return Set(arr.compactMap { UUID(uuidString: $0) })
    }
    private func saveClaudeSessions() {
        let arr = claudeSessions.map { $0.uuidString }
        UserDefaults.standard.set(arr, forKey: Self.claudeSessionsKey)
    }

    /// Device-local ownership key. Uses the Mac's hardware UUID so ownership
    /// doesn't leak between machines if UserDefaults ever sync.
    private static var ownedKey: String {
        let deviceId = macDeviceID()
        return "com.clauderelay.mac.ownedSessions.\(deviceId)"
    }

    private static func macDeviceID() -> String {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }
        if platformExpert != 0,
           let serial = IORegistryEntryCreateCFProperty(
               platformExpert,
               kIOPlatformUUIDKey as CFString,
               kCFAllocatorDefault, 0
           )?.takeUnretainedValue() as? String {
            return serial
        }
        return "unknown"
    }

    private static func loadOwned() -> Set<UUID> {
        guard let arr = UserDefaults.standard.stringArray(forKey: ownedKey) else { return [] }
        return Set(arr.compactMap { UUID(uuidString: $0) })
    }

    private func saveOwned() {
        let arr = ownedSessionIds.map { $0.uuidString }
        UserDefaults.standard.set(arr, forKey: Self.ownedKey)
    }

    private func claimSession(_ id: UUID) {
        guard !ownedSessionIds.contains(id) else { return }
        ownedSessionIds.insert(id)
        saveOwned()
    }

    private func unclaimSession(_ id: UUID) {
        ownedSessionIds.remove(id)
        saveOwned()
    }

    // MARK: - Auth

    private func ensureAuthenticated() async throws -> SessionController {
        if let controller = sessionController, controller.isAuthenticated {
            return controller
        }
        let controller = sessionController ?? SessionController(connection: connection)
        try await controller.authenticate(token: token)
        sessionController = controller
        isAuthenticated = true
        return controller
    }

    // MARK: - List

    func fetchSessions() async {
        let now = Date()
        guard now.timeIntervalSince(lastFetchTime) >= 0.5 else { return }
        lastFetchTime = now

        isLoading = true
        defer { isLoading = false }

        do {
            let controller = try await ensureAuthenticated()
            sessions = try await controller.listSessions()

            for session in sessions {
                if let serverName = session.name {
                    sessionNames[session.id] = serverName
                }
            }
            Self.saveNames(sessionNames)

            for session in sessions {
                let activity = session.activity ?? .idle
                handleActivityUpdate(sessionId: session.id, activity: activity)
            }

            // Prune stale state for sessions no longer on the server.
            let serverIds = Set(sessions.map { $0.id })
            let staleActivity = claudeSessions.subtracting(serverIds)
            if !staleActivity.isEmpty {
                claudeSessions.subtract(staleActivity)
                sessionsAwaitingInput.subtract(staleActivity)
                saveClaudeSessions()
            }
            let staleOwned = ownedSessionIds.subtracting(serverIds)
            if !staleOwned.isEmpty {
                ownedSessionIds.subtract(staleOwned)
                saveOwned()
            }
            let staleNames = Set(sessionNames.keys).subtracting(serverIds)
            if !staleNames.isEmpty {
                for id in staleNames { sessionNames.removeValue(forKey: id) }
                Self.saveNames(sessionNames)
            }
        } catch {
            // Non-critical refresh.
        }
    }

    // MARK: - Access

    func viewModel(for sessionId: UUID) -> TerminalViewModel? {
        terminalViewModels[sessionId]
    }

    func createdAt(for sessionId: UUID) -> Date? {
        sessions.first { $0.id == sessionId }?.createdAt
    }

    func isRunningClaude(sessionId: UUID) -> Bool {
        claudeSessions.contains(sessionId)
    }

    // MARK: - Activity / Steal / Rename handlers

    private func handleActivityUpdate(sessionId: UUID, activity: ActivityState) {
        var claudeChanged = false
        if activity.isClaudeRunning {
            if !claudeSessions.contains(sessionId) {
                claudeSessions.insert(sessionId)
                terminalViewModels[sessionId]?.isClaudeActive = true
                claudeChanged = true
            }
        } else {
            if claudeSessions.contains(sessionId) {
                claudeSessions.remove(sessionId)
                terminalViewModels[sessionId]?.isClaudeActive = false
                claudeChanged = true
            }
        }
        if claudeChanged { saveClaudeSessions() }

        if activity == .claudeIdle {
            sessionsAwaitingInput.insert(sessionId)
        } else {
            sessionsAwaitingInput.remove(sessionId)
        }
    }

    private func handleSessionStolen(sessionId: UUID) {
        let sessionName = name(for: sessionId)
        let shortId = String(sessionId.uuidString.prefix(8))

        if activeSessionId == sessionId {
            terminalViewModels[sessionId] = nil
            activeSessionId = nil
        }
        claudeSessions.remove(sessionId)
        sessionsAwaitingInput.remove(sessionId)

        stolenSessionName = sessionName
        stolenSessionShortId = shortId
        showSessionStolen = true

        Task { await fetchSessions() }
    }

    private func handleSessionRenamed(sessionId: UUID, name: String) {
        sessionNames[sessionId] = name
        Self.saveNames(sessionNames)
    }

    // MARK: - Wire output

    func wireTerminalOutput(to sessionId: UUID) {
        if claudeSessions.contains(sessionId) {
            terminalViewModels[sessionId]?.isClaudeActive = true
        }
        connection.onTerminalOutput = { [weak self] data in
            self?.terminalViewModels[sessionId]?.receiveOutput(data)
        }
        terminalViewModels[sessionId]?.onTitleChanged = { [weak self] title in
            self?.terminalTitles[sessionId] = title
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }

    // Tasks 2.4–2.9 implement: createNewSession, switchToSession, detachSession,
    // terminateSession, fetchAttachableSessions, attachRemoteSession, renameSession.
    // Stubs added here to satisfy references in MainWindow.

    func createNewSession() async {
        // Implemented in Task 2.4.
    }

    func switchToSession(id: UUID) async {
        // Implemented in Task 2.5/2.6.
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/ViewModels/SessionCoordinator.swift
git commit -m "feat(mac): expand SessionCoordinator with full state and observers"
```

---

### Task 2.2: Create SessionSidebarView

**Files:**
- Create: `ClaudeRelayMac/Views/SessionSidebarView.swift`

**Context:** Displays the list of sessions with activity icons and uptime. Selection binds to `SessionCoordinator.activeSessionId`. Right-click context menu for Rename/Detach/Terminate. "+ New Session" button at bottom.

- [ ] **Step 1: Write the sidebar**

Create `ClaudeRelayMac/Views/SessionSidebarView.swift`:

```swift
import SwiftUI
import ClaudeRelayKit

struct SessionSidebarView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var renameTarget: UUID?
    @State private var renameText: String = ""
    @State private var terminateTarget: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { coordinator.activeSessionId },
                set: { newId in
                    if let id = newId {
                        Task { await coordinator.switchToSession(id: id) }
                    }
                }
            )) {
                ForEach(coordinator.activeSessions, id: \.id) { session in
                    SessionRow(
                        name: coordinator.name(for: session.id),
                        shortId: String(session.id.uuidString.prefix(8)),
                        activity: activityFor(session.id),
                        createdAt: session.createdAt
                    )
                    .contextMenu {
                        Button("Rename") {
                            renameText = coordinator.name(for: session.id)
                            renameTarget = session.id
                        }
                        Divider()
                        Button("Terminate", role: .destructive) {
                            terminateTarget = session.id
                        }
                    }
                    .tag(session.id)
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button {
                Task { await coordinator.createNewSession() }
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .alert("Rename Session", isPresented: .init(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renameTarget {
                    coordinator.setName(renameText, for: id)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Terminate Session?",
               isPresented: .init(
                get: { terminateTarget != nil },
                set: { if !$0 { terminateTarget = nil } }
               )) {
            Button("Terminate", role: .destructive) {
                if let id = terminateTarget {
                    Task { await coordinator.terminateSession(id: id) }
                }
                terminateTarget = nil
            }
            Button("Cancel", role: .cancel) { terminateTarget = nil }
        }
    }

    private func activityFor(_ id: UUID) -> ActivityState {
        if coordinator.isRunningClaude(sessionId: id) {
            return coordinator.sessionsAwaitingInput.contains(id) ? .claudeIdle : .claudeActive
        }
        return coordinator.sessionsAwaitingInput.contains(id) ? .idle : .active
    }
}

private struct SessionRow: View {
    let name: String
    let shortId: String
    let activity: ActivityState
    let createdAt: Date

    private var icon: String {
        switch activity {
        case .claudeActive: return "circle.fill"
        case .claudeIdle:   return "circle.lefthalf.filled"
        case .idle:         return "circle"
        case .active:       return "circle"
        }
    }
    private var iconColor: Color {
        switch activity {
        case .claudeActive: return .green
        case .claudeIdle:   return .orange
        case .idle, .active: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.system(size: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                Text(shortId)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 2: Build — will fail on `coordinator.terminateSession` (implemented in Task 2.8)**

That's expected. We'll fix after 2.8.

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

Continue to Task 2.3, then 2.4–2.9 complete the wiring.

- [ ] **Step 3: Commit (file alone, build wired up after 2.8)**

```bash
git add ClaudeRelayMac/Views/SessionSidebarView.swift
git commit -m "feat(mac): add SessionSidebarView with activity icons"
```

---

### Task 2.3: Update MainWindow to NavigationSplitView

**Files:**
- Modify: `ClaudeRelayMac/Views/MainWindow.swift`

**Context:** Replace the single-terminal MainWindow with a `NavigationSplitView` holding sidebar + terminal detail. Also move the `SessionCoordinator` into `@StateObject` at window level so all views can observe.

- [ ] **Step 1: Rewrite MainWindow**

Replace contents of `ClaudeRelayMac/Views/MainWindow.swift`:

```swift
import SwiftUI
import ClaudeRelayClient

struct MainWindow: View {
    @StateObject private var serverList = ServerListViewModel()
    @State private var coordinator: SessionCoordinator?
    @State private var showServerList = false
    @State private var loadFailure: String?

    var body: some View {
        Group {
            if let coordinator {
                WorkspaceView(coordinator: coordinator)
            } else if let failure = loadFailure {
                FailureView(message: failure) { showServerList = true }
            } else {
                ProgressView("Connecting...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showServerList = true
                } label: {
                    Label("Servers", systemImage: "server.rack")
                }
            }
        }
        .task { await attemptAutoConnect() }
        .sheet(isPresented: $showServerList) {
            NavigationStack {
                ServerListWindow { config in
                    Task { await connect(to: config) }
                    showServerList = false
                }
            }
        }
        .onDisappear { coordinator?.tearDown() }
    }

    private func attemptAutoConnect() async {
        guard let last = serverList.selectedConnection() else {
            showServerList = true
            return
        }
        await connect(to: last)
    }

    private func connect(to config: ConnectionConfig) async {
        loadFailure = nil
        do {
            guard let token = try AuthManager.shared.loadToken(for: config.id) else {
                loadFailure = "No token stored for this server."
                return
            }
            let c = SessionCoordinator(config: config, token: token)
            coordinator = c
            await c.start()
            if let err = c.errorMessage {
                loadFailure = err
                coordinator = nil
            }
        } catch {
            loadFailure = error.localizedDescription
        }
    }
}

private struct WorkspaceView: View {
    @ObservedObject var coordinator: SessionCoordinator

    var body: some View {
        NavigationSplitView {
            SessionSidebarView(coordinator: coordinator)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            if let activeId = coordinator.activeSessionId,
               let vm = coordinator.viewModel(for: activeId) {
                TerminalContainerView(viewModel: vm)
                    .id(activeId)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No session selected")
                        .foregroundStyle(.secondary)
                    Button("New Session") {
                        Task { await coordinator.createNewSession() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct FailureView: View {
    let message: String
    let onChooseServer: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Cannot connect")
                .font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Choose Server") { onChooseServer() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Build**

May fail on missing implementations — continue to 2.4.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/Views/MainWindow.swift
git commit -m "feat(mac): replace single-terminal MainWindow with NavigationSplitView"
```

---

### Task 2.4: Implement session create in SessionCoordinator

**Files:**
- Modify: `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`

**Context:** Port iOS `createNewSession()` logic. Detach current session first, create via server, claim the session, create a new `TerminalViewModel`, wire it, set as active, refresh list.

- [ ] **Step 1: Replace the `createNewSession()` stub**

In `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`, find the stub:

```swift
    func createNewSession() async {
        // Implemented in Task 2.4.
    }
```

Replace with:

```swift
    func createNewSession() async {
        guard !isRecovering else { return }
        do {
            let controller = try await ensureAuthenticated()

            if let currentId = activeSessionId {
                try? await controller.detach()
                terminalViewModels[currentId]?.prepareForSwitch()
                terminalViewModels[currentId] = nil
            }

            let name = pickDefaultName()
            let sessionId = try await controller.createSession(name: name)
            claimSession(sessionId)
            sessionNames[sessionId] = name
            Self.saveNames(sessionNames)

            let vm = TerminalViewModel(sessionId: sessionId, connection: connection)
            terminalViewModels[sessionId] = vm
            wireTerminalOutput(to: sessionId)
            activeSessionId = sessionId

            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

Still may fail on `switchToSession` / `terminateSession` — continue.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/ViewModels/SessionCoordinator.swift
git commit -m "feat(mac): implement session create in SessionCoordinator"
```

---

### Task 2.5: Implement session switch (via resume)

**Files:**
- Modify: `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`

**Context:** Switching to a different session detaches the current one (server-side) and resumes the target. Terminal scrollback is replayed. Port from iOS `switchToSession`.

- [ ] **Step 1: Replace the `switchToSession` stub**

In `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`, find:

```swift
    func switchToSession(id: UUID) async {
        // Implemented in Task 2.5/2.6.
    }
```

Replace with:

```swift
    func switchToSession(id: UUID) async {
        guard !isRecovering, id != activeSessionId else { return }
        do {
            let controller = try await ensureAuthenticated()

            if let currentId = activeSessionId {
                try? await controller.detach()
                terminalViewModels[currentId]?.prepareForSwitch()
                terminalViewModels[currentId] = nil
            }

            try await controller.resumeSession(id: id)

            if terminalViewModels[id] == nil {
                terminalViewModels[id] = TerminalViewModel(sessionId: id, connection: connection)
            } else {
                terminalViewModels[id]?.prepareForSwitch()
            }

            wireTerminalOutput(to: id)
            activeSessionId = id

            await fetchSessions()
        } catch {
            presentError(error.localizedDescription)
        }
    }
```

- [ ] **Step 2: Build & commit**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
git add ClaudeRelayMac/ViewModels/SessionCoordinator.swift
git commit -m "feat(mac): implement session switch via resume"
```

---

### Task 2.6: Implement session resume (explicit, standalone)

**Files:**
- Modify: `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`

**Context:** The `switchToSession` above already calls `resumeSession` on the controller. This task adds an explicit public `resumeSession(id:)` method for foreground recovery paths (used by Phase 3 sleep/wake handler). It's a thin wrapper that calls `switchToSession` with reset-for-replay first.

- [ ] **Step 1: Add resumeSession public method**

Append to the `SessionCoordinator` class (before `createNewSession` stub or wherever natural):

```swift
    /// Explicit resume — used by foreground recovery to replay scrollback after
    /// a dead connection is restored. Calls resetForReplay on the VM before
    /// triggering the resume flow.
    func resumeActiveSession() async {
        guard let activeId = activeSessionId else { return }
        terminalViewModels[activeId]?.resetForReplay()
        do {
            let controller = try await ensureAuthenticated()
            try await controller.resumeSession(id: activeId)
            wireTerminalOutput(to: activeId)
        } catch {
            presentError(error.localizedDescription)
        }
    }
```

- [ ] **Step 2: Build & commit**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
git add ClaudeRelayMac/ViewModels/SessionCoordinator.swift
git commit -m "feat(mac): add explicit resumeActiveSession for recovery path"
```

---

### Task 2.7: Implement session detach

**Files:**
- Modify: `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`

**Context:** Detach — keep PTY alive on server, stop receiving output on this client. Used when the user closes a tab or terminates without killing.

- [ ] **Step 1: Add detach method**

Append to the `SessionCoordinator`:

```swift
    func detachSession(id: UUID) async {
        do {
            let controller = try await ensureAuthenticated()
            if activeSessionId == id {
                try await controller.detach()
                terminalViewModels[id]?.prepareForSwitch()
                terminalViewModels[id] = nil
                activeSessionId = nil
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }
```

- [ ] **Step 2: Build & commit**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
git add ClaudeRelayMac/ViewModels/SessionCoordinator.swift
git commit -m "feat(mac): implement session detach"
```

---

### Task 2.8: Implement session terminate

**Files:**
- Modify: `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`

**Context:** Terminate — kill the PTY on the server. Remove from all local state, switch to another session if this was active.

- [ ] **Step 1: Add terminate method**

Append to the `SessionCoordinator`:

```swift
    func terminateSession(id: UUID) async {
        guard !isRecovering else { return }
        do {
            try await connection.send(.sessionTerminate(sessionId: id))
            if activeSessionId == id {
                activeSessionId = nil
                terminalViewModels[id] = nil
            }
            claudeSessions.remove(id)
            unclaimSession(id)
            sessionNames.removeValue(forKey: id)
            terminalTitles.removeValue(forKey: id)
            sessionsAwaitingInput.remove(id)
            Self.saveNames(sessionNames)
            await fetchSessions()

            // Switch to another active session if available.
            if activeSessionId == nil, let next = activeSessions.first {
                await switchToSession(id: next.id)
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }
```

- [ ] **Step 2: Build — now all sidebar wiring compiles**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/ViewModels/SessionCoordinator.swift
git commit -m "feat(mac): implement session terminate with automatic switch-to-next"
```

---

### Task 2.9: Implement cross-device attach

**Files:**
- Modify: `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`
- Create: `ClaudeRelayMac/Views/AttachRemoteSessionSheet.swift`

**Context:** Lists sessions running on the server that THIS device has not claimed. Selecting one triggers cross-device attach, which takes over the session from whatever device had it. The other device receives `sessionStolen`.

- [ ] **Step 1: Add attach methods to SessionCoordinator**

Append to `SessionCoordinator`:

```swift
    func fetchAttachableSessions() async -> [SessionInfo] {
        do {
            let controller = try await ensureAuthenticated()
            let all = try await controller.listAllSessions()
            return all.filter { session in
                !session.state.isTerminal && !ownedSessionIds.contains(session.id)
            }
        } catch {
            return []
        }
    }

    func attachRemoteSession(id: UUID, serverName: String? = nil) async {
        guard !isRecovering else { return }
        let previousId = activeSessionId
        do {
            let controller = try await ensureAuthenticated()

            if previousId != nil {
                try? await controller.detach()
            }

            try await controller.attachSession(id: id)

            if let currentId = previousId, currentId != id {
                terminalViewModels[currentId]?.prepareForSwitch()
                terminalViewModels[currentId] = nil
            }

            claimSession(id)
            let vm = TerminalViewModel(sessionId: id, connection: connection)
            terminalViewModels[id] = vm
            wireTerminalOutput(to: id)
            activeSessionId = id

            if let serverName {
                sessionNames[id] = serverName
                Self.saveNames(sessionNames)
            } else if sessionNames[id] == nil {
                let name = pickDefaultName()
                sessionNames[id] = name
                Self.saveNames(sessionNames)
                try? await controller.renameSession(id: id, name: name)
            }

            await fetchSessions()
        } catch {
            if let previousId {
                try? await sessionController?.resumeSession(id: previousId)
                wireTerminalOutput(to: previousId)
            }
            presentError(error.localizedDescription)
        }
    }
```

- [ ] **Step 2: Create the AttachRemoteSessionSheet view**

Create `ClaudeRelayMac/Views/AttachRemoteSessionSheet.swift`:

```swift
import SwiftUI
import ClaudeRelayKit

struct AttachRemoteSessionSheet: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [SessionInfo] = []
    @State private var isLoading = true
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Looking for sessions...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No remote sessions available")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(sessions, id: \.id) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name ?? String(session.id.uuidString.prefix(8)))
                                .font(.headline)
                            Text("State: \(session.state.rawValue) · Created \(session.createdAt.formatted(.dateTime))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(session.id)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Attach") {
                    guard let id = selection else { return }
                    let serverName = sessions.first { $0.id == id }?.name
                    Task {
                        await coordinator.attachRemoteSession(id: id, serverName: serverName)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(12)
        }
        .frame(width: 480, height: 400)
        .task {
            sessions = await coordinator.fetchAttachableSessions()
            isLoading = false
        }
    }
}
```

- [ ] **Step 3: Add a button in the sidebar to open the sheet**

Modify `ClaudeRelayMac/Views/SessionSidebarView.swift`. In the `VStack(spacing: 0)` before the `Divider() / Button "New Session"`, add state:

At the top of the struct:

```swift
    @State private var showAttachSheet = false
```

Update the bottom button area to:

```swift
            Divider()
            HStack {
                Button {
                    Task { await coordinator.createNewSession() }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    showAttachSheet = true
                } label: {
                    Label("Attach", systemImage: "rectangle.connected.to.line.below")
                }
                .buttonStyle(.plain)
            }
            .padding(12)
```

And add the sheet modifier to the outermost `VStack`:

```swift
        .sheet(isPresented: $showAttachSheet) {
            AttachRemoteSessionSheet(coordinator: coordinator)
        }
```

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayMac/ViewModels/SessionCoordinator.swift \
        ClaudeRelayMac/Views/AttachRemoteSessionSheet.swift \
        ClaudeRelayMac/Views/SessionSidebarView.swift
git commit -m "feat(mac): cross-device attach with remote session picker sheet"
```

---

### Task 2.10: Wire session rename

**Files:**
- Modify: `ClaudeRelayMac/Views/SessionSidebarView.swift` (already wired in Task 2.2)
- No new code needed — verify end-to-end works.

**Context:** The sidebar already has a Rename context menu action that calls `coordinator.setName(_:for:)`. That calls `sessionController.renameSession` which broadcasts to all clients. Verify the flow.

- [ ] **Step 1: Manual test**

Run the app, right-click a session in the sidebar, pick Rename, enter a new name, save. Verify:
- The sidebar row updates immediately
- If you have the iOS app connected to the same server, its session list shows the new name within a second (the server broadcasts `sessionRenamed`)

- [ ] **Step 2: No commit — test only**

---

### Task 2.11: Activity state display in sidebar (verify end-to-end)

**Files:**
- No new code — verify the activity icons update.

**Context:** `SessionSidebarView.SessionRow` already computes `activityFor(_:)` from `coordinator.claudeSessions` and `coordinator.sessionsAwaitingInput`. Those are updated by `handleActivityUpdate` from server pushes.

- [ ] **Step 1: Manual test**

1. Connect to the server with the Mac app.
2. Create a session.
3. In the terminal, run `claude` (or any Claude Code command). Wait for it to launch.
4. Verify the sidebar icon changes to green filled circle (`● claude active`).
5. Wait for Claude to stop producing output (at the prompt).
6. Verify the icon changes to orange half-filled (`◐ claude idle`).
7. Exit Claude. Verify icon returns to gray open circle.

- [ ] **Step 2: No commit — test only**

---

### Task 2.12: Create StatusBarView

**Files:**
- Create: `ClaudeRelayMac/Views/StatusBarView.swift`
- Modify: `ClaudeRelayMac/Views/MainWindow.swift` (add status bar at bottom)

**Context:** Bottom bar showing connection state and Claude activity for the focused session. Visible at all times in the main window.

- [ ] **Step 1: Write the StatusBar**

Create `ClaudeRelayMac/Views/StatusBarView.swift`:

```swift
import SwiftUI
import ClaudeRelayClient

struct StatusBarView: View {
    @ObservedObject var coordinator: SessionCoordinator

    var body: some View {
        HStack(spacing: 16) {
            // Connection state
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
                Text(connectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Activity for active session
            if let id = coordinator.activeSessionId {
                HStack(spacing: 6) {
                    Image(systemName: activityIcon(id))
                        .foregroundStyle(activityColor(id))
                        .font(.caption)
                    Text(activityLabel(id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
    }

    private var connectionColor: Color {
        if coordinator.isRecovering { return .orange }
        return coordinator.isConnected ? .green : .red
    }
    private var connectionLabel: String {
        if coordinator.isRecovering { return "Reconnecting..." }
        return coordinator.isConnected ? "Connected" : "Disconnected"
    }
    private func activityIcon(_ id: UUID) -> String {
        if coordinator.isRunningClaude(sessionId: id) {
            return coordinator.sessionsAwaitingInput.contains(id) ?
                "circle.lefthalf.filled" : "circle.fill"
        }
        return "circle"
    }
    private func activityColor(_ id: UUID) -> Color {
        if coordinator.isRunningClaude(sessionId: id) {
            return coordinator.sessionsAwaitingInput.contains(id) ? .orange : .green
        }
        return .secondary
    }
    private func activityLabel(_ id: UUID) -> String {
        if coordinator.isRunningClaude(sessionId: id) {
            return coordinator.sessionsAwaitingInput.contains(id) ?
                "Claude (idle)" : "Claude (active)"
        }
        return coordinator.sessionsAwaitingInput.contains(id) ? "Idle" : "Active"
    }
}
```

- [ ] **Step 2: Add StatusBar to the MainWindow detail area**

In `ClaudeRelayMac/Views/MainWindow.swift`, find the `WorkspaceView` struct's `NavigationSplitView`'s detail closure. Wrap the detail content in a `VStack`:

```swift
        } detail: {
            VStack(spacing: 0) {
                if let activeId = coordinator.activeSessionId,
                   let vm = coordinator.viewModel(for: activeId) {
                    TerminalContainerView(viewModel: vm)
                        .id(activeId)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No session selected")
                            .foregroundStyle(.secondary)
                        Button("New Session") {
                            Task { await coordinator.createNewSession() }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                StatusBarView(coordinator: coordinator)
            }
        }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual test — Phase 2 exit criteria**

1. Launch the app, connect.
2. Create multiple sessions via `+ New`.
3. Verify sidebar shows all sessions with activity icons.
4. Switch between sessions — terminal content changes, scrollback appears correctly.
5. Right-click → Rename works.
6. Right-click → Terminate works.
7. Click `Attach` with sessions running on another device, pick one, attach — takes over from the other device.
8. Status bar shows connection state and activity correctly.

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayMac/Views/StatusBarView.swift ClaudeRelayMac/Views/MainWindow.swift
git commit -m "feat(mac): add StatusBarView showing connection and activity state"
```

**Phase 2 exit criteria met:** Multi-session sidebar, full lifecycle, cross-device attach, activity indicators, rename.

---

## Phase 3 — Mac-Native Polish

**Goal**: Menu bar integration, keyboard shortcuts, preferences, network/sleep recovery, naming themes, launch-at-login.

---

### Task 3.1: Add app menu bar commands

**Files:**
- Modify: `ClaudeRelayMac/ClaudeRelayMacApp.swift`
- Create: `ClaudeRelayMac/Helpers/AppCommands.swift`

**Context:** SwiftUI's `.commands` modifier lets us replace default menu items and add new ones. We need the coordinator to route menu actions — use a `@FocusedObject` or `@FocusedValue` to give commands access to the main window's coordinator.

- [ ] **Step 1: Create a focused-value key for the coordinator**

Create `ClaudeRelayMac/Helpers/AppCommands.swift`:

```swift
import SwiftUI

/// FocusedValue key so menu bar commands can access the active SessionCoordinator.
struct SessionCoordinatorKey: FocusedValueKey {
    typealias Value = SessionCoordinator
}

extension FocusedValues {
    var sessionCoordinator: SessionCoordinator? {
        get { self[SessionCoordinatorKey.self] }
        set { self[SessionCoordinatorKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.sessionCoordinator) var coordinator: SessionCoordinator?

    var body: some Commands {
        // Replace the default New item in the File menu.
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                guard let coordinator else { return }
                Task { await coordinator.createNewSession() }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(coordinator == nil)
        }

        // Add a Session menu between View and Window.
        CommandMenu("Session") {
            Button("Detach Current") {
                guard let coordinator, let id = coordinator.activeSessionId else { return }
                Task { await coordinator.detachSession(id: id) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(coordinator?.activeSessionId == nil)

            Button("Terminate Current") {
                guard let coordinator, let id = coordinator.activeSessionId else { return }
                Task { await coordinator.terminateSession(id: id) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(coordinator?.activeSessionId == nil)

            Divider()

            Button("Next Session") {
                coordinator?.switchToNextSession()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Previous Session") {
                coordinator?.switchToPreviousSession()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }
}
```

- [ ] **Step 2: Add switchToNext/Previous methods to SessionCoordinator**

Append to `SessionCoordinator`:

```swift
    // MARK: - Next/Previous

    func switchToNextSession() {
        guard let current = activeSessionId,
              let idx = activeSessions.firstIndex(where: { $0.id == current }) else { return }
        let next = (idx + 1) % activeSessions.count
        let target = activeSessions[next].id
        guard target != current else { return }
        Task { await switchToSession(id: target) }
    }

    func switchToPreviousSession() {
        guard let current = activeSessionId,
              let idx = activeSessions.firstIndex(where: { $0.id == current }) else { return }
        let previous = (idx - 1 + activeSessions.count) % activeSessions.count
        let target = activeSessions[previous].id
        guard target != current else { return }
        Task { await switchToSession(id: target) }
    }
```

- [ ] **Step 3: Install AppCommands and publish the coordinator to focused values**

In `ClaudeRelayMac/ClaudeRelayMacApp.swift`, update the body:

```swift
    var body: some Scene {
        WindowGroup("Claude Relay") {
            MainWindow()
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands()
        }

        MenuBarExtra {
            MenuBarDropdown()
        } label: {
            Image(systemName: "terminal")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .frame(width: 600, height: 400)
        }
    }
```

In `ClaudeRelayMac/Views/MainWindow.swift`, publish the coordinator when it exists:

Find the `Group` in MainWindow's body and add a `.focusedValue` modifier after `.onDisappear`:

```swift
        .onDisappear { coordinator?.tearDown() }
        .focusedValue(\.sessionCoordinator, coordinator)
```

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual test**

Run the app, create multiple sessions. Test the menu:
- `Cmd+T` creates a new session
- `Cmd+W` detaches current
- `Cmd+Shift+W` terminates current
- `Cmd+Shift+]` / `[` switches between sessions

- [ ] **Step 6: Commit**

```bash
git add ClaudeRelayMac/Helpers/AppCommands.swift \
        ClaudeRelayMac/ClaudeRelayMacApp.swift \
        ClaudeRelayMac/Views/MainWindow.swift \
        ClaudeRelayMac/ViewModels/SessionCoordinator.swift
git commit -m "feat(mac): add File/Session menu commands with keyboard shortcuts"
```

---

### Task 3.2: Implement session-index shortcuts (Cmd+1..9) and sidebar toggle (Cmd+0)

**Files:**
- Modify: `ClaudeRelayMac/Helpers/AppCommands.swift`
- Modify: `ClaudeRelayMac/Views/MainWindow.swift`

**Context:** `Cmd+1..9` switches to session by index. `Cmd+0` toggles sidebar. Session-index shortcuts need the coordinator's session list; the sidebar toggle needs the split view column visibility.

- [ ] **Step 1: Add sidebar visibility state to MainWindow**

In `WorkspaceView` inside `ClaudeRelayMac/Views/MainWindow.swift`, add a `@State` for sidebar visibility. Replace `NavigationSplitView { … } detail: { … }` with:

```swift
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebarView(coordinator: coordinator)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            // ... existing detail content ...
        }
        .focusedValue(\.sidebarVisibility, $columnVisibility)
    }
```

- [ ] **Step 2: Add FocusedValue key for sidebar visibility**

Add to `ClaudeRelayMac/Helpers/AppCommands.swift`:

```swift
struct SidebarVisibilityKey: FocusedValueKey {
    typealias Value = Binding<NavigationSplitViewVisibility>
}

extension FocusedValues {
    var sidebarVisibility: Binding<NavigationSplitViewVisibility>? {
        get { self[SidebarVisibilityKey.self] }
        set { self[SidebarVisibilityKey.self] = newValue }
    }
}
```

- [ ] **Step 3: Add the View menu and session-index commands to AppCommands**

In `ClaudeRelayMac/Helpers/AppCommands.swift`, add to `AppCommands.body`:

Inject `@FocusedValue(\.sidebarVisibility) var sidebarVisibility: Binding<NavigationSplitViewVisibility>?` at the top of `AppCommands`.

Append this to `body` after the `CommandMenu("Session")`:

```swift
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                guard let binding = sidebarVisibility else { return }
                switch binding.wrappedValue {
                case .all:
                    binding.wrappedValue = .detailOnly
                default:
                    binding.wrappedValue = .all
                }
            }
            .keyboardShortcut("0", modifiers: .command)
        }
```

And inside the `CommandMenu("Session")`, append nine buttons for session index shortcuts:

```swift
            Divider()

            ForEach(1...9, id: \.self) { index in
                Button("Session \(index)") {
                    coordinator?.switchToSession(atIndex: index - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
```

- [ ] **Step 4: Add switchToSession(atIndex:) to SessionCoordinator**

Append to `SessionCoordinator`:

```swift
    func switchToSession(atIndex index: Int) {
        guard index >= 0, index < activeSessions.count else { return }
        let target = activeSessions[index].id
        guard target != activeSessionId else { return }
        Task { await switchToSession(id: target) }
    }
```

- [ ] **Step 5: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Manual test**

Create several sessions. Test:
- `Cmd+1` through `Cmd+9` switch to session by position
- `Cmd+0` toggles sidebar visibility

- [ ] **Step 7: Commit**

```bash
git add ClaudeRelayMac/Helpers/AppCommands.swift \
        ClaudeRelayMac/Views/MainWindow.swift \
        ClaudeRelayMac/ViewModels/SessionCoordinator.swift
git commit -m "feat(mac): session-index shortcuts (Cmd+1..9) and sidebar toggle (Cmd+0)"
```

---

### Task 3.3: Create MenuBarViewModel

**Files:**
- Create: `ClaudeRelayMac/ViewModels/MenuBarViewModel.swift`

**Context:** The menu bar dropdown needs state that survives across window open/close. This VM observes the active `SessionCoordinator` (if any) and publishes what the dropdown needs: server name, connection state, session list with activity states.

- [ ] **Step 1: Create a shared coordinator registry**

The menu bar lives outside any window, so we need a way to share the active coordinator. Use a simple observable singleton.

Create `ClaudeRelayMac/ViewModels/MenuBarViewModel.swift`:

```swift
import Foundation
import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

/// Singleton that the menu bar dropdown and main window both write to.
/// When the main window connects, it registers its coordinator here.
@MainActor
final class ActiveCoordinatorRegistry: ObservableObject {
    static let shared = ActiveCoordinatorRegistry()

    @Published private(set) var coordinator: SessionCoordinator?
    @Published private(set) var serverName: String?

    private init() {}

    func register(coordinator: SessionCoordinator, serverName: String) {
        self.coordinator = coordinator
        self.serverName = serverName
    }

    func clear() {
        coordinator = nil
        serverName = nil
    }
}

/// Menu bar dropdown's view model — derived from ActiveCoordinatorRegistry.
@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published private(set) var connectionLabel: String = "Not connected"
    @Published private(set) var connectionColor: Color = .secondary
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var activityStates: [UUID: ActivityState] = [:]
    @Published private(set) var activeSessionId: UUID?

    private var observationTask: Task<Void, Never>?

    init() {
        observe()
    }

    private func observe() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            let registry = ActiveCoordinatorRegistry.shared
            for await coordinator in registry.$coordinator.values {
                guard let self else { return }
                if let coordinator {
                    self.connectionLabel = registry.serverName ?? "Connected"
                    self.connectionColor = coordinator.isConnected ? .green : .orange
                    await self.follow(coordinator)
                } else {
                    self.connectionLabel = "Not connected"
                    self.connectionColor = .secondary
                    self.sessions = []
                    self.activeSessionId = nil
                }
            }
        }
    }

    private func follow(_ coordinator: SessionCoordinator) async {
        // Subscribe to the coordinator's published state.
        async let sessionsStream: () = Task { @MainActor in
            for await s in coordinator.$sessions.values {
                self.sessions = s.filter { !$0.state.isTerminal }
            }
        }.value
        async let activeStream: () = Task { @MainActor in
            for await id in coordinator.$activeSessionId.values {
                self.activeSessionId = id
            }
        }.value
        async let claudeStream: () = Task { @MainActor in
            for await claude in coordinator.$claudeSessions.values {
                var states: [UUID: ActivityState] = [:]
                for session in self.sessions {
                    let awaiting = coordinator.sessionsAwaitingInput.contains(session.id)
                    if claude.contains(session.id) {
                        states[session.id] = awaiting ? .claudeIdle : .claudeActive
                    } else {
                        states[session.id] = awaiting ? .idle : .active
                    }
                }
                self.activityStates = states
            }
        }.value
        _ = await (sessionsStream, activeStream, claudeStream)
    }

    deinit {
        observationTask?.cancel()
    }
}
```

- [ ] **Step 2: Register/unregister coordinator in MainWindow**

In `ClaudeRelayMac/Views/MainWindow.swift`'s `connect(to:)` function, after `coordinator = c` and `await c.start()`, add:

```swift
            if c.errorMessage == nil {
                ActiveCoordinatorRegistry.shared.register(coordinator: c, serverName: config.name)
            }
```

And in `onDisappear`:

```swift
        .onDisappear {
            coordinator?.tearDown()
            ActiveCoordinatorRegistry.shared.clear()
        }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayMac/ViewModels/MenuBarViewModel.swift ClaudeRelayMac/Views/MainWindow.swift
git commit -m "feat(mac): add MenuBarViewModel and ActiveCoordinatorRegistry"
```

---

### Task 3.4: Build rich MenuBarDropdown

**Files:**
- Modify: `ClaudeRelayMac/Views/MenuBarDropdown.swift`

**Context:** Upgrade the placeholder dropdown (Task 1.3) to show connection state, session list with activity icons, and action buttons.

- [ ] **Step 1: Replace dropdown content**

Replace contents of `ClaudeRelayMac/Views/MenuBarDropdown.swift`:

```swift
import SwiftUI
import AppKit
import ClaudeRelayKit

struct MenuBarDropdown: View {
    @StateObject private var viewModel = MenuBarViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: connection
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.connectionColor)
                    .frame(width: 8, height: 8)
                Text(viewModel.connectionLabel)
                    .font(.headline)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            // Session list
            if viewModel.sessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.sessions, id: \.id) { session in
                        SessionMenuRow(
                            session: session,
                            activity: viewModel.activityStates[session.id] ?? .active,
                            isActive: session.id == viewModel.activeSessionId,
                            onSelect: { activate(sessionId: session.id) }
                        )
                    }
                }
            }

            Divider()

            // Actions
            VStack(alignment: .leading, spacing: 2) {
                MenuButton(label: "Open Window") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                        return
                    }
                }
                MenuButton(label: "Preferences...") {
                    NSApp.sendAction(Selector("showPreferencesWindow:"), to: nil, from: nil)
                }
                MenuButton(label: "Quit Claude Relay") {
                    NSApp.terminate(nil)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 280)
    }

    private func activate(sessionId: UUID) {
        // Switch and focus the main window.
        if let coordinator = ActiveCoordinatorRegistry.shared.coordinator {
            Task { await coordinator.switchToSession(id: sessionId) }
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}

private struct SessionMenuRow: View {
    let session: SessionInfo
    let activity: ActivityState
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 10))
                Text(session.name ?? String(session.id.uuidString.prefix(8)))
                    .foregroundStyle(.primary)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.accentColor)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        switch activity {
        case .claudeActive: return "circle.fill"
        case .claudeIdle:   return "circle.lefthalf.filled"
        case .idle, .active: return "circle"
        }
    }
    private var iconColor: Color {
        switch activity {
        case .claudeActive: return .green
        case .claudeIdle:   return .orange
        case .idle, .active: return .secondary
        }
    }
}

private struct MenuButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual test**

Run the app. Connect to a server. Click the menu bar icon — verify the dropdown shows server name, session list with activity icons, clickable rows that switch sessions, and the action buttons.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayMac/Views/MenuBarDropdown.swift
git commit -m "feat(mac): rich menu bar dropdown with session list and actions"
```

---

### Task 3.5: Build SettingsView with tabs

**Files:**
- Modify: `ClaudeRelayMac/Views/SettingsView.swift`

**Context:** Native macOS Settings window (`Cmd+,`). Three tabs: General (launch at login, default server, naming theme), Speech (placeholder for Phase 4 model management), Servers (embedded server list).

- [ ] **Step 1: Replace placeholder SettingsView**

Replace contents of `ClaudeRelayMac/Views/SettingsView.swift`:

```swift
import SwiftUI
import ClaudeRelayClient

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings)
                .tabItem { Label("General", systemImage: "gear") }

            SpeechSettingsTab()
                .tabItem { Label("Speech", systemImage: "mic") }

            ServersSettingsTab()
                .tabItem { Label("Servers", systemImage: "server.rack") }
        }
        .frame(width: 600, height: 420)
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Show window on launch", isOn: $settings.showWindowOnLaunch)
            // Launch at login toggle added in Task 3.10.
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct SpeechSettingsTab: View {
    var body: some View {
        Form {
            Section("Speech-to-Text") {
                Text("Speech engine configuration available in Phase 4.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ServersSettingsTab: View {
    var body: some View {
        ServerListWindow { _ in
            // No connect action from settings — just manage the list.
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual test**

Run the app. Press `Cmd+,`. Verify Settings window opens with three tabs.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayMac/Views/SettingsView.swift
git commit -m "feat(mac): Settings window with General/Speech/Servers tabs"
```

---

### Task 3.6: Create NetworkMonitor

**Files:**
- Create: `ClaudeRelayMac/Helpers/NetworkMonitor.swift`

**Context:** Wraps `NWPathMonitor` to publish connectivity state. On transition from unsatisfied → satisfied, post a notification so the coordinator can force-reconnect without waiting for backoff.

- [ ] **Step 1: Write the monitor**

Create `ClaudeRelayMac/Helpers/NetworkMonitor.swift`:

```swift
import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isConnected = true

    static let connectivityRestored = Notification.Name("com.clauderelay.mac.connectivityRestored")

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.clauderelay.mac.networkMonitor")
    private var wasDisconnected = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let priorDisconnected = self.wasDisconnected
                self.isConnected = connected
                if !connected {
                    self.wasDisconnected = true
                } else if priorDisconnected {
                    self.wasDisconnected = false
                    NotificationCenter.default.post(name: Self.connectivityRestored, object: nil)
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
```

- [ ] **Step 2: Build & commit**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
git add ClaudeRelayMac/Helpers/NetworkMonitor.swift
git commit -m "feat(mac): NetworkMonitor that posts notification on connectivity restore"
```

---

### Task 3.7: Create SleepWakeObserver

**Files:**
- Create: `ClaudeRelayMac/Helpers/SleepWakeObserver.swift`

**Context:** Observes `NSWorkspace.willSleepNotification` and `didWakeNotification`. On wake, posts a notification that the coordinator listens for.

- [ ] **Step 1: Write the observer**

Create `ClaudeRelayMac/Helpers/SleepWakeObserver.swift`:

```swift
import Foundation
import AppKit

final class SleepWakeObserver: @unchecked Sendable {

    static let systemDidWake = Notification.Name("com.clauderelay.mac.systemDidWake")

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { _ in
            // Just log; recovery happens on wake.
            NSLog("[Mac] System will sleep")
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in
            NSLog("[Mac] System did wake")
            NotificationCenter.default.post(name: Self.systemDidWake, object: nil)
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
    }
}
```

- [ ] **Step 2: Instantiate in AppDelegate**

Update `ClaudeRelayMac/AppDelegate.swift`:

```swift
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sleepWakeObserver: SleepWakeObserver?
    private var networkMonitor: NetworkMonitor?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        sleepWakeObserver = SleepWakeObserver()
        networkMonitor = NetworkMonitor()
    }
}
```

- [ ] **Step 3: Build & commit**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
git add ClaudeRelayMac/Helpers/SleepWakeObserver.swift ClaudeRelayMac/AppDelegate.swift
git commit -m "feat(mac): SleepWakeObserver posts notification on system wake"
```

---

### Task 3.8: Implement foreground recovery in SessionCoordinator

**Files:**
- Modify: `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`

**Context:** Mirror iOS `handleForegroundTransition`. Subscribe to `SleepWakeObserver.systemDidWake` and `NetworkMonitor.connectivityRestored` notifications. On wake or reconnect, ping the WebSocket; if dead, reconnect, re-auth, resume.

- [ ] **Step 1: Add recovery methods to SessionCoordinator**

Append to `SessionCoordinator`:

```swift
    // MARK: - Recovery

    private var recoveryObservers: [NSObjectProtocol] = []

    func registerRecoveryObservers() {
        let center = NotificationCenter.default
        let wakeObs = center.addObserver(
            forName: SleepWakeObserver.systemDidWake,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleForegroundTransition()
            }
        }
        let netObs = center.addObserver(
            forName: NetworkMonitor.connectivityRestored,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleForegroundTransition()
            }
        }
        recoveryObservers = [wakeObs, netObs]
    }

    func unregisterRecoveryObservers() {
        for obs in recoveryObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        recoveryObservers.removeAll()
    }

    func handleForegroundTransition() async {
        guard !isRecovering, !isTornDown else { return }

        let alive = await connection.isAlive()
        if alive {
            await fetchSessions()
            return
        }

        isRecovering = true
        defer { isRecovering = false }

        do {
            try await connection.forceReconnect()
        } catch {
            guard !isTornDown else { return }
            if !(error is CancellationError) {
                connectionTimedOut = true
            }
            return
        }

        guard !isTornDown else { return }
        await restoreSession()
    }

    private func handleAutoReconnect() async {
        isRecovering = true
        defer { isRecovering = false }
        await restoreSession()
    }

    private func restoreSession() async {
        sessionController?.resetAuth()
        do {
            let controller = try await ensureAuthenticated()
            guard !isTornDown else { return }
            if let activeId = activeSessionId {
                terminalViewModels[activeId]?.resetForReplay()
                try await controller.resumeSession(id: activeId)
                wireTerminalOutput(to: activeId)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isTornDown else { return }
            if activeSessionId != nil {
                activeSessionId = nil
            }
            connectionTimedOut = true
            return
        }

        if !isTornDown {
            await fetchSessions()
        }
    }
```

- [ ] **Step 2: Register observers when coordinator starts, unregister on tearDown**

Update `SessionCoordinator.start()`. After `try await connection.connect(...)`, add:

```swift
            registerRecoveryObservers()
```

Update `tearDown()`:

```swift
    func tearDown() {
        isTornDown = true
        unregisterRecoveryObservers()
        recoveryTask?.cancel()
        recoveryTask = nil
        if activeSessionId != nil {
            Task { try? await sessionController?.detach() }
        }
        connection.disconnect()
    }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual test**

Run the app. Connect to a server. Put the Mac to sleep (`Apple menu → Sleep`). Wake it. Verify:
- The terminal reconnects automatically
- The terminal content is preserved (scrollback replayed)

Alternative: toggle airplane mode to simulate network loss, then disable — verify reconnect.

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayMac/ViewModels/SessionCoordinator.swift
git commit -m "feat(mac): foreground recovery on wake and network restore"
```

---

### Task 3.9: Implement session naming themes

**Files:**
- Create: `ClaudeRelayMac/Models/SessionNamingTheme.swift`
- Modify: `ClaudeRelayMac/Models/AppSettings.swift`
- Modify: `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`
- Modify: `ClaudeRelayMac/Views/SettingsView.swift`

**Context:** Port the iOS naming themes (Game of Thrones, Viking, Star Wars, Dune, Lord of the Rings). Uses the exact same name lists as the iOS app (copy them verbatim from `ClaudeRelayApp/Models/AppSettings.swift`). `SessionCoordinator.pickDefaultName()` uses the user's selected theme.

- [ ] **Step 1: Create the theme enum**

Create `ClaudeRelayMac/Models/SessionNamingTheme.swift`:

```swift
import Foundation

enum SessionNamingTheme: String, CaseIterable, Identifiable {
    case gameOfThrones = "gameOfThrones"
    case viking = "viking"
    case starWars = "starWars"
    case dune = "dune"
    case lordOfTheRings = "lordOfTheRings"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gameOfThrones: return "Game of Thrones"
        case .viking: return "Viking"
        case .starWars: return "Star Wars"
        case .dune: return "Dune"
        case .lordOfTheRings: return "Lord of the Rings"
        }
    }

    var names: [String] {
        switch self {
        case .gameOfThrones: return Self.gotNames
        case .viking: return Self.vikingNames
        case .starWars: return Self.starWarsNames
        case .dune: return Self.duneNames
        case .lordOfTheRings: return Self.lotrNames
        }
    }

    static let gotNames = [
        "Arya", "Tyrion", "Daenerys", "Jon Snow", "Cersei",
        "Sansa", "Bran", "Jaime", "Brienne", "Theon",
        "Samwell", "Jorah", "Davos", "Missandei", "Varys",
        "Tormund", "Podrick", "Gendry", "Bronn", "Sandor",
        "Melisandre", "Ygritte", "Oberyn", "Margaery", "Olenna",
        "Ramsay", "Stannis", "Robb", "Catelyn", "Ned",
        "Hodor", "Gilly", "Drogo", "Viserys", "Littlefinger",
        "Tywin", "Joffrey", "Tommen", "Myrcella", "Rickon"
    ]

    static let vikingNames = [
        "Ragnar", "Lagertha", "Bjorn", "Rollo", "Floki",
        "Ivar", "Ubbe", "Sigurd", "Hvitserk", "Aslaug",
        "Athelstan", "Helga", "Torvi", "Harald", "Halfdan",
        "Freydis", "Leif", "Erik", "Gunnar", "Sigrid",
        "Thorstein", "Ingrid", "Arne", "Astrid", "Brynhild",
        "Odin", "Thor", "Freya", "Tyr", "Loki"
    ]

    static let starWarsNames = [
        "Luke", "Leia", "Han Solo", "Chewie", "Vader",
        "Obi-Wan", "Yoda", "Palpatine", "Anakin", "Padme",
        "Ahsoka", "Rex", "Mace Windu", "Qui-Gon", "Maul",
        "Dooku", "Grievous", "Tarkin", "Lando", "Boba Fett",
        "Rey", "Kylo Ren", "Finn", "Poe", "Hux",
        "Din Djarin", "Grogu", "Bo-Katan", "Cara Dune", "Greef"
    ]

    static let duneNames = [
        "Paul", "Chani", "Leto", "Jessica", "Stilgar",
        "Duncan", "Gurney", "Thufir", "Alia", "Irulan",
        "Feyd", "Baron", "Rabban", "Piter", "Shaddam",
        "Liet", "Harah", "Jamis", "Mohiam", "Mapes",
        "Idaho", "Ghanima", "Farad'n", "Usul", "Muad'Dib"
    ]

    static let lotrNames = [
        "Frodo", "Sam", "Gandalf", "Aragorn", "Legolas",
        "Gimli", "Boromir", "Merry", "Pippin", "Gollum",
        "Saruman", "Sauron", "Elrond", "Galadriel", "Arwen",
        "Eowyn", "Theoden", "Eomer", "Faramir", "Denethor",
        "Treebeard", "Radagast", "Bilbo", "Thorin", "Balin",
        "Dwalin", "Fili", "Kili", "Smaug", "Shelob"
    ]
}
```

- [ ] **Step 2: Add sessionNamingTheme to AppSettings**

In `ClaudeRelayMac/Models/AppSettings.swift`, add:

```swift
    @AppStorage("com.clauderelay.mac.sessionNamingTheme") var sessionNamingTheme: SessionNamingTheme = .gameOfThrones
```

Note: `@AppStorage` needs `SessionNamingTheme` to be `RawRepresentable` with `String` raw values — it already is.

- [ ] **Step 3: Update SessionCoordinator.pickDefaultName()**

In `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`, replace the `pickDefaultName()` function:

```swift
    private func pickDefaultName() -> String {
        let usedNames = Set(sessionNames.values)
        let themeNames = AppSettings.shared.sessionNamingTheme.names
        let available = themeNames.filter { !usedNames.contains($0) }
        return available.randomElement() ?? "Session \(sessionNames.count + 1)"
    }
```

- [ ] **Step 4: Add theme picker to SettingsView → General**

In `ClaudeRelayMac/Views/SettingsView.swift`, update `GeneralSettingsTab`:

```swift
private struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Session naming theme", selection: $settings.sessionNamingTheme) {
                    ForEach(SessionNamingTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
            }
            Section("Launch") {
                Toggle("Show window on launch", isOn: $settings.showWindowOnLaunch)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

- [ ] **Step 5: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Manual test**

Open Settings, change the theme. Create a new session. Verify the name matches the picked theme.

- [ ] **Step 7: Commit**

```bash
git add ClaudeRelayMac/Models/SessionNamingTheme.swift \
        ClaudeRelayMac/Models/AppSettings.swift \
        ClaudeRelayMac/ViewModels/SessionCoordinator.swift \
        ClaudeRelayMac/Views/SettingsView.swift
git commit -m "feat(mac): session naming themes with Settings picker"
```

---

### Task 3.10: Implement launch-at-login

**Files:**
- Create: `ClaudeRelayMac/Helpers/LaunchAtLogin.swift`
- Modify: `ClaudeRelayMac/Views/SettingsView.swift`
- Modify: `ClaudeRelayMac/Models/AppSettings.swift`

**Context:** macOS 13+ uses `SMAppService.mainApp` to register the app as a login item. When launched at login, the app starts with the window hidden (menu bar only).

- [ ] **Step 1: Create the helper**

Create `ClaudeRelayMac/Helpers/LaunchAtLogin.swift`:

```swift
import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { return }
        if enabled {
            if SMAppService.mainApp.status == .enabled { return }
            try SMAppService.mainApp.register()
        } else {
            if SMAppService.mainApp.status == .notRegistered { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 2: Add launchAtLogin to AppSettings**

In `ClaudeRelayMac/Models/AppSettings.swift`, add:

```swift
    @AppStorage("com.clauderelay.mac.launchAtLogin") var launchAtLoginEnabled = false
```

- [ ] **Step 3: Add toggle to Settings General tab**

Update `GeneralSettingsTab` in `ClaudeRelayMac/Views/SettingsView.swift`:

```swift
            Section("Launch") {
                Toggle("Show window on launch", isOn: $settings.showWindowOnLaunch)
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLoginEnabled },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                            settings.launchAtLoginEnabled = newValue
                        } catch {
                            NSLog("[Mac] LaunchAtLogin toggle failed: \(error)")
                        }
                    }
                ))
            }
```

- [ ] **Step 4: Hide window on launch if launched-at-login and showWindowOnLaunch is false**

Modify `ClaudeRelayMacApp.swift`. After the `WindowGroup` declaration, the `.defaultAppStorage` approach doesn't work for hiding windows directly. Instead, handle in `AppDelegate`:

In `AppDelegate.applicationDidFinishLaunching`, add:

```swift
        if !AppSettings.shared.showWindowOnLaunch {
            // Close the initial window; user can reopen via menu bar.
            DispatchQueue.main.async {
                for window in NSApp.windows where window.canBecomeMain {
                    window.close()
                }
            }
        }
```

Note: `AppSettings.shared` access must be `@MainActor`. Wrap in a MainActor block:

```swift
        Task { @MainActor in
            if !AppSettings.shared.showWindowOnLaunch {
                for window in NSApp.windows where window.canBecomeMain {
                    window.close()
                }
            }
        }
```

- [ ] **Step 5: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Manual test**

1. Open Settings. Toggle "Launch at login" on. Verify it persists.
2. Quit the app. Reboot the Mac (or log out and back in).
3. Verify the app launches and appears in the menu bar.
4. If "Show window on launch" is off, verify the main window does NOT appear — only the menu bar icon.

- [ ] **Step 7: Commit**

```bash
git add ClaudeRelayMac/Helpers/LaunchAtLogin.swift \
        ClaudeRelayMac/Models/AppSettings.swift \
        ClaudeRelayMac/Views/SettingsView.swift \
        ClaudeRelayMac/AppDelegate.swift
git commit -m "feat(mac): launch-at-login via SMAppService with menu-bar-only mode"
```

**Phase 3 exit criteria met:** Menu bar commands, keyboard shortcuts, preferences, sleep/wake recovery, naming themes, launch-at-login.

---

## Phase 4 — Media & Speech

**Goal**: Image paste (clipboard + drag-and-drop), QR code generation + camera scanning, on-device speech engine.

---

### Task 4.1: Create ImagePasteHandler

**Files:**
- Create: `ClaudeRelayMac/Helpers/ImagePasteHandler.swift`

**Context:** Inspects `NSPasteboard` for image content, converts to PNG `Data`. Reused by both clipboard paste and drag-and-drop paths.

- [ ] **Step 1: Write the helper**

Create `ClaudeRelayMac/Helpers/ImagePasteHandler.swift`:

```swift
import Foundation
import AppKit
import UniformTypeIdentifiers

enum ImagePasteHandler {

    /// Returns image PNG data from the system pasteboard, or nil if clipboard has no image.
    static func extractFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Data? {
        // Try PNG first
        if let pngData = pasteboard.data(forType: .png) {
            return pngData
        }
        // Fall back to TIFF and convert
        if let tiffData = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiffData),
           let pngData = rep.representation(using: .png, properties: [:]) {
            return pngData
        }
        // Try an NSImage — covers JPEG, HEIC, and file URLs to images.
        if let image = NSImage(pasteboard: pasteboard),
           let tiffRep = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiffRep),
           let pngData = rep.representation(using: .png, properties: [:]) {
            return pngData
        }
        return nil
    }

    /// Converts arbitrary image data (JPEG, TIFF, HEIC, PNG) to PNG.
    /// Returns nil if the data isn't a decodable image.
    static func convertToPNG(_ data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiffRep = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffRep),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData
    }

    /// Loads and converts an image file at the given URL to PNG data.
    static func convertFileToPNG(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return convertToPNG(data)
    }
}
```

- [ ] **Step 2: Build & commit**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
git add ClaudeRelayMac/Helpers/ImagePasteHandler.swift
git commit -m "feat(mac): ImagePasteHandler for extracting/converting image data"
```

---

### Task 4.2: Implement clipboard image paste

**Files:**
- Modify: `ClaudeRelayMac/Views/TerminalContainerView.swift`

**Context:** Override the terminal view's paste behavior. SwiftTerm's `TerminalView` handles `Cmd+V` by default and pastes as text. We need to intercept paste on `NSTerminalView` to check for image data first, and if none, fall through to text paste. We do this by subclassing `TerminalView` (or wrapping the `NSView` in a paste-aware host view).

- [ ] **Step 1: Create a TerminalHostView subclass**

Add this subclass in `ClaudeRelayMac/Views/TerminalContainerView.swift` (at file scope, outside the `TerminalContainerView` struct):

```swift
/// Wraps a SwiftTerm TerminalView and intercepts Cmd+V to handle image paste.
final class PasteAwareTerminalView: TerminalView {

    /// Callback when an image was found on the pasteboard and handled.
    var onImagePaste: ((Data) -> Void)?

    override func paste(_ sender: Any?) {
        // If the clipboard holds an image, handle it specially.
        if let pngData = ImagePasteHandler.extractFromPasteboard() {
            onImagePaste?(pngData)
            return
        }
        // Otherwise, fall through to SwiftTerm's default text paste.
        super.paste(sender)
    }
}
```

- [ ] **Step 2: Use `PasteAwareTerminalView` in makeNSView**

In `TerminalContainerView.makeNSView`, change:

```swift
        let terminal = TerminalView(frame: .zero)
```

to:

```swift
        let terminal = PasteAwareTerminalView(frame: .zero)
        terminal.onImagePaste = { [weak viewModel] data in
            viewModel?.sendPasteImage(data)
        }
```

Update the `makeNSView` return type to match — since `PasteAwareTerminalView` is a subclass, this still returns `TerminalView` through upcast. To keep the types tight, change the `NSViewRepresentable` associated type to `PasteAwareTerminalView` or use polymorphism. Simplest: update the method signatures:

```swift
    func makeNSView(context: Context) -> PasteAwareTerminalView {
```

And:

```swift
    func updateNSView(_ nsView: PasteAwareTerminalView, context: Context) {
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual test**

1. Start a session with Claude Code.
2. Copy an image to clipboard (screenshot with `Cmd+Shift+5`).
3. Focus the terminal, press `Cmd+V`.
4. Verify the image is sent to the server — Claude Code should show it attached to the next prompt.

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayMac/Views/TerminalContainerView.swift
git commit -m "feat(mac): intercept Cmd+V for image paste, fall through to text paste"
```

---

### Task 4.3: Implement drag-and-drop image paste

**Files:**
- Modify: `ClaudeRelayMac/Views/TerminalContainerView.swift`

**Context:** Register `PasteAwareTerminalView` as a drop target for image data and image file URLs. On drop, read the image, convert to PNG, send via `sendPasteImage`.

- [ ] **Step 1: Add drop target support in PasteAwareTerminalView**

Extend `PasteAwareTerminalView` in `ClaudeRelayMac/Views/TerminalContainerView.swift`:

```swift
final class PasteAwareTerminalView: TerminalView {

    var onImagePaste: ((Data) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.png, .tiff, .fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.png, .tiff, .fileURL])
    }

    override func paste(_ sender: Any?) {
        if let pngData = ImagePasteHandler.extractFromPasteboard() {
            onImagePaste?(pngData)
            return
        }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.availableType(from: [.png, .tiff, .fileURL]) != nil {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        // Direct image data first.
        if let pngData = ImagePasteHandler.extractFromPasteboard(pasteboard) {
            onImagePaste?(pngData)
            return true
        }

        // File URLs: look for image extensions.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let pngData = ImagePasteHandler.convertFileToPNG(at: url) {
                    onImagePaste?(pngData)
                    return true
                }
            }
        }
        return false
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual test**

1. Start a session with Claude Code.
2. Drag an image file (e.g. from Finder) onto the terminal view.
3. Verify the image is sent to the server.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayMac/Views/TerminalContainerView.swift
git commit -m "feat(mac): drag-and-drop image paste onto terminal"
```

---

### Task 4.4: Create QRCodePopover

**Files:**
- Create: `ClaudeRelayMac/Views/QRCodePopover.swift`
- Modify: `ClaudeRelayMac/Views/MainWindow.swift` (add toolbar button to show the popover)

**Context:** Renders the current session's attach URL as a QR code. Format: `coderelay://session/<uuid>`. Uses CoreImage `CIQRCodeGenerator` filter. Displayed in a popover anchored to a toolbar button.

- [ ] **Step 1: Write the popover view**

Create `ClaudeRelayMac/Views/QRCodePopover.swift`:

```swift
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

struct QRCodePopover: View {
    let sessionId: UUID
    let sessionName: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(sessionName ?? String(sessionId.uuidString.prefix(8)))
                .font(.headline)
            if let image = generateQRCode() {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
            } else {
                Text("Failed to generate QR code")
                    .foregroundStyle(.red)
            }
            Text("coderelay://session/\(sessionId.uuidString)")
                .font(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(16)
        .frame(width: 260)
    }

    private func generateQRCode() -> NSImage? {
        let urlString = "coderelay://session/\(sessionId.uuidString)"
        guard let data = urlString.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = ciImage.transformed(by: scale)

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: scaled.extent.size)
    }
}
```

- [ ] **Step 2: Add a toolbar button to show the popover**

In `ClaudeRelayMac/Views/MainWindow.swift`, add `@State` to `MainWindow`:

```swift
    @State private var showQRPopover = false
```

In the `.toolbar` modifier, add a trailing item. After the existing `ToolbarItem(placement: .navigation)` block, append:

```swift
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showQRPopover = true
                } label: {
                    Label("Share via QR Code", systemImage: "qrcode")
                }
                .disabled(coordinator?.activeSessionId == nil)
                .popover(isPresented: $showQRPopover, arrowEdge: .bottom) {
                    if let coordinator, let id = coordinator.activeSessionId {
                        QRCodePopover(sessionId: id, sessionName: coordinator.name(for: id))
                    }
                }
            }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual test**

Start a session. Click the QR button in the toolbar. Verify:
- Popover appears with a QR code
- Session name is shown
- URL text below QR is selectable

Scan the QR with the iOS app — verify it attaches to the session.

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayMac/Views/QRCodePopover.swift ClaudeRelayMac/Views/MainWindow.swift
git commit -m "feat(mac): QR code popover for sharing sessions to mobile"
```

---

### Task 4.5: Create QRScannerView

**Files:**
- Create: `ClaudeRelayMac/Views/QRScannerView.swift`
- Modify: `ClaudeRelayMac/ClaudeRelayMacApp.swift` (handle `coderelay://` deep link)
- Modify: `ClaudeRelayMac/Helpers/AppCommands.swift` (add Scan QR menu item)

**Context:** Uses `AVCaptureSession` with `AVCaptureMetadataOutput` for QR detection. Wrapped in `NSViewRepresentable`. On scan, parses the `coderelay://session/<uuid>` URL and triggers attach via the coordinator.

- [ ] **Step 1: Write the scanner**

Create `ClaudeRelayMac/Views/QRScannerView.swift`:

```swift
import SwiftUI
import AVFoundation
import AppKit

struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator: SessionCoordinator
    @State private var errorMessage: String?
    @State private var scannedValue: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Scan QR Code")
                .font(.headline)
                .padding()

            if let errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QRScannerRepresentable(onScan: handleScan, onError: handleError)
                    .frame(width: 480, height: 360)
                    .background(.black)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 460)
    }

    private func handleScan(_ value: String) {
        guard scannedValue == nil else { return }
        scannedValue = value
        if let url = URL(string: value), url.scheme == "clauderelay",
           url.host == "session",
           let uuidString = url.pathComponents.dropFirst().first,
           let uuid = UUID(uuidString: uuidString) {
            Task {
                await coordinator.attachRemoteSession(id: uuid)
                dismiss()
            }
        } else {
            errorMessage = "Invalid QR code format."
        }
    }

    private func handleError(_ error: String) {
        errorMessage = error
    }
}

/// AVFoundation QR scanner wrapped in NSViewRepresentable.
private struct QRScannerRepresentable: NSViewRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError)
    }

    func makeNSView(context: Context) -> NSView {
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.cgColor

        let session = AVCaptureSession()
        context.coordinator.session = session

        guard let device = AVCaptureDevice.default(for: .video) else {
            onError("No camera available.")
            return containerView
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) { session.addOutput(output) }
            output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]
        } catch {
            onError("Camera setup failed: \(error.localizedDescription)")
            return containerView
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = containerView.bounds
        containerView.layer?.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.previewLayer?.frame = nsView.bounds
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.session?.stopRunning()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onScan: (String) -> Void
        let onError: (String) -> Void
        var session: AVCaptureSession?
        var previewLayer: AVCaptureVideoPreviewLayer?

        init(onScan: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onError = onError
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else { return }
            session?.stopRunning()
            onScan(value)
        }
    }
}
```

- [ ] **Step 2: Add menu item to trigger the scanner**

In `ClaudeRelayMac/Helpers/AppCommands.swift`, add a `@State`-held binding isn't available in Commands, so expose the trigger via the coordinator. Add a `@Published var showQRScanner = false` to SessionCoordinator:

```swift
    @Published var showQRScanner = false
```

In `AppCommands.body`'s `CommandMenu("Session")`, append a button:

```swift
            Divider()

            Button("Scan QR Code...") {
                coordinator?.showQRScanner = true
            }
            .keyboardShortcut("q", modifiers: [.command, .shift])
            .disabled(coordinator == nil)
```

- [ ] **Step 3: Present the sheet from WorkspaceView**

In `ClaudeRelayMac/Views/MainWindow.swift`, in `WorkspaceView.body`, add a sheet modifier to the outer `NavigationSplitView`:

```swift
        .sheet(isPresented: $coordinator.showQRScanner) {
            QRScannerSheet(coordinator: coordinator)
        }
```

- [ ] **Step 4: Handle deep link from menu bar or external URL open**

In `ClaudeRelayMac/ClaudeRelayMacApp.swift`, add `.onOpenURL` to the `WindowGroup` content:

```swift
        WindowGroup("Claude Relay") {
            MainWindow()
                .frame(minWidth: 800, minHeight: 500)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
```

And add the handler as a private func at the bottom of `ClaudeRelayMacApp`:

```swift
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "clauderelay",
              url.host == "session",
              let uuidString = url.pathComponents.dropFirst().first,
              let uuid = UUID(uuidString: uuidString) else {
            return
        }
        // Route to active coordinator.
        if let coordinator = ActiveCoordinatorRegistry.shared.coordinator {
            Task { await coordinator.attachRemoteSession(id: uuid) }
        }
    }
```

- [ ] **Step 5: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Manual test**

Generate a QR code on the iPhone Claude Relay app. On the Mac: Session menu → Scan QR Code, or `Cmd+Shift+Q`. Hold the phone up to the Mac camera. Verify the Mac attaches to the session.

- [ ] **Step 7: Commit**

```bash
git add ClaudeRelayMac/Views/QRScannerView.swift \
        ClaudeRelayMac/Helpers/AppCommands.swift \
        ClaudeRelayMac/ViewModels/SessionCoordinator.swift \
        ClaudeRelayMac/Views/MainWindow.swift \
        ClaudeRelayMac/ClaudeRelayMacApp.swift
git commit -m "feat(mac): QR code scanner via AVFoundation + deep-link support"
```

---

### Task 4.6: Create SpeechEngineState

**Files:**
- Create: `ClaudeRelayMac/Speech/SpeechEngineState.swift`

**Context:** State enum for the speech pipeline phases. Direct port from iOS — pure Foundation, no platform-specific types.

- [ ] **Step 1: Write the state enum**

Create `ClaudeRelayMac/Speech/SpeechEngineState.swift`:

```swift
import Foundation

enum SpeechEngineState: Equatable {
    case idle
    case loading
    case recording
    case transcribing
    case cleaning
    case enhancing
    case inserting
    case error(String)

    var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }

    var description: String {
        switch self {
        case .idle: return "Idle"
        case .loading: return "Loading model..."
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .cleaning: return "Cleaning..."
        case .enhancing: return "Enhancing..."
        case .inserting: return "Inserting..."
        case .error(let msg): return "Error: \(msg)"
        }
    }
}
```

- [ ] **Step 2: Build & commit**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
git add ClaudeRelayMac/Speech/SpeechEngineState.swift
git commit -m "feat(mac): SpeechEngineState enum"
```

---

### Task 4.7: Create TextCleaner

**Files:**
- Create: `ClaudeRelayMac/Speech/TextCleaner.swift`

**Context:** Port the iOS `TextCleaner` verbatim — it's pure Foundation regex processing with no platform dependencies. Reference: `ClaudeRelayApp/Speech/TextCleaner.swift`.

- [ ] **Step 1: Copy iOS TextCleaner**

Read the iOS source to get the exact current implementation:

```bash
cat "ClaudeRelayApp/Speech/TextCleaner.swift"
```

Create `ClaudeRelayMac/Speech/TextCleaner.swift` with the same content. If the iOS file imports UIKit (it shouldn't for a pure text cleaner), drop the UIKit import.

If the iOS source uses LLM.swift for cleanup (it does — `TextCleaner.swift` includes LLM model loading), copy it wholesale. The `LLM` import works on macOS because LLM.swift is cross-platform.

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

If the build fails due to iOS-specific imports (e.g. UIKit in the iOS file), strip those. The cleaner should only need Foundation and LLM.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/Speech/TextCleaner.swift
git commit -m "feat(mac): port TextCleaner from iOS for speech-to-text cleanup"
```

---

### Task 4.8: Create AudioCaptureSession

**Files:**
- Create: `ClaudeRelayMac/Speech/AudioCaptureSession.swift`

**Context:** AVAudioEngine wrapper that records 16kHz mono Float32 samples. On macOS, `AVAudioEngine` is available and works identically to iOS. Difference: iOS has `AVAudioSession` for permission/category management; macOS doesn't. Microphone permission is handled via the `NSMicrophoneUsageDescription` Info.plist entry and a `AVCaptureDevice.requestAccess(for: .audio)` call.

- [ ] **Step 1: Write the capture session**

Create `ClaudeRelayMac/Speech/AudioCaptureSession.swift`:

```swift
import Foundation
import AVFoundation

final class AudioCaptureSession: @unchecked Sendable {

    // MARK: - Public API

    static let targetSampleRate: Double = 16000

    /// Called on the audio engine's tap queue with 16kHz mono Float32 samples.
    var onSamples: (([Float]) -> Void)?

    /// Called with the final concatenated buffer when stop() is called.
    var onStop: (([Float]) -> Void)?

    var isRunning: Bool { engine.isRunning }

    // MARK: - Internals

    private let engine = AVAudioEngine()
    private var buffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.clauderelay.mac.audioBuffer")

    // MARK: - Permission

    static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Start / Stop

    func start() throws {
        guard !engine.isRunning else { return }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        // Target format: 16kHz mono Float32 (matches Whisper's expected input).
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioCaptureSession", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create target audio format"])
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "AudioCaptureSession", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
        }

        // Reset buffer.
        bufferQueue.sync { buffer.removeAll(keepingCapacity: true) }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] inputBuffer, _ in
            guard let self else { return }
            let outputCapacity = AVAudioFrameCount(
                Double(inputBuffer.frameLength) * Self.targetSampleRate / inputFormat.sampleRate
            )
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputCapacity
            ) else { return }

            var error: NSError?
            _ = converter.convert(
                to: outputBuffer,
                error: &error,
                withInputFrom: { _, outStatus in
                    outStatus.pointee = .haveData
                    return inputBuffer
                }
            )
            if error != nil { return }

            let frames = Int(outputBuffer.frameLength)
            guard let channelData = outputBuffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frames))

            self.bufferQueue.async {
                self.buffer.append(contentsOf: samples)
            }
            self.onSamples?(samples)
        }

        try engine.start()
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let finalBuffer = bufferQueue.sync { Array(buffer) }
        onStop?(finalBuffer)
    }
}
```

- [ ] **Step 2: Build & commit**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
git add ClaudeRelayMac/Speech/AudioCaptureSession.swift
git commit -m "feat(mac): AudioCaptureSession — 16kHz mono via AVAudioEngine"
```

---

### Task 4.9: Create WhisperTranscriber

**Files:**
- Create: `ClaudeRelayMac/Speech/WhisperTranscriber.swift`

**Context:** Wraps WhisperKit. Port iOS `WhisperTranscriber` — the API is cross-platform.

- [ ] **Step 1: Read iOS implementation**

```bash
cat "ClaudeRelayApp/Speech/WhisperTranscriber.swift"
```

- [ ] **Step 2: Copy to Mac location, strip iOS imports**

Create `ClaudeRelayMac/Speech/WhisperTranscriber.swift` with the same code. Replace any `import UIKit` with nothing (or `import AppKit` if the code needs any AppKit types — it shouldn't for speech). Adjust any `UIDevice` references to use `Host.current()` or drop them.

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

If WhisperKit has macOS-specific availability restrictions, the build will surface them. WhisperKit 0.18+ supports macOS. Adjust imports or add `@available(macOS 14, *)` as needed.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayMac/Speech/WhisperTranscriber.swift
git commit -m "feat(mac): port WhisperTranscriber with macOS platform adjustments"
```

---

### Task 4.10: Create SpeechModelStore and CloudPromptEnhancer

**Files:**
- Create: `ClaudeRelayMac/Speech/SpeechModelStore.swift`
- Create: `ClaudeRelayMac/Speech/CloudPromptEnhancer.swift`

**Context:** Model storage and optional cloud-based prompt enhancement. Port from iOS with path changes — models live in `~/Library/Application Support/ClaudeRelay/Models/` on Mac, not the iOS app's sandboxed Documents directory.

- [ ] **Step 1: Read iOS implementations**

```bash
cat "ClaudeRelayApp/Speech/SpeechModelStore.swift"
cat "ClaudeRelayApp/Speech/CloudPromptEnhancer.swift"
```

- [ ] **Step 2: Copy SpeechModelStore with path change**

Create `ClaudeRelayMac/Speech/SpeechModelStore.swift`. Copy the iOS content, then replace the models directory initializer:

```swift
    /// Directory where downloaded models live.
    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("ClaudeRelay", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }
```

If the iOS version has `UIDevice` or other UIKit references for download progress UI, strip them — the Mac will get a Settings-based progress view later.

- [ ] **Step 3: Copy CloudPromptEnhancer verbatim**

Create `ClaudeRelayMac/Speech/CloudPromptEnhancer.swift`. The iOS version is pure `URLSession` networking (Anthropic Haiku API) and should port unchanged. Remove UIKit import if present.

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayMac/Speech/SpeechModelStore.swift \
        ClaudeRelayMac/Speech/CloudPromptEnhancer.swift
git commit -m "feat(mac): port SpeechModelStore and CloudPromptEnhancer with Mac paths"
```

---

### Task 4.11: Create OnDeviceSpeechEngine and wire it up

**Files:**
- Create: `ClaudeRelayMac/Speech/OnDeviceSpeechEngine.swift`
- Modify: `ClaudeRelayMac/Views/MainWindow.swift` (add mic toolbar button)
- Modify: `ClaudeRelayMac/Models/AppSettings.swift` (speech settings)
- Modify: `ClaudeRelayMac/Views/SettingsView.swift` (speech tab)

**Context:** Orchestrates the full pipeline. Start recording → audio buffer → Whisper → text cleanup → optional cloud enhancement → insert into active terminal. Activation: toolbar mic button for v1. Configurable keyboard shortcut can be added as a follow-up.

- [ ] **Step 1: Read iOS OnDeviceSpeechEngine**

```bash
cat "ClaudeRelayApp/Speech/OnDeviceSpeechEngine.swift"
```

- [ ] **Step 2: Port to Mac**

Create `ClaudeRelayMac/Speech/OnDeviceSpeechEngine.swift`. Copy the iOS content. Adjustments:
- Replace `import UIKit` with nothing.
- Replace `UIDevice` references with `Host.current()` or drop them.
- Insertion target: instead of posting to a shared terminal, have the engine call a callback `onTranscriptionReady: (String) -> Void`. The caller (mic button in MainWindow) wires this to the active `TerminalViewModel.sendInput(_:)`.

Shape the public API:

```swift
@MainActor
final class OnDeviceSpeechEngine: ObservableObject {
    @Published private(set) var state: SpeechEngineState = .idle

    var onTranscriptionReady: ((String) -> Void)?

    private let audio = AudioCaptureSession()
    // plus the WhisperTranscriber, TextCleaner, CloudPromptEnhancer references

    func start() async { ... }
    func stop() async { ... }
}
```

Use the iOS logic for model readiness, Whisper invocation, cleanup, and optional cloud enhancement. At the end of `stop()`, invoke `onTranscriptionReady?(text)` with the final string.

- [ ] **Step 3: Add speech-enabled and API key settings to AppSettings**

In `ClaudeRelayMac/Models/AppSettings.swift`, add:

```swift
    @AppStorage("com.clauderelay.mac.promptEnhancementEnabled") var promptEnhancementEnabled = false
    @AppStorage("com.clauderelay.mac.anthropicAPIKey") var anthropicAPIKey: String = ""
    @AppStorage("com.clauderelay.mac.smartCleanupEnabled") var smartCleanupEnabled = true
```

- [ ] **Step 4: Build Speech settings tab**

In `ClaudeRelayMac/Views/SettingsView.swift`, replace `SpeechSettingsTab`:

```swift
private struct SpeechSettingsTab: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = SpeechModelStore.shared

    var body: some View {
        Form {
            Section("Models") {
                if store.modelsReady {
                    Label("Models downloaded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speech models need to be downloaded before first use (~1 GB).")
                            .foregroundStyle(.secondary)
                        Button(store.isDownloading ? "Downloading..." : "Download Models") {
                            Task { try? await store.downloadIfNeeded() }
                        }
                        .disabled(store.isDownloading)
                        if store.isDownloading {
                            ProgressView(value: store.downloadProgress)
                        }
                    }
                }
            }
            Section("Transcription") {
                Toggle("Smart cleanup (local LLM)", isOn: $settings.smartCleanupEnabled)
                Toggle("Prompt enhancement (Anthropic Haiku)", isOn: $settings.promptEnhancementEnabled)
                if settings.promptEnhancementEnabled {
                    SecureField("Anthropic API Key", text: $settings.anthropicAPIKey)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

Note: The `SpeechModelStore` needs `@MainActor` observable properties (`modelsReady`, `isDownloading`, `downloadProgress`, `downloadIfNeeded()`). Port from iOS.

- [ ] **Step 5: Add mic toolbar button**

In `ClaudeRelayMac/Views/MainWindow.swift`, add state:

```swift
    @StateObject private var speechEngine = OnDeviceSpeechEngine()
```

In the toolbar, add (after QR button):

```swift
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        if speechEngine.state.isActive {
                            await speechEngine.stop()
                        } else {
                            speechEngine.onTranscriptionReady = { [weak coordinator] text in
                                guard let coordinator,
                                      let id = coordinator.activeSessionId,
                                      let vm = coordinator.viewModel(for: id) else { return }
                                vm.sendInput(text)
                            }
                            await speechEngine.start()
                        }
                    }
                } label: {
                    Label(
                        speechEngine.state.isActive ? "Stop Recording" : "Record",
                        systemImage: speechEngine.state.isActive ? "stop.circle.fill" : "mic"
                    )
                }
                .disabled(coordinator?.activeSessionId == nil)
            }
```

- [ ] **Step 6: Build**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **` (assuming all Speech files ported cleanly).

- [ ] **Step 7: Manual test**

1. Open Settings → Speech. Download models if not present.
2. Start a session.
3. Click the mic button in the toolbar. Speak a phrase.
4. Click stop.
5. Verify the transcribed text appears in the terminal.

- [ ] **Step 8: Commit**

```bash
git add ClaudeRelayMac/Speech/OnDeviceSpeechEngine.swift \
        ClaudeRelayMac/Models/AppSettings.swift \
        ClaudeRelayMac/Views/SettingsView.swift \
        ClaudeRelayMac/Views/MainWindow.swift
git commit -m "feat(mac): on-device speech engine with toolbar mic button"
```

**Phase 4 exit criteria met:** Image paste, QR generation, QR scanning, deep links, on-device speech-to-text.

---

## Phase 5 — Cross-Platform Refinement

**Goal**: Extract shared ViewModels between iOS and Mac, align behavior, add test coverage, update docs.

---

### Task 5.1: Audit ViewModel differences between iOS and Mac

**Files:**
- Create: `docs/superpowers/specs/2026-04-28-macos-viewmodel-audit.md` (analysis notes)

**Context:** Before extracting shared code, write down what's identical and what's platform-specific. This informs the protocol boundaries in 5.2.

- [ ] **Step 1: Read both SessionCoordinator implementations side-by-side**

```bash
diff -u ClaudeRelayApp/ViewModels/SessionCoordinator.swift \
        ClaudeRelayMac/ViewModels/SessionCoordinator.swift > /tmp/coord.diff
wc -l /tmp/coord.diff
```

- [ ] **Step 2: Write audit doc**

Create `docs/superpowers/specs/2026-04-28-macos-viewmodel-audit.md` with four sections:
- **Identical logic** (copy-paste between files): list function names, e.g. `ensureAuthenticated`, `fetchSessions`, `handleActivityUpdate`, `handleSessionStolen`, `handleSessionRenamed`, `pickDefaultName` (after themes added in 3.9), `createNewSession`, `switchToSession`, `detachSession`, `terminateSession`, `fetchAttachableSessions`, `attachRemoteSession`.
- **Platform-specific wiring** (same intent, platform differs): device ID source (`UIDevice` vs `IOPlatformExpertDevice`), UserDefaults keys (suffix differs to avoid cross-platform collision).
- **Platform-only** (doesn't exist in the other): none expected for SessionCoordinator after Phase 3; ActiveCoordinatorRegistry is Mac-only.
- **Recommended extractions**: list the ≥10 functions that are identical — those go into a shared base/protocol.

- [ ] **Step 3: Commit the audit**

```bash
git add docs/superpowers/specs/2026-04-28-macos-viewmodel-audit.md
git commit -m "docs: ViewModel audit comparing iOS and Mac SessionCoordinator"
```

---

### Task 5.2: Define shared protocols in ClaudeRelayClient

**Files:**
- Create: `Sources/ClaudeRelayClient/Protocols/SessionCoordinating.swift`

**Context:** Introduce a protocol that formalizes the session coordinator API. Both iOS and Mac conform, enabling shared tests and future ViewModel base classes.

- [ ] **Step 1: Create the protocol**

Create `Sources/ClaudeRelayClient/Protocols/SessionCoordinating.swift`:

```swift
import Foundation
import ClaudeRelayKit

/// Common protocol implemented by iOS and Mac SessionCoordinator.
/// Describes the session lifecycle operations shared between platforms.
@MainActor
public protocol SessionCoordinating: AnyObject {
    var sessions: [SessionInfo] { get }
    var activeSessionId: UUID? { get }
    var ownedSessionIds: Set<UUID> { get }
    var claudeSessions: Set<UUID> { get }
    var sessionsAwaitingInput: Set<UUID> { get }

    func name(for id: UUID) -> String
    func setName(_ name: String, for id: UUID)
    func isRunningClaude(sessionId: UUID) -> Bool

    func fetchSessions() async
    func createNewSession() async
    func switchToSession(id: UUID) async
    func detachSession(id: UUID) async
    func terminateSession(id: UUID) async
    func fetchAttachableSessions() async -> [SessionInfo]
    func attachRemoteSession(id: UUID, serverName: String?) async

    func handleForegroundTransition() async
    func tearDown()
}
```

- [ ] **Step 2: Conform iOS SessionCoordinator to the protocol**

In `ClaudeRelayApp/ViewModels/SessionCoordinator.swift`, change the class declaration:

```swift
final class SessionCoordinator: ObservableObject, SessionCoordinating {
```

- [ ] **Step 3: Conform Mac SessionCoordinator to the protocol**

In `ClaudeRelayMac/ViewModels/SessionCoordinator.swift`, same change:

```swift
final class SessionCoordinator: ObservableObject, SessionCoordinating {
```

The `attachRemoteSession` signature on iOS is `attachRemoteSession(id: UUID, serverName: String? = nil)` — the protocol declares no default, so the conformances implement the two-argument form already.

- [ ] **Step 4: Build both targets**

```bash
# Mac
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
# iOS
xcodebuild -scheme ClaudeRelayApp -destination 'generic/platform=iOS' build 2>&1 | tail -5
# SPM tests
swift test 2>&1 | tail -5
```

Expected: all three succeed.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/Protocols/SessionCoordinating.swift \
        ClaudeRelayApp/ViewModels/SessionCoordinator.swift \
        ClaudeRelayMac/ViewModels/SessionCoordinator.swift
git commit -m "feat(client): SessionCoordinating protocol conformed by iOS and Mac"
```

---

### Task 5.3: Extract shared business logic into ClaudeRelayClient

**Files:**
- Create: `Sources/ClaudeRelayClient/Helpers/SessionNaming.swift`
- Create: `Sources/ClaudeRelayClient/Helpers/ActivityStateMapping.swift`
- Modify: both iOS and Mac SessionCoordinator to use the shared helpers
- Modify: both platforms' SessionNamingTheme (convert to use shared type)

**Context:** Move the name-picking logic, activity-state-to-UI mapping, and naming theme data into the cross-platform `ClaudeRelayClient` library. After this, both apps use the same code for these.

- [ ] **Step 1: Move SessionNamingTheme to ClaudeRelayClient**

Create `Sources/ClaudeRelayClient/Helpers/SessionNaming.swift`:

Copy the full `SessionNamingTheme` enum from `ClaudeRelayMac/Models/SessionNamingTheme.swift` (or iOS `ClaudeRelayApp/Models/AppSettings.swift`) into the new file. Make it `public`:

```swift
import Foundation

public enum SessionNamingTheme: String, CaseIterable, Identifiable, Sendable {
    case gameOfThrones = "gameOfThrones"
    case viking = "viking"
    case starWars = "starWars"
    case dune = "dune"
    case lordOfTheRings = "lordOfTheRings"

    public var id: String { rawValue }

    public var displayName: String { /* ... existing cases ... */ }
    public var names: [String] { /* ... existing cases ... */ }
    // ... name arrays (public static let)
}

public enum SessionNaming {
    /// Picks the next unused theme name, or falls back to "Session N".
    public static func pickDefaultName(
        usedNames: Set<String>,
        theme: SessionNamingTheme,
        fallbackIndex: Int
    ) -> String {
        let available = theme.names.filter { !usedNames.contains($0) }
        return available.randomElement() ?? "Session \(fallbackIndex)"
    }
}
```

- [ ] **Step 2: Delete the duplicates in the app targets**

Delete:
- `ClaudeRelayMac/Models/SessionNamingTheme.swift`

And in `ClaudeRelayApp/Models/AppSettings.swift`, delete the `enum SessionNamingTheme` block (the app will now import it from ClaudeRelayClient).

In both apps' `AppSettings.swift`, ensure `import ClaudeRelayClient` is at the top.

- [ ] **Step 3: Update SessionCoordinator to use SessionNaming**

In both iOS and Mac `SessionCoordinator.swift`, replace the body of `pickDefaultName()`:

```swift
    private func pickDefaultName() -> String {
        SessionNaming.pickDefaultName(
            usedNames: Set(sessionNames.values),
            theme: AppSettings.shared.sessionNamingTheme,
            fallbackIndex: sessionNames.count + 1
        )
    }
```

- [ ] **Step 4: Build all targets and run tests**

```bash
xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build 2>&1 | tail -5
xcodebuild -scheme ClaudeRelayApp -destination 'generic/platform=iOS' build 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Expected: all succeed.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/Helpers/SessionNaming.swift \
        ClaudeRelayApp/Models/AppSettings.swift \
        ClaudeRelayMac/Models/AppSettings.swift \
        ClaudeRelayApp/ViewModels/SessionCoordinator.swift \
        ClaudeRelayMac/ViewModels/SessionCoordinator.swift
git rm ClaudeRelayMac/Models/SessionNamingTheme.swift
git commit -m "refactor(client): extract SessionNamingTheme to cross-platform library"
```

---

### Task 5.4: Align wire protocol behavior between iOS and Mac

**Files:**
- Verification only — no new code expected if audit shows parity.

**Context:** Ensure both apps send identical wire messages for every operation. Check edge cases: reconnection timing, scrollback handling, activity state transitions, session stolen, rename.

- [ ] **Step 1: Trace each wire message through both apps**

For each wire message type, grep for senders in both app codebases and verify the call sites are equivalent:

```bash
# Check each type is sent the same way
for msg in authRequest sessionCreate sessionAttach sessionResume sessionDetach \
           sessionTerminate sessionList sessionListAll sessionRename resize \
           pasteImage ping; do
    echo "=== $msg ==="
    grep -r ".$msg" ClaudeRelayApp/ ClaudeRelayMac/ --include="*.swift" | grep -v "// " | head -3
done
```

Look for any asymmetry. Expected outcome: both apps send the same payload for each operation.

- [ ] **Step 2: Manual parity test**

Run both apps connected to the same server. Perform the same sequence on each:
1. Create a session with name "parity-test".
2. Type `ls` and observe output.
3. Detach.
4. Resume.
5. Rename to "parity-test-renamed".
6. Cross-device attach to a session from the other device.
7. Terminate.

Verify on the server (`claude-relay session list`, `claude-relay logs show`) that both apps produced equivalent server-side behavior.

- [ ] **Step 3: Document findings**

Append a "Wire protocol parity" section to the audit doc with the results. If any divergence was found, fix it in a dedicated commit per divergence.

```bash
git add docs/superpowers/specs/2026-04-28-macos-viewmodel-audit.md
git commit -m "docs: wire protocol parity verification between iOS and Mac clients"
```

---

### Task 5.5: Add shared ViewModel tests

**Files:**
- Create: `Tests/ClaudeRelayClientTests/SessionNamingTests.swift`
- Modify: `Package.swift` (add test target if not present)

**Context:** Unit tests for the extracted shared logic. For `SessionNaming.pickDefaultName`, verify: theme exhaustion falls back to "Session N", unused names are preferred, every theme has non-empty name list.

- [ ] **Step 1: Check if ClaudeRelayClientTests target exists**

```bash
grep -A2 "ClaudeRelayClientTests" Package.swift || echo "not present"
```

If not present, add it. In `Package.swift`, append to `targets`:

```swift
        .testTarget(
            name: "ClaudeRelayClientTests",
            dependencies: ["ClaudeRelayClient"],
            path: "Tests/ClaudeRelayClientTests"
        ),
```

- [ ] **Step 2: Write the test**

Create `Tests/ClaudeRelayClientTests/SessionNamingTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayClient

final class SessionNamingTests: XCTestCase {

    func testEveryThemeHasNames() {
        for theme in SessionNamingTheme.allCases {
            XCTAssertFalse(theme.names.isEmpty, "Theme \(theme.displayName) has empty name list")
        }
    }

    func testPickPrefersUnusedNames() {
        let theme = SessionNamingTheme.starWars
        let used = Set(theme.names.dropLast())  // Only one unused name
        let expected = theme.names.last!
        let picked = SessionNaming.pickDefaultName(
            usedNames: used,
            theme: theme,
            fallbackIndex: 1
        )
        XCTAssertEqual(picked, expected)
    }

    func testPickFallsBackWhenAllNamesUsed() {
        let theme = SessionNamingTheme.viking
        let used = Set(theme.names)
        let picked = SessionNaming.pickDefaultName(
            usedNames: used,
            theme: theme,
            fallbackIndex: 42
        )
        XCTAssertEqual(picked, "Session 42")
    }

    func testAllThemesIdMatchesRawValue() {
        for theme in SessionNamingTheme.allCases {
            XCTAssertEqual(theme.id, theme.rawValue)
        }
    }
}
```

- [ ] **Step 3: Run tests**

```bash
swift test --filter ClaudeRelayClientTests 2>&1 | tail -10
```

Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Tests/ClaudeRelayClientTests/SessionNamingTests.swift
git commit -m "test(client): unit tests for SessionNaming.pickDefaultName"
```

---

### Task 5.6: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `CHANGELOG.md`
- Create: `ClaudeRelayMac/README.md`

**Context:** Update root README and CLAUDE.md to describe the Mac app. Add a Mac section to the project structure. Add CHANGELOG entry. Create Mac setup README.

- [ ] **Step 1: Update README.md**

In `README.md`:

**Architecture section** — after "iOS application with terminal emulation", add:

```markdown
- **ClaudeRelayMac** - Native macOS application with terminal emulation, menu bar persistence, and full iOS feature parity
```

**Project Structure** — add `ClaudeRelayMac/` under the iOS app entry:

```
├── ClaudeRelayApp/             # iOS application (SwiftUI, XcodeGen-managed)
│   ...
├── ClaudeRelayMac/             # macOS application (SwiftUI, XcodeGen-managed)
│   ├── Views/                  # SwiftUI views + menu bar
│   ├── ViewModels/             # Observable view models
│   ├── Models/                 # App settings, saved connections
│   ├── Speech/                 # On-device speech pipeline (WhisperKit + LLM)
│   └── Helpers/                # Network monitor, sleep/wake, image paste
```

**Development — iOS App section** — rename to "iOS & Mac Apps" and add:

```markdown
After generating the Xcode project with `xcodegen generate`, both the iOS and Mac schemes are available. Select `ClaudeRelayApp` for iOS, `ClaudeRelayMac` for macOS.
```

- [ ] **Step 2: Update CLAUDE.md**

In `CLAUDE.md`, update the Architecture section:

Replace "Five SPM targets + one iOS app" with "Five SPM targets + iOS app + macOS app".

Add after the iOS app bullet:

```markdown
- **ClaudeRelayMac/** — macOS SwiftUI app (not in SPM, uses Xcode project). Depends on ClaudeRelayClient + SwiftTerm + WhisperKit + LLM.swift. Menu bar persistent, single-window with sidebar + native tabs.
```

- [ ] **Step 3: Update CHANGELOG.md**

Add at the top (under the `# Changelog` header):

```markdown
## [Unreleased] - macOS App

### Added
- **ClaudeRelayMac** — native macOS client with full iOS feature parity
  - Single-window terminal with sidebar session list and NavigationSplitView layout
  - Menu bar persistent icon (`MenuBarExtra(.window)`) with connection state and session list
  - Keyboard shortcuts: `Cmd+T` new, `Cmd+W` detach, `Cmd+Shift+W` terminate, `Cmd+1..9` switch, `Cmd+0` sidebar, `Cmd+Shift+[/]` prev/next
  - Automatic foreground recovery via `NSWorkspace` sleep/wake and `NWPathMonitor` network change observers
  - Launch-at-login via `SMAppService.mainApp` (macOS 13+)
  - Image paste: `Cmd+V` clipboard and drag-and-drop onto terminal
  - QR code: generation for sharing, camera scanning for attach
  - On-device speech engine: WhisperKit (CoreML/ANE) + LLM.swift (Metal) + optional Anthropic Haiku enhancement
  - Session naming themes shared with iOS
  - `coderelay://session/<uuid>` deep link support

### Shared Library Changes
- `SessionCoordinating` protocol added to `ClaudeRelayClient` (conformed by iOS and Mac)
- `SessionNamingTheme` moved to `ClaudeRelayClient` as cross-platform shared type
- `SessionNaming.pickDefaultName` helper in `ClaudeRelayClient`
- `ClaudeRelayClientTests` target added
```

- [ ] **Step 4: Create ClaudeRelayMac README**

Create `ClaudeRelayMac/README.md`:

```markdown
# ClaudeRelayMac

Native macOS terminal client for ClaudeRelay. Provides persistent terminal sessions with cross-device attach, Claude activity monitoring, on-device speech-to-text, image paste, and QR code session sharing.

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A running ClaudeRelay server (install via `brew install miguelriotinto/clauderelay/clauderelay`)

## Setup

1. **Generate the Xcode project**

   From the repo root:

   ```bash
   xcodegen generate
   ```

2. **Build and run**

   Open `ClaudeRelay.xcodeproj`, select the `ClaudeRelayMac` scheme, choose "My Mac" as the destination, and press Cmd+R.

## First Launch

On first launch, the Server List window appears. Add a server with the host, port, and auth token. Click Connect — the main terminal window opens.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+T` | New session |
| `Cmd+W` | Detach current session |
| `Cmd+Shift+W` | Terminate current session |
| `Cmd+1..9` | Switch to session by index |
| `Cmd+0` | Toggle sidebar |
| `Cmd+Shift+[` / `]` | Previous/next session |
| `Cmd+,` | Preferences |
| `Cmd+Shift+Q` | Scan QR Code |

## Menu Bar

Closing the main window keeps the app running in the menu bar. Click the menu bar icon for the dropdown with session list, connection state, and actions. Quit with `Cmd+Q`.

## File Overview

```
ClaudeRelayMac/
  ClaudeRelayMacApp.swift         -- @main App with Window, MenuBarExtra, Settings scenes
  AppDelegate.swift               -- NSApplicationDelegate: lifecycle, sleep/wake
  ClaudeRelayMac.entitlements     -- Microphone, camera, network entitlements
  Models/
    SavedConnection.swift         -- Persisted server bookmarks (UserDefaults)
    AppSettings.swift             -- User preferences (@AppStorage)
  ViewModels/
    ServerListViewModel.swift     -- Server list, status polling, connection
    AddEditServerViewModel.swift  -- Add/edit server form state
    SessionCoordinator.swift      -- Auth, session lifecycle, I/O routing
    TerminalViewModel.swift       -- Terminal I/O bridge
    MenuBarViewModel.swift        -- Menu bar dropdown state
    ServerStatusChecker.swift     -- TCP-based reachability polling
  Views/
    MainWindow.swift              -- NavigationSplitView: sidebar + terminal + status bar
    ServerListWindow.swift        -- Server configuration window
    AddEditServerView.swift       -- Server config form (sheet)
    SessionSidebarView.swift      -- Session list with activity indicators
    TerminalContainerView.swift   -- NSViewRepresentable SwiftTerm wrapper
    SettingsView.swift            -- Preferences (Cmd+,)
    StatusBarView.swift           -- Bottom connection/activity bar
    MenuBarDropdown.swift         -- Menu bar icon dropdown view
    QRCodePopover.swift           -- QR code generation popover
    QRScannerView.swift           -- AVFoundation camera QR scanner
    AttachRemoteSessionSheet.swift -- Cross-device attach picker
  Speech/
    OnDeviceSpeechEngine.swift    -- WhisperKit orchestrator
    AudioCaptureSession.swift     -- AVAudioEngine 16kHz mono capture
    WhisperTranscriber.swift      -- WhisperKit CoreML/ANE wrapper
    CloudPromptEnhancer.swift     -- Optional Anthropic Haiku enhancement
    SpeechEngineState.swift       -- Pipeline state enum
    SpeechModelStore.swift        -- Model download/caching
    TextCleaner.swift             -- Regex + local LLM cleanup
  Helpers/
    NetworkMonitor.swift          -- NWPathMonitor wrapper
    SleepWakeObserver.swift       -- NSWorkspace sleep/wake observer
    ImagePasteHandler.swift       -- Clipboard/drag-drop image extraction
    AppCommands.swift             -- Menu bar commands with FocusedValue routing
    LaunchAtLogin.swift           -- SMAppService wrapper
```
```

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md CHANGELOG.md ClaudeRelayMac/README.md
git commit -m "docs: document ClaudeRelayMac setup and architecture"
```

**Phase 5 exit criteria met:** Shared logic extracted, both apps pass tests, documentation current.

---

## Completion Checklist

After all 5 phases are complete:

- [ ] All 53 tasks above are checked off
- [ ] `xcodebuild -scheme ClaudeRelayMac -destination 'platform=macOS' build` succeeds
- [ ] `xcodebuild -scheme ClaudeRelayApp -destination 'generic/platform=iOS' build` still succeeds (no iOS regression)
- [ ] `swift test` passes with all existing tests plus new `ClaudeRelayClientTests`
- [ ] Manual smoke test: Mac app launches, connects, creates/attaches sessions, terminal works, menu bar persists, keyboard shortcuts work, image paste works, QR generation works, QR scanning works (with camera-equipped Mac), speech-to-text works (with models downloaded)
- [ ] Cross-device test: Mac and iPhone/iPad attach to the same session, rename propagates, cross-device steal works
- [ ] Documentation current: `README.md`, `CLAUDE.md`, `CHANGELOG.md`, `ClaudeRelayMac/README.md`


