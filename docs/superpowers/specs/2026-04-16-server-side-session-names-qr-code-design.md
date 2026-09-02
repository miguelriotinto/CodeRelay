# Server-Side Session Names + QR Code Session Sharing

**Date:** 2026-04-16
**Status:** Approved

## Problem

Session names are persisted only client-side in iOS UserDefaults. When a second device lists sessions from the server (via the Attach Session sheet), it sees raw UUIDs (e.g. `FF2EF38A`) instead of the names assigned by the creating device (e.g. "Rhaegar"). Names are lost on app reinstall and never shared between devices.

Additionally, there is no quick physical mechanism for sharing a session between two devices that are nearby — the user must scroll through a list of sessions and identify the correct one by UUID.

## Solution

Two coordinated features:

1. **Server-side session names** — Persist names on the server, sync across devices in real-time
2. **QR code session sharing** — Generate/scan QR codes to quickly attach to a session from another device

---

## Feature 1: Server-Side Session Names

### Wire Protocol Changes (ClaudeRelayKit)

#### SessionInfo — New `name` field

```swift
public struct SessionInfo: Codable, Sendable {
    public var id: UUID
    public var name: String?          // NEW — nil for legacy pre-name sessions
    public var state: SessionState
    public var tokenId: String
    public var createdAt: Date
    public var cols: UInt16
    public var rows: UInt16
    public var activity: ActivityState?
}
```

`name` is `String?`. Existing sessions created before this change have `nil`. The client falls back to its local theme name or short UUID.

#### ClientMessage — Modify `sessionCreate`, add `sessionRename`

| Message | Wire Type | Payload | Notes |
|---------|-----------|---------|-------|
| `sessionCreate(name: String?)` | `"session_create"` | `{"name": "Rhaegar"}` | Optional name at creation time |
| `sessionRename(sessionId: UUID, name: String)` | `"session_rename"` | `{"sessionId": "...", "name": "Tyrion"}` | NEW message type |

#### ServerMessage — Add `sessionRenamed` broadcast

| Message | Wire Type | Payload | Notes |
|---------|-----------|---------|-------|
| `sessionRenamed(sessionId: UUID, name: String)` | `"session_renamed"` | `{"sessionId": "...", "name": "Tyrion"}` | NEW broadcast to all token observers |

Type string uniqueness: `"session_rename"` (client) vs `"session_renamed"` (server) — no collision. Follows the established verb/past-tense pattern (e.g. `session_attach` / `session_attached`).

### Server Changes (ClaudeRelayServer)

#### SessionManager

- **Create flow:** `createSession(tokenId:, cols:, rows:, name:)` stores `name` in `SessionInfo`. Returned in `sessionCreated` response and all subsequent list responses.
- **Rename flow:** New method `renameSession(id: UUID, tokenId: String, name: String)`. Validates session exists and belongs to `tokenId`. Updates `info.name`. Broadcasts `sessionRenamed` to all activity observers for that token.
- **Broadcast mechanism:** Reuses existing `activityObservers` infrastructure. When a rename happens, iterates all observers for the session's `tokenId` and pushes the rename event.

#### RelayMessageHandler

Routes `ClientMessage.sessionRename`:
- Validates client is authenticated
- Calls `sessionManager.renameSession(id:, tokenId:, name:)`
- Server broadcasts `ServerMessage.sessionRenamed` to all observers for the token

#### Session list responses

Since `SessionInfo` now includes `name`, both `session_list_result` and `session_list_all_result` automatically include names. No extra work.

#### Admin HTTP API

No changes. SessionInfo serialization naturally includes the new field.

### Client Library Changes (ClaudeRelayClient)

#### SessionController

- `sendSessionCreate(name: String?)` — encodes name in create message
- `sendSessionRename(sessionId: UUID, name: String)` — new method

#### RelayConnection / Message handling

New callback: `var onSessionRenamed: ((UUID, String) -> Void)?`

When `ServerMessage.sessionRenamed` arrives, invokes the callback. Mirrors existing `onSessionActivity` pattern.

### iOS App Changes (ClaudeRelayApp)

#### SessionCoordinator

- **On create:** Picks theme name locally, passes to `sendSessionCreate(name:)`, caches locally.
- **On rename:** Calls `sendSessionRename(sessionId:, name:)`, updates local cache.
- **On `sessionRenamed` broadcast:** Updates `sessionNames[sessionId] = name`. UI reacts via `@Published`.
- **On session list fetch:** Merges server-side names into local cache. Server name wins over local.

#### Display fallback chain

1. Server-provided `SessionInfo.name` (if non-nil)
2. Local `sessionNames[id]` (legacy local name)
3. Short UUID (first 8 characters)

#### Attach Session Sheet

Session rows now display server-side names instead of raw UUIDs.

---

## Feature 2: QR Code Session Sharing

### URL Scheme

Register `coderelay://` URL scheme in `project.yml`:

```
coderelay://session/<full-UUID>
```

Example: `coderelay://session/FF2EF38A-1234-5678-ABCD-1234567890AB`

Camera permission added:

```yaml
INFOPLIST_KEY_NSCameraUsageDescription: "Claude Relay uses the camera to scan QR codes for session sharing."
```

### QR Code Generation — Top Bar Button

In `ActiveTerminalView`, a new QR code button appears to the right of session tabs, left of the session name pill:

```
[← sidebar fn] [●connected 1m] [1] [2] [3]  [⊞QR]  [Rhaegar]
```

- Icon: `qrcode` SF Symbol
- Same size/style as existing tab buttons (`ToolbarIconButton`)
- Tapping sets `showQROverlay = true`

### QR Code Overlay

Full-screen overlay on `ActiveTerminalView`:

- Black dimmed background at ~60% opacity
- QR code (200x200pt) centered, generated via CoreImage `CIQRCodeGenerator`
- Content: `coderelay://session/<full-UUID>` of the active session
- Session name label below QR code for visual confirmation
- Tap anywhere on overlay to dismiss (no explicit close button)
- Interaction feels ephemeral — flash, scan, dismiss

### QR Code Scanning — Attach Sheet

In the `AttachSessionSheet`, below the session list:

```
┌──────────────────────────────────┐
│        Attach Session      Cancel│
│                                  │
│  Rhaegar                 active  │
│  FF2EF38A                        │
│                                  │
│  Tyrion                  active  │
│  9B1C7513                        │
│                                  │
│  ┌──────────────────────────┐    │
│  │  ⊞  Scan QR Code        │    │
│  └──────────────────────────┘    │
└──────────────────────────────────┘
```

Tapping "Scan QR Code" opens a camera sheet:

- `AVCaptureSession` with `AVCaptureMetadataOutput` for `.qr` metadata type
- Camera preview fills sheet, centered viewfinder overlay
- On successful scan of `coderelay://session/<UUID>`:
  - Parses UUID from URL
  - Dismisses camera sheet
  - Dismisses attach sheet
  - Calls `coordinator.attachRemoteSession(id: parsedUUID)`
- Invalid QR codes silently ignored (keep scanning)
- Cancel button to dismiss camera without scanning

### URL Scheme Deep Linking

In `ClaudeRelayApp.swift`, handle `onOpenURL`:

- Parse `coderelay://session/<UUID>`
- If app is connected to a server: attach to session
- If not connected: store pending session ID, attach after connection

### New Components

| Component | Type | Location |
|-----------|------|----------|
| `QRCodeOverlay` | SwiftUI View | Inline in ActiveTerminalView or small standalone file |
| QR generation helper | Extension | `UUID` extension using CoreImage `CIQRCodeGenerator` |
| `QRScannerView` | UIViewRepresentable | New file — wraps AVCaptureSession |
| URL scheme handler | onOpenURL | ClaudeRelayApp.swift |

---

## Files Modified (Summary)

### ClaudeRelayKit (shared models)
- `SessionInfo.swift` — add `name: String?` field
- `ClientMessage.swift` — add `name` to `sessionCreate`, add `sessionRename` case
- `ServerMessage.swift` — add `sessionRenamed` case

### ClaudeRelayServer
- `SessionManager.swift` — accept name in create, add renameSession method, broadcast renames
- `RelayMessageHandler.swift` — route `sessionRename` message

### ClaudeRelayClient
- `SessionController.swift` — add name param to create, add sendSessionRename
- Message handler — route `sessionRenamed` callback

### ClaudeRelayApp (iOS)
- `project.yml` — add `coderelay://` URL scheme, add camera permission
- `SessionCoordinator.swift` — sync names with server, handle rename broadcast
- `ActiveTerminalView.swift` — add QR button to toolbar, add QR overlay
- `SessionSidebarView.swift` — display server names in attach sheet, add Scan QR Code button
- New: `QRScannerView.swift` — camera-based QR scanner (UIViewRepresentable)
- `ClaudeRelayApp.swift` — handle `onOpenURL` for deep linking

### No changes
- `PTYSession.swift` — no name storage needed (SessionManager handles it)
- Admin HTTP API — SessionInfo serialization includes name automatically
- `AdminRoutes.swift` — no new routes needed

---

## Non-Goals

- Session name uniqueness enforcement (names are not unique by design)
- Server-side naming themes (themes remain client-side)
- QR code expiration or one-time-use tokens
- iCloud sync of session names (server is now source of truth)
- Admin API endpoints for rename (WebSocket only)
