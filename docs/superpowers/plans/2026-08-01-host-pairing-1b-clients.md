# Host Pairing Phase 1b (Clients) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a phone or Mac redeem a `claude-relay setup` pairing code — by scanning its QR or typing host+code — so a server is added, authenticated, and listed with no hand-typed token, on iOS, macOS, and Android.

**Architecture:** A pre-auth redeem flow: dial the host from the pairing artifact with a token-less WebSocket connect, send `pair_request`, await `pair_success`, then persist a `ConnectionConfig` + the minted token exactly the way the existing "Add Server" flow does, and hand off to the normal connect+auth path. The redeem logic is a small `PairingController` (one per platform: Swift in `ClaudeRelayClient`, Kotlin in `core-session`) that mirrors `AddEditServerViewModel.save()`. UI is thin: a QR scanner (reusing the existing session-QR scanner infrastructure) and a manual "Pair with a host" sheet (Host + Port + TLS + Code fields, mirroring the Add Server sheet with Code swapping in for Token). A new `coderelay://pair` deep-link route feeds the same redeem path.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, `ClaudeRelayKit`/`ClaudeRelayClient` SPM libraries, XCTest; Kotlin, Jetpack Compose, CameraX + ML Kit (already declared), JUnit 5.

## Global Constraints

- **Manual entry captures host+port+tls+code, not a bare code.** An 8-char pairing code carries no network coordinates; `PairingURL` bundles `host`/`port`/`useTLS`/`code`. The manual sheet therefore has Host, Port, TLS, and Code fields (Code replaces the Token field of the Add Server sheet). The QR-scan path carries the full `coderelay://pair?host=&port=&tls=&code=` URL and needs no extra fields. *(User decision, 2026-08-01.)*
- **One authenticated path only.** Pairing never sets `isAuthenticated`. After `pair_success`, the client persists the token and authenticates with it through the *existing* connect+auth path — there is exactly one way to reach an authenticated connection (mirrors the 1a server-side property).
- **Redeem is a strictly sequential, single-socket RPC.** No request-id correlation exists on the wire; only one RPC may be in flight per connection. `pair_request` → `pair_success` must not overlap any other send (see #44, `connect→auth→list` is one uninterruptible handshake). Replicate `SessionController.awaitResponse`'s pattern: install the subscriber *before* sending, match `expected ∪ {"error"}`, 10 s timeout.
- **Persistence mirrors the existing Add Server flow, does not fork it.** Success path = build `ConnectionConfig(host,port,useTLS from the PairingURL; name from pair_success.label)` → `savedConnections.add(config)` → `AuthManager.shared.saveToken(pair_success.token, for: config.id)`. iOS uses `ClaudeRelayApp.savedConnections`; macOS uses `ClaudeRelayMacApp.savedConnections`; Android uses `SavedConnectionStore` + `TokenStore`.
- **`pair_success.tokenId` is not persisted client-side.** No client store keys by tokenId today; it is redelivered on `auth_success` and used only for session reconciliation. Redeem uses `token` and `label` only.
- **Error surfaces are distinct and actionable:** invalid/expired code (401), rate-limited (429), host unreachable (transport), and TLS-required (CGNAT/public host over `ws://`) each get their own message. Do not collapse them into one "pairing failed."
- **Hostile QR input is rejected in one tested place.** All parsing goes through `PairingURL(url:)` / `PairingURL(string:)` (Swift, shipped in 1a) and its Kotlin port. UI layers never re-parse.
- **macOS gets no camera scanner** — typed-code (Host+Code) sheet only. iOS and Android get both a scanner and the manual sheet.
- **Deep-link scheme is `clauderelay`, pair host is `pair`.** `PairingURL.scheme == "clauderelay"`, `PairingURL.host == "pair"`. The Android manifest already routes `coderelay://` broadly — no manifest change needed.
- **Known pre-existing CI failure:** `swift test` hangs deterministically at `GitRootResolver` case 313 and has not passed since 22 Jul; the app-build jobs gate TestFlight. Verify Swift work with `swift build` + `swift test --filter <SuiteName>`; verify Android with `./gradlew :<module>:testDebugUnitTest`. Report this limitation honestly rather than claiming a full green run.

---

## File Structure

**Swift — shared (`Sources/ClaudeRelayClient/`)**
- `PairingController.swift` (new) — the redeem engine. Pure of UI: takes a `PairingURL`, dials, redeems, persists, returns a `ConnectionConfig`. One home for the pre-auth RPC + persist sequence, consumed by iOS and macOS.

**Swift — iOS (`ClaudeRelayApp/`)**
- `ViewModels/PairingViewModel.swift` (new) — drives the manual sheet fields + invokes `PairingController`, exposes error state.
- `Views/PairWithHostSheet.swift` (new) — the manual Host+Port+TLS+Code sheet.
- `Views/ServerListView.swift` (modify) — add a "Pair" entry (menu → Scan QR / Enter code), present scanner + manual sheet, wire success → connect.
- `ClaudeRelayApp.swift` (modify) — add the `pair` branch to `handleDeepLink`, add `@State pendingPairing`, present the redeem flow on arrival.

**Swift — macOS (`ClaudeRelayMac/`)**
- `Views/PairWithHostSheet.swift` (new) — same manual sheet (no scanner).
- `ViewModels/PairingViewModel.swift` (new) — Mac-flavored (uses `ClaudeRelayMacApp.savedConnections`).
- `Views/ServerListWindow.swift` (modify) — add a "Pair" button next to "Add Server".
- `ClaudeRelayMacApp.swift` (modify) — add the `pair` branch to `handleDeepLink`.

**Kotlin — Android (`ClaudeRelayAndroid/`)**
- `core-protocol/.../PairingMessages.kt` (new or fold into ClientMessage/ServerMessage) — `PairRequest`/`PairSuccess` + envelope encode/decode + `ALL_TYPE_STRINGS`.
- `core-protocol/.../PairingCode.kt` (new) — Kotlin port of `PairingCode`.
- `core-protocol/.../PairingURL.kt` (new) — Kotlin port of `PairingURL`.
- `feature-workspace/.../DeepLinks.kt` (modify) — add `parsePairingUrl`.
- `core-session/.../PairingController.kt` (new) — the Kotlin redeem engine.
- `feature-servers/.../PairWithHostSheet.kt` (new) + `PairingViewModel.kt` (new) — manual sheet + scan entry.
- `feature-servers/.../ServersScreen.kt` (modify) — add Pair entry.
- `app/.../MainActivity.kt` + nav graph (modify) — `pair` deep-link route → Servers.

**Docs**
- `README.md`, `ClaudeRelayApp/README.md`, `ClaudeRelayMac/README.md`, `ClaudeRelayAndroid/README.md` — document the pairing client flow.

---

## Task 1: Swift `PairingController` — pre-auth redeem + persist

**Files:**
- Create: `Sources/ClaudeRelayClient/PairingController.swift`
- Test: `Tests/ClaudeRelayClientTests/PairingControllerTests.swift`

**Interfaces:**
- Consumes: `PairingURL` (`.host`, `.port: UInt16`, `.useTLS`, `.code`, `.wsURL`) and `ConnectionConfig(id:name:host:port:useTLS:)` from `ClaudeRelayKit`/`ClaudeRelayClient`; `RelayConnection` (`init()`, `connect(config:token:)`, `send(_:) async throws`, `addServerMessageSubscriber(_:) -> UUID`, `removeSubscriber(_:)`, `disconnect()`); `ClientMessage.pairRequest(code:deviceName:platform:)`; `ServerMessage.pairSuccess(token:tokenId:label:)` and `.error(code:message:)`; `SavedConnectionStore.add(_:)`; `AuthManager.shared.saveToken(_:for:)`.
- Produces: `PairingController` (init takes a `SavedConnectionStore` + a `deviceName`/`platform` + optional connection factory for tests) with `func pair(_ url: PairingURL) async throws -> ConnectionConfig`, and `enum PairingError: Error` with `.invalidCode`, `.rateLimited`, `.tlsRequired`, `.unreachable`, `.timedOut`, `.server(code:message:)`.

- [ ] **Step 1: Write the failing test — happy path mints and persists**

Use a mock `ConnectionSurface`-style stub. `RelayConnection` conforms to `ConnectionSurface` (see `SessionController.swift`), so define the controller against a small protocol it can inject. Create the test file:

```swift
import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

@MainActor
final class PairingControllerTests: XCTestCase {

    /// Minimal stand-in for the pieces of RelayConnection the controller uses.
    final class MockConnection: PairingConnection {
        var connected: (config: ConnectionConfig, token: String)?
        var sent: [ClientMessage] = []
        var subscriber: ((ServerMessage) -> Void)?
        var disconnected = false
        /// The reply to deliver on the next send, or nil to stay silent (timeout).
        var scriptedReply: ServerMessage?

        func connect(config: ConnectionConfig, token: String) async throws {
            connected = (config, token)
        }
        func addServerMessageSubscriber(_ handler: @escaping (ServerMessage) -> Void) -> UUID {
            subscriber = handler
            return UUID()
        }
        func removeSubscriber(_ id: UUID) { subscriber = nil }
        func send(_ message: ClientMessage) async throws {
            sent.append(message)
            if let reply = scriptedReply { subscriber?(reply) }
        }
        func disconnect() { disconnected = true }
    }

    private func makeStore() -> SavedConnectionStore {
        SavedConnectionStore(key: "test.pairing.\(UUID().uuidString)")
    }

    func testPairMintsTokenPersistsConfigAndToken() async throws {
        let conn = MockConnection()
        conn.scriptedReply = .pairSuccess(token: "tok-abc", tokenId: "id-1", label: "Miguel's iPhone (paired)")
        let store = makeStore()
        let controller = PairingController(
            store: store,
            deviceName: "Miguel's iPhone",
            platform: "ios",
            connectionFactory: { conn })

        let url = PairingURL(host: "silverwing.local", port: 9200, useTLS: false, code: "K7QP2M4X")
        let config = try await controller.pair(url)

        // Sent exactly one pair_request with the right fields.
        XCTAssertEqual(conn.sent.count, 1)
        guard case .pairRequest(let code, let device, let platform) = conn.sent[0] else {
            return XCTFail("expected pair_request, got \(conn.sent)")
        }
        XCTAssertEqual(code, "K7QP2M4X")
        XCTAssertEqual(device, "Miguel's iPhone")
        XCTAssertEqual(platform, "ios")

        // Persisted a config from the URL, named from the label.
        XCTAssertEqual(config.host, "silverwing.local")
        XCTAssertEqual(config.port, 9200)
        XCTAssertFalse(config.useTLS)
        XCTAssertEqual(config.name, "Miguel's iPhone (paired)")
        XCTAssertTrue(store.loadAll().contains { $0.id == config.id })

        // Persisted the token under the config id.
        XCTAssertEqual(try AuthManager.shared.loadToken(for: config.id), "tok-abc")
        try? AuthManager.shared.deleteToken(for: config.id)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter PairingControllerTests/testPairMintsTokenPersistsConfigAndToken`
Expected: FAIL — `PairingController` / `PairingConnection` are not defined.

- [ ] **Step 3: Write the controller**

```swift
import Foundation
import ClaudeRelayKit

/// The subset of `RelayConnection` a `PairingController` needs. Lets tests
/// inject a stub without a live socket. `RelayConnection` satisfies it as-is.
@MainActor
public protocol PairingConnection: AnyObject {
    func connect(config: ConnectionConfig, token: String) async throws
    @discardableResult
    func addServerMessageSubscriber(_ handler: @escaping (ServerMessage) -> Void) -> UUID
    func removeSubscriber(_ id: UUID)
    func send(_ message: ClientMessage) async throws
    func disconnect()
}

extension RelayConnection: PairingConnection {}

public enum PairingError: Error, Equatable {
    case invalidCode        // 401
    case rateLimited        // 429
    case tlsRequired        // ws:// to a host ATS blocks
    case unreachable        // transport failure dialing the host
    case timedOut           // no reply within the deadline
    case server(code: Int, message: String)   // any other server error
}

/// Redeems a pairing code over a fresh, pre-auth WebSocket connection and
/// persists the minted token the same way `AddEditServerViewModel.save()` does.
///
/// One home for the redeem sequence so iOS and macOS share it. It deliberately
/// does NOT authenticate — after `pair()` returns, the caller connects through
/// the normal path with the persisted token, keeping one authenticated path.
@MainActor
public final class PairingController {

    private let store: SavedConnectionStore
    private let deviceName: String
    private let platform: String
    private let connectionFactory: () -> PairingConnection
    private let timeout: Duration

    public init(
        store: SavedConnectionStore,
        deviceName: String,
        platform: String,
        connectionFactory: @escaping () -> PairingConnection = { RelayConnection() },
        timeout: Duration = .seconds(10)
    ) {
        self.store = store
        self.deviceName = deviceName
        self.platform = platform
        self.connectionFactory = connectionFactory
        self.timeout = timeout
    }

    /// Dials the host in `url`, redeems `url.code`, persists a `ConnectionConfig`
    /// plus the minted token, and returns the config. Throws `PairingError` on any
    /// failure. Never leaves a dangling socket.
    public func pair(_ url: PairingURL) async throws -> ConnectionConfig {
        let connection = connectionFactory()

        // A pre-auth dial: connect() stores the token but does not send
        // auth_request, so an empty token is correct here — we redeem first.
        let dialConfig = ConnectionConfig(
            name: url.host, host: url.host, port: url.port, useTLS: url.useTLS)
        do {
            try await connection.connect(config: dialConfig, token: "")
        } catch {
            throw PairingError.unreachable
        }
        defer { connection.disconnect() }

        let reply = try await redeem(url.code, on: connection)
        guard case .pairSuccess(let token, _, let label) = reply else {
            throw mapError(reply)
        }

        let config = ConnectionConfig(
            name: label.isEmpty ? url.host : label,
            host: url.host, port: url.port, useTLS: url.useTLS)
        store.add(config)
        try? AuthManager.shared.saveToken(token, for: config.id)
        return config
    }

    /// Installs the response subscriber BEFORE sending (mirrors
    /// SessionController.awaitResponse), matches pair_success or error, and
    /// resolves within the deadline. Only one RPC is ever in flight here.
    private func redeem(_ code: String, on connection: PairingConnection) async throws -> ServerMessage {
        let matchTypes: Set<String> = ["pair_success", "error"]

        return try await withThrowingTaskGroup(of: ServerMessage.self) { group in
            let box = ContinuationBox()
            let subId = connection.addServerMessageSubscriber { message in
                guard matchTypes.contains(message.typeString) else { return }
                box.resume(with: message)
            }
            defer { connection.removeSubscriber(subId) }

            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { cont in
                    box.attach(cont)
                }
            }
            group.addTask { @MainActor [timeout] in
                try await Task.sleep(for: timeout)
                throw PairingError.timedOut
            }

            do {
                try await connection.send(.pairRequest(
                    code: code, deviceName: deviceName, platform: platform))
            } catch {
                group.cancelAll()
                throw PairingError.unreachable
            }

            guard let result = try await group.next() else { throw PairingError.timedOut }
            group.cancelAll()
            return result
        }
    }

    private func mapError(_ message: ServerMessage) -> PairingError {
        guard case .error(let code, let text) = message else {
            return .server(code: -1, message: "Unexpected reply")
        }
        switch code {
        case 401: return .invalidCode
        case 429: return .rateLimited
        default:  return .server(code: code, message: text)
        }
    }
}

/// Bridges the subscriber callback (sync) to the awaiting continuation. The
/// subscriber may fire before or after the continuation is attached, so it
/// stores the first value and replays it on attach.
@MainActor
private final class ContinuationBox {
    private var continuation: CheckedContinuation<ServerMessage, Error>?
    private var pending: ServerMessage?
    private var done = false

    func attach(_ cont: CheckedContinuation<ServerMessage, Error>) {
        if let pending, !done {
            done = true
            cont.resume(returning: pending)
        } else {
            continuation = cont
        }
    }

    func resume(with message: ServerMessage) {
        guard !done else { return }
        if let continuation {
            done = true
            continuation.resume(returning: message)
        } else {
            pending = message
        }
    }
}
```

- [ ] **Step 4: Run the happy-path test to verify it passes**

Run: `swift test --filter PairingControllerTests/testPairMintsTokenPersistsConfigAndToken`
Expected: PASS

- [ ] **Step 5: Write the failing tests for the error surfaces**

Add to `PairingControllerTests`:

```swift
func testInvalidCodeMapsToInvalidCodeError() async throws {
    let conn = MockConnection()
    conn.scriptedReply = .error(code: 401, message: "Invalid or expired pairing code")
    let controller = PairingController(
        store: makeStore(), deviceName: "d", platform: "ios",
        connectionFactory: { conn })
    let url = PairingURL(host: "h.local", port: 9200, useTLS: false, code: "K7QP2M4X")
    do {
        _ = try await controller.pair(url)
        XCTFail("expected throw")
    } catch let e as PairingError {
        XCTAssertEqual(e, .invalidCode)
    }
    XCTAssertTrue(conn.disconnected, "socket must be torn down on failure")
}

func testRateLimitedMapsTo429Error() async throws {
    let conn = MockConnection()
    conn.scriptedReply = .error(code: 429, message: "Too many attempts")
    let controller = PairingController(
        store: makeStore(), deviceName: "d", platform: "ios",
        connectionFactory: { conn })
    let url = PairingURL(host: "h.local", port: 9200, useTLS: false, code: "K7QP2M4X")
    do { _ = try await controller.pair(url); XCTFail("expected throw") }
    catch let e as PairingError { XCTAssertEqual(e, .rateLimited) }
}

func testNoReplyTimesOut() async throws {
    let conn = MockConnection()          // scriptedReply nil → server stays silent
    let controller = PairingController(
        store: makeStore(), deviceName: "d", platform: "ios",
        connectionFactory: { conn }, timeout: .milliseconds(100))
    let url = PairingURL(host: "h.local", port: 9200, useTLS: false, code: "K7QP2M4X")
    do { _ = try await controller.pair(url); XCTFail("expected throw") }
    catch let e as PairingError { XCTAssertEqual(e, .timedOut) }
    XCTAssertTrue(conn.disconnected)
}
```

- [ ] **Step 6: Run to verify they fail, then pass**

Run: `swift test --filter PairingControllerTests`
Expected: the three new tests FAIL first only if the mapping/teardown is wrong. Given Step 3 already implements mapping + `defer { disconnect() }`, they should PASS. If any fail, fix `mapError`/teardown in `PairingController.swift` until green. Do NOT weaken a test to pass.

- [ ] **Step 7: Verify build + full suite filter, then commit**

```bash
swift build
swift test --filter PairingControllerTests
git add Sources/ClaudeRelayClient/PairingController.swift Tests/ClaudeRelayClientTests/PairingControllerTests.swift
git commit -m "feat(pairing): PairingController — pre-auth redeem + persist (shared client)"
```

---

## Task 2: iOS — manual "Pair with a host" sheet + view model

**Files:**
- Create: `ClaudeRelayApp/ViewModels/PairingViewModel.swift`
- Create: `ClaudeRelayApp/Views/PairWithHostSheet.swift`
- Test: `ClaudeRelayApp` has no unit-test target for view models today (verify: `ls ClaudeRelayApp*Tests` — if absent, the view model's *logic* is covered by Task 1's `PairingController` tests; the sheet is verified by build + a manual smoke note). If a test target exists, add `PairingViewModelTests` mirroring the structure below.

**Interfaces:**
- Consumes: `PairingController` (Task 1), `PairingError`, `PairingURL(host:port:useTLS:code:)`, `PairingCode.normalize(_:)`, `ClaudeRelayApp.savedConnections`.
- Produces: `PairingViewModel` (`@MainActor ObservableObject`) with `@Published host/port/tls/code/errorMessage/isPairing` and `func pair() async -> ConnectionConfig?`; `PairWithHostSheet` view with `onPaired: (ConnectionConfig) -> Void`.

- [ ] **Step 1: Write the view model**

`PairingViewModel` validates its fields into a `PairingURL`, invokes `PairingController`, and translates `PairingError` into a user string:

```swift
import Foundation
import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

@MainActor
final class PairingViewModel: ObservableObject {
    @Published var host: String = ""
    @Published var port: String = "9200"
    @Published var useTLS: Bool = false
    @Published var code: String = ""
    @Published var errorMessage: String?
    @Published var isPairing = false

    var isValid: Bool {
        !host.isEmpty && UInt16(port) != nil && PairingCode.normalize(code) != nil
    }

    /// Builds a PairingURL from the fields, redeems it, returns the saved config.
    func pair() async -> ConnectionConfig? {
        errorMessage = nil
        guard let portNumber = UInt16(port), portNumber >= 1 else {
            errorMessage = "Port must be a number between 1 and 65535."; return nil
        }
        guard let normalized = PairingCode.normalize(code) else {
            errorMessage = "That code is not a valid pairing code."; return nil
        }
        let url = PairingURL(host: host, port: portNumber, useTLS: useTLS, code: normalized)
        let controller = PairingController(
            store: ClaudeRelayApp.savedConnections,
            deviceName: DeviceIdentifier.deviceName,
            platform: "ios")
        isPairing = true
        defer { isPairing = false }
        do {
            return try await controller.pair(url)
        } catch let error as PairingError {
            errorMessage = Self.message(for: error, host: host, useTLS: useTLS)
            return nil
        } catch {
            errorMessage = "Pairing failed: \(error.localizedDescription)"
            return nil
        }
    }

    static func message(for error: PairingError, host: String, useTLS: Bool) -> String {
        switch error {
        case .invalidCode:
            return "That code is invalid or has expired. Run `claude-relay setup` again for a fresh code."
        case .rateLimited:
            return "Too many attempts from this device. Wait a minute and try again."
        case .tlsRequired:
            return "\(host) requires a secure connection (wss://). Enable TLS on the server, then pair again."
        case .unreachable:
            return "Could not reach \(host). Check you are on the same network as the Mac."
        case .timedOut:
            return "The server did not respond. Check it is running with `claude-relay status`."
        case .server(let code, let text):
            return "Pairing failed (\(code)): \(text)"
        }
    }
}
```

Note: confirm `DeviceIdentifier.deviceName` exists in `ClaudeRelayClient` (research cited `DeviceIdentifier`). If the property is named differently, use the actual accessor; if none exists, use `UIDevice.current.name`.

- [ ] **Step 2: Write the sheet**

Mirror `AddEditServerView`'s form; Code replaces Token:

```swift
import SwiftUI
import ClaudeRelayClient

struct PairWithHostSheet: View {
    @StateObject private var viewModel = PairingViewModel()
    @Environment(\.dismiss) private var dismiss
    var onPaired: (ConnectionConfig) -> Void

    /// Prefill from a scanned or deep-linked URL (scanner path).
    var prefill: PairingURL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("silverwing.local", text: $viewModel.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", text: $viewModel.port).keyboardType(.numberPad)
                    Toggle("Use TLS (wss://)", isOn: $viewModel.useTLS)
                }
                Section("Pairing code") {
                    TextField("K7QP-2M4X", text: $viewModel.code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Pair with a host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") {
                        Task {
                            if let config = await viewModel.pair() {
                                onPaired(config); dismiss()
                            }
                        }
                    }
                    .disabled(!viewModel.isValid || viewModel.isPairing)
                }
            }
            .onAppear {
                if let prefill {
                    viewModel.host = prefill.host
                    viewModel.port = String(prefill.port)
                    viewModel.useTLS = prefill.useTLS
                    viewModel.code = PairingCode.formatted(prefill.code)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Verify build**

Rebuild the iOS app target in Xcode (or `xcodebuild -scheme ClaudeRelay -destination 'generic/platform=iOS' build` if wired for CLI). Expected: compiles. (SwiftUI views have no unit tests here; correctness of the redeem logic is proven by Task 1.)

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayApp/ViewModels/PairingViewModel.swift ClaudeRelayApp/Views/PairWithHostSheet.swift
git commit -m "feat(pairing): iOS Pair-with-host sheet + view model"
```

---

## Task 3: iOS — ServerListView entry (Scan QR + Enter code) and deep-link route

**Files:**
- Modify: `ClaudeRelayApp/Views/ServerListView.swift`
- Modify: `ClaudeRelayApp/ClaudeRelayApp.swift`
- Reuse: `ClaudeRelayApp/Views/QRScannerView.swift` (`QRScannerView { (String) -> Void }`)

**Interfaces:**
- Consumes: `QRScannerView` (callback `(String) -> Void`), `PairingURL(string:)`, `PairWithHostSheet` (Task 2), the existing `viewModel.startConnect(to:)` in `ServerListView`'s view model (research: `ServerListView.swift:28`).
- Produces: a "Pair" menu on the server list with two actions; a `pendingPairing: PairingURL?` state on the app that presents the scanner-prefilled sheet when a `coderelay://pair` link arrives.

- [ ] **Step 1: Add the `pair` route to `handleDeepLink`**

In `ClaudeRelayApp.swift`, extend the handler (research quoted it at lines 109–117). Add a `pair` branch *before* the `session` guard, and a `@State`:

```swift
@State private var pendingPairing: PairingURL?

private func handleDeepLink(_ url: URL) {
    if url.host == "pair", let pairing = PairingURL(url: url) {
        pendingPairing = pairing
        return
    }
    guard url.scheme == "clauderelay",
          url.host == "session",
          let uuidString = url.pathComponents.dropFirst().first,
          let sessionId = UUID(uuidString: uuidString) else {
        return
    }
    pendingSessionId = sessionId
}
```

Present the sheet from the same root view that owns `pendingSessionId` (find the `.sheet`/`.onChange` cluster near the ServerListView presentation):

```swift
.sheet(item: $pendingPairing) { pairing in
    PairWithHostSheet(onPaired: { config in
        // Hand off to the normal connect path.
        pendingConnectConfig = config     // or call the server list VM's startConnect
    }, prefill: pairing)
}
```

`PairingURL` must be `Identifiable` for `.sheet(item:)`. It is not today — add a tiny conformance in the app (do NOT modify the shipped kit type unless trivial): create `extension PairingURL: Identifiable { public var id: String { urlString } }` in the app target. (If you prefer to keep it out of the kit, declare the extension in `ClaudeRelayApp.swift`.)

- [ ] **Step 2: Add the Pair entry to ServerListView**

Add a toolbar menu (or a row action) offering "Scan QR Code" and "Enter Code Manually". Scanning decodes a String → `PairingURL(string:)` → present `PairWithHostSheet(prefill:)`; manual just presents `PairWithHostSheet(prefill: nil)`:

```swift
@State private var showScanner = false
@State private var showManualPair = false
@State private var scannedPairing: PairingURL?

// In the toolbar:
Menu {
    Button { showScanner = true } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
    Button { showManualPair = true } label: { Label("Enter Code Manually", systemImage: "keyboard") }
} label: {
    Image(systemName: "plus.viewfinder")   // "Pair"
}

// Sheets:
.sheet(isPresented: $showScanner) {
    NavigationStack {
        QRScannerView { value in
            showScanner = false
            if let pairing = PairingURL(string: value) { scannedPairing = pairing }
            // A non-pairing QR is ignored; optionally surface a transient error.
        }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScanner = false } } }
    }
}
.sheet(item: $scannedPairing) { pairing in
    PairWithHostSheet(onPaired: { config in viewModel.startConnect(to: config) }, prefill: pairing)
}
.sheet(isPresented: $showManualPair) {
    PairWithHostSheet(onPaired: { config in viewModel.startConnect(to: config) }, prefill: nil)
}
```

Confirm the server-list view model's connect method name (`startConnect(to:)` per research). If success should immediately open the terminal, call the same method a row tap calls.

- [ ] **Step 3: Verify build + manual smoke**

Rebuild the iOS app in Xcode. Manual smoke (document result in the report, do not claim without running): run `claude-relay setup` on the Mac, scan the QR in the app, confirm the server appears and connects; then `--no-qr`, type host + code, confirm the same.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayApp/Views/ServerListView.swift ClaudeRelayApp/ClaudeRelayApp.swift
git commit -m "feat(pairing): iOS scan + manual pairing entry and coderelay://pair route"
```

---

## Task 4: macOS — manual pairing sheet, list entry, and deep-link route

**Files:**
- Create: `ClaudeRelayMac/Views/PairWithHostSheet.swift`
- Create: `ClaudeRelayMac/ViewModels/PairingViewModel.swift`
- Modify: `ClaudeRelayMac/Views/ServerListWindow.swift`
- Modify: `ClaudeRelayMac/ClaudeRelayMacApp.swift`

**Interfaces:**
- Consumes: `PairingController` (Task 1), `PairingError`, `PairingURL`, `PairingCode`, `ClaudeRelayMacApp.savedConnections`, the macOS connect entry `MainWindow.connect(to:)` / `ServerListWindow.onConnect` (research: `ServerListWindow.swift:11`, `MainWindow.swift:80`).
- Produces: a macOS `PairingViewModel` (uses `ClaudeRelayMacApp.savedConnections`), a `PairWithHostSheet` (no scanner), a "Pair" button beside "Add Server", and a `pair` deep-link branch.

- [ ] **Step 1: Write the macOS view model**

Identical logic to Task 2's `PairingViewModel` but persisting via `ClaudeRelayMacApp.savedConnections` and `platform: "macos"`. Copy the Task 2 code, changing only the store reference and platform string (the plan repeats it rather than sharing because the two apps are separate targets and neither imports the other's view models — matches how `AddEditServerViewModel` is duplicated per platform, per research §6):

```swift
import Foundation
import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

@MainActor
final class PairingViewModel: ObservableObject {
    @Published var host: String = ""
    @Published var port: String = "9200"
    @Published var useTLS: Bool = false
    @Published var code: String = ""
    @Published var errorMessage: String?
    @Published var isPairing = false

    var isValid: Bool {
        !host.isEmpty && UInt16(port) != nil && PairingCode.normalize(code) != nil
    }

    func pair() async -> ConnectionConfig? {
        errorMessage = nil
        guard let portNumber = UInt16(port), portNumber >= 1 else {
            errorMessage = "Port must be a number between 1 and 65535."; return nil
        }
        guard let normalized = PairingCode.normalize(code) else {
            errorMessage = "That code is not a valid pairing code."; return nil
        }
        let url = PairingURL(host: host, port: portNumber, useTLS: useTLS, code: normalized)
        let controller = PairingController(
            store: ClaudeRelayMacApp.savedConnections,
            deviceName: Host.current().localizedName ?? "Mac",
            platform: "macos")
        isPairing = true
        defer { isPairing = false }
        do { return try await controller.pair(url) }
        catch let error as PairingError {
            errorMessage = Self.message(for: error, host: host, useTLS: useTLS); return nil
        } catch {
            errorMessage = "Pairing failed: \(error.localizedDescription)"; return nil
        }
    }

    static func message(for error: PairingError, host: String, useTLS: Bool) -> String {
        switch error {
        case .invalidCode: return "That code is invalid or has expired. Run `claude-relay setup` again."
        case .rateLimited: return "Too many attempts. Wait a minute and try again."
        case .tlsRequired: return "\(host) requires wss://. Enable TLS on the server, then pair again."
        case .unreachable: return "Could not reach \(host). Check the network and that the server is running."
        case .timedOut:    return "The server did not respond. Check `claude-relay status`."
        case .server(let code, let text): return "Pairing failed (\(code)): \(text)"
        }
    }
}
```

- [ ] **Step 2: Write the macOS sheet**

Mirror `AddEditServerView.swift` (macOS: `Form` + fixed frame + Cancel/confirm row):

```swift
import SwiftUI
import ClaudeRelayClient

struct PairWithHostSheet: View {
    @StateObject private var viewModel = PairingViewModel()
    @Environment(\.dismiss) private var dismiss
    var onPaired: (ConnectionConfig) -> Void
    var prefill: PairingURL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair with a host").font(.headline)
            Form {
                TextField("Host", text: $viewModel.host)
                TextField("Port", text: $viewModel.port)
                Toggle("Use TLS (wss://)", isOn: $viewModel.useTLS)
                TextField("Code (K7QP-2M4X)", text: $viewModel.code)
            }
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Pair") {
                    Task { if let c = await viewModel.pair() { onPaired(c); dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.isValid || viewModel.isPairing)
            }
        }
        .padding(20)
        .frame(width: 480, height: 320)
        .onAppear {
            if let prefill {
                viewModel.host = prefill.host
                viewModel.port = String(prefill.port)
                viewModel.useTLS = prefill.useTLS
                viewModel.code = PairingCode.formatted(prefill.code)
            }
        }
    }
}
```

- [ ] **Step 3: Add the Pair button + deep-link route**

In `ServerListWindow.swift` add a "Pair" button beside "Add Server" (research: bottom-bar `HStack` at `:49-63`) that sets a `@State pairTarget = true`, presented via `.sheet(isPresented:)` showing `PairWithHostSheet(onPaired: { onConnect?($0) }, prefill: nil)`.

In `ClaudeRelayMacApp.swift`, add the `pair` branch to `handleDeepLink` (research quoted `:46-58`). Because a pair link arrives before any coordinator exists, route it to a sheet, not `ActiveCoordinatorRegistry`:

```swift
@State private var pendingPairing: PairingURL?

private func handleDeepLink(_ url: URL) {
    if url.host == "pair", let pairing = PairingURL(url: url) {
        pendingPairing = pairing
        return
    }
    guard url.scheme == "clauderelay", url.host == "session",
          let uuidString = url.pathComponents.dropFirst().first,
          let uuid = UUID(uuidString: uuidString) else { return }
    Task { @MainActor in
        if let coordinator = ActiveCoordinatorRegistry.shared.coordinator {
            await coordinator.attachRemoteSession(id: uuid)
        }
    }
}
```

Present `PairWithHostSheet(prefill: pendingPairing)` from the window that owns the scene, handing `onPaired` to the same connect entry a list tap uses.

- [ ] **Step 4: Verify build + manual smoke**

Build the macOS app in Xcode (needs `macos-26` + Xcode 26 per repo notes). Manual smoke: `claude-relay setup --no-qr` on the Mac, open the macOS app → Pair → type host + code → confirm the server is added and connects.

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayMac/Views/PairWithHostSheet.swift ClaudeRelayMac/ViewModels/PairingViewModel.swift ClaudeRelayMac/Views/ServerListWindow.swift ClaudeRelayMac/ClaudeRelayMacApp.swift
git commit -m "feat(pairing): macOS pair-with-host sheet, list entry, and deep-link route"
```

---

## Task 5: Android — port pairing wire messages, `PairingCode`, `PairingURL` to Kotlin

**Files:**
- Modify: `ClaudeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/ClientMessage.kt`
- Modify: `ClaudeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/ServerMessage.kt`
- Modify: `ClaudeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/MessageEnvelope.kt`
- Create: `ClaudeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/PairingCode.kt`
- Create: `ClaudeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/PairingURL.kt`
- Test: `ClaudeRelayAndroid/core-protocol/src/test/kotlin/relay/protocol/PairingCodeTest.kt`
- Test: `ClaudeRelayAndroid/core-protocol/src/test/kotlin/relay/protocol/PairingUrlTest.kt`
- Test: `ClaudeRelayAndroid/core-protocol/src/test/kotlin/relay/protocol/PairingMessageEnvelopeTest.kt`

**Interfaces:**
- Consumes: existing `ClientMessage` sealed interface (`typeString`, `ALL_TYPE_STRINGS`), `ServerMessage`, `MessageEnvelope.encodeClient`/`decodeServer` (research §3).
- Produces: `ClientMessage.PairRequest(code, deviceName, platform)` (typeString `"pair_request"`), `ServerMessage.PairSuccess(token, tokenId, label)` (typeString `"pair_success"`); `PairingCode` object with `normalize(String): String?` and `formatted(String): String`; `PairingURL` data class with `parse(String): PairingURL?`, fields `host: String, port: Int, useTLS: Boolean, code: String`, and `wsUrl: String`.

- [ ] **Step 1: Write failing PairingCode tests (port the Swift cases)**

```kotlin
package relay.protocol

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull

class PairingCodeTest {
    @Test fun `normalize strips hyphen and uppercases`() {
        assertEquals("K7QP2M4X", PairingCode.normalize("k7qp-2m4x"))
    }
    @Test fun `normalize folds confusables I L O U`() {
        // I,L -> 1 ; O -> 0 ; U -> V
        assertEquals("10ABCDEV", PairingCode.normalize("ILoAbcdeu".let { "IL0ABCDEU" }))
    }
    @Test fun `normalize rejects wrong length`() {
        assertNull(PairingCode.normalize("K7QP"))
        assertNull(PairingCode.normalize("K7QP2M4X9"))
    }
    @Test fun `normalize rejects out-of-alphabet chars`() {
        assertNull(PairingCode.normalize("K7QP2M4!"))
    }
    @Test fun `normalize rejects overlong input`() {
        assertNull(PairingCode.normalize("A".repeat(65)))
    }
    @Test fun `formatted groups in fours with a hyphen`() {
        assertEquals("K7QP-2M4X", PairingCode.formatted("K7QP2M4X"))
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `./gradlew :core-protocol:testDebugUnitTest --tests "relay.protocol.PairingCodeTest"`
Expected: FAIL — `PairingCode` unresolved.

- [ ] **Step 3: Port PairingCode**

```kotlin
package relay.protocol

/** Kotlin mirror of Swift ClaudeRelayKit PairingCode. Crockford Base32. */
object PairingCode {
    const val LENGTH = 8
    private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private val ALPHABET_SET = ALPHABET.toHashSet()
    private val CONFUSABLES = mapOf('I' to '1', 'L' to '1', 'O' to '0', 'U' to 'V')
    private const val MAX_INPUT_LENGTH = 64

    /** Canonicalizes user input, or null if it cannot be a valid code. */
    fun normalize(input: String): String? {
        if (input.toByteArray(Charsets.UTF_8).size > MAX_INPUT_LENGTH) return null
        val out = StringBuilder(LENGTH)
        for (raw in input.uppercase()) {
            if (raw == '-' || raw.isWhitespace()) continue
            val ch = CONFUSABLES[raw] ?: raw
            if (ch !in ALPHABET_SET) return null
            out.append(ch)
        }
        return if (out.length == LENGTH) out.toString() else null
    }

    /** Renders a code grouped in fours: K7QP-2M4X. Presentation only. */
    fun formatted(code: String): String {
        if (code.length != LENGTH) return code
        val mid = LENGTH / 2
        return "${code.substring(0, mid)}-${code.substring(mid)}"
    }
}
```

- [ ] **Step 4: Run PairingCode tests to pass**

Run: `./gradlew :core-protocol:testDebugUnitTest --tests "relay.protocol.PairingCodeTest"`
Expected: PASS. (Fix the Step-1 `normalize folds confusables` test literal if needed: the intended input is the literal string `"IL0ABCDEU"` → expect `"110ABCDEV"`. Correct the assertion to `assertEquals("110ABCDEV", PairingCode.normalize("IL0ABCDEU"))` — `I`→1, `L`→1, `0`→0, `A B C D E`, `U`→V.)

- [ ] **Step 5: Write failing PairingURL tests (port `PairingURLTests.swift` case list)**

```kotlin
package relay.protocol

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue

class PairingUrlTest {
    @Test fun `parses a valid pair url`() {
        val u = PairingURL.parse("coderelay://pair?host=silverwing.local&port=9200&tls=0&code=K7QP2M4X")!!
        assertEquals("silverwing.local", u.host)
        assertEquals(9200, u.port)
        assertFalse(u.useTLS)
        assertEquals("K7QP2M4X", u.code)
        assertEquals("ws://silverwing.local:9200", u.wsUrl)
    }
    @Test fun `tls=1 yields wss`() {
        val u = PairingURL.parse("coderelay://pair?host=h.example.com&port=443&tls=1&code=K7QP2M4X")!!
        assertTrue(u.useTLS)
        assertEquals("wss://h.example.com:443", u.wsUrl)
    }
    @Test fun `normalizes a hyphenated lowercase code`() {
        assertEquals("K7QP2M4X", PairingURL.parse("coderelay://pair?host=h.local&port=9200&tls=0&code=k7qp-2m4x")!!.code)
    }
    @Test fun `wrong scheme is null`() {
        assertNull(PairingURL.parse("https://pair?host=h&port=9200&tls=0&code=K7QP2M4X"))
    }
    @Test fun `wrong host is null`() {
        assertNull(PairingURL.parse("coderelay://session/123?code=K7QP2M4X"))
    }
    @Test fun `missing code is null`() {
        assertNull(PairingURL.parse("coderelay://pair?host=h.local&port=9200&tls=0"))
    }
    @Test fun `bad port is null`() {
        assertNull(PairingURL.parse("coderelay://pair?host=h.local&port=0&tls=0&code=K7QP2M4X"))
        assertNull(PairingURL.parse("coderelay://pair?host=h.local&port=99999&tls=0&code=K7QP2M4X"))
    }
    @Test fun `bad code charset is null`() {
        assertNull(PairingURL.parse("coderelay://pair?host=h.local&port=9200&tls=0&code=K7QP2M4!"))
    }
    @Test fun `empty host is null`() {
        assertNull(PairingURL.parse("coderelay://pair?host=&port=9200&tls=0&code=K7QP2M4X"))
    }
}
```

- [ ] **Step 6: Run to verify fail, then port PairingURL**

Run: `./gradlew :core-protocol:testDebugUnitTest --tests "relay.protocol.PairingUrlTest"` → FAIL, then implement:

```kotlin
package relay.protocol

import java.net.URI

/** Kotlin mirror of Swift PairingURL. Pure — no android.net.Uri. */
data class PairingURL(
    val host: String,
    val port: Int,
    val useTLS: Boolean,
    val code: String,
) {
    val wsUrl: String get() = "${if (useTLS) "wss" else "ws"}://$host:$port"

    companion object {
        const val SCHEME = "clauderelay"
        const val HOST = "pair"

        fun parse(input: String): PairingURL? {
            val uri = try { URI(input) } catch (_: Exception) { return null }
            if (uri.scheme?.lowercase() != SCHEME) return null
            // URI puts "pair" in authority/host for coderelay://pair?...
            val authority = (uri.host ?: uri.authority)?.lowercase()
            if (authority != HOST) return null
            val query = uri.rawQuery ?: return null
            val params = query.split("&").mapNotNull {
                val i = it.indexOf('='); if (i < 0) null else
                    java.net.URLDecoder.decode(it.substring(0, i), "UTF-8") to
                    java.net.URLDecoder.decode(it.substring(i + 1), "UTF-8")
            }.toMap()

            val host = params["host"]?.trim()
            if (host.isNullOrEmpty()) return null
            val port = params["port"]?.toIntOrNull() ?: return null
            if (port < 1 || port > 65535) return null
            val code = params["code"]?.let { PairingCode.normalize(it) } ?: return null
            val useTLS = params["tls"] == "1"
            // Reject RFC-3986-illegal host chars, matching Swift isValidHost.
            if (host.any { it == ' ' || it == '/' || it == '?' || it == '#' || it == '@' }) return null
            return PairingURL(host, port, useTLS, code)
        }
    }
}
```

Run the tests again → PASS.

- [ ] **Step 7: Write failing wire-message envelope tests**

```kotlin
package relay.protocol

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue

class PairingMessageEnvelopeTest {
    @Test fun `pair_request encodes with code deviceName platform`() {
        val json = MessageEnvelope.encodeClient(
            ClientMessage.PairRequest(code = "K7QP2M4X", deviceName = "Pixel", platform = "android"))
        assertTrue(json.contains("\"type\":\"pair_request\""))
        assertTrue(json.contains("\"code\":\"K7QP2M4X\""))
        assertTrue(json.contains("\"deviceName\":\"Pixel\""))
        assertTrue(json.contains("\"platform\":\"android\""))
    }
    @Test fun `pair_success decodes token tokenId label`() {
        val msg = MessageEnvelope.decodeServer(
            "{\"type\":\"pair_success\",\"payload\":{\"token\":\"t\",\"tokenId\":\"id\",\"label\":\"Pixel (paired)\"}}")
        assertTrue(msg is ServerMessage.PairSuccess)
        val ps = msg as ServerMessage.PairSuccess
        assertEquals("t", ps.token); assertEquals("id", ps.tokenId); assertEquals("Pixel (paired)", ps.label)
    }
    @Test fun `type strings are registered`() {
        assertTrue(ClientMessage.ALL_TYPE_STRINGS.contains("pair_request"))
        assertTrue(ServerMessage.ALL_TYPE_STRINGS.contains("pair_success"))
    }
}
```

- [ ] **Step 8: Run to fail, then add the messages**

Run: `./gradlew :core-protocol:testDebugUnitTest --tests "relay.protocol.PairingMessageEnvelopeTest"` → FAIL.

Add to `ClientMessage.kt` (a `data class` case + type string + `ALL_TYPE_STRINGS` entry):
```kotlin
data class PairRequest(val code: String, val deviceName: String, val platform: String) : ClientMessage {
    override val typeString get() = "pair_request"
}
// in ALL_TYPE_STRINGS: add "pair_request"
```
Add to `ServerMessage.kt`:
```kotlin
data class PairSuccess(val token: String, val tokenId: String, val label: String) : ServerMessage {
    override val typeString get() = "pair_success"
}
// in ALL_TYPE_STRINGS: add "pair_success"
```
Add to `MessageEnvelope.encodeClient`'s `when` a `PairRequest` arm building `{"code":..,"deviceName":..,"platform":..}`, and to `decodeServer`'s `when(type)` a `"pair_success"` arm reading `token`/`tokenId`/`label`. Follow the exact JSON-building idiom already used by neighboring cases in the file.

- [ ] **Step 9: Run all core-protocol pairing tests + the existing type-string test**

Run: `./gradlew :core-protocol:testDebugUnitTest`
Expected: PASS, including the pre-existing `MessageTypeTest` (which asserts the `ALL_TYPE_STRINGS` sets — it now includes the two new strings).

- [ ] **Step 10: Commit**

```bash
git add ClaudeRelayAndroid/core-protocol/
git commit -m "feat(pairing): Kotlin port of pairing wire messages, PairingCode, PairingURL"
```

---

## Task 6: Android — `PairingController` (redeem + persist) in core-session

**Files:**
- Create: `ClaudeRelayAndroid/core-session/src/main/kotlin/relay/session/PairingController.kt`
- Test: `ClaudeRelayAndroid/core-session/src/test/kotlin/relay/session/PairingControllerTest.kt`

**Interfaces:**
- Consumes: `PairingURL` (Task 5), `ClientMessage.PairRequest`, `ServerMessage.PairSuccess`/`ServerMessage.Error`, `ConnectionConfig`, `RelayConnection.connectRaw(wsUrl)` / `connect(config, token)` + `send` + `addServerMessageSubscriber`/`removeSubscriber` (research §4 — `ConnectionSurface`), `SavedConnectionStore.add`, `TokenStore.saveToken` (research §5).
- Produces: `PairingController` with `suspend fun pair(url: PairingURL): Result<ConnectionConfig>` (or throws a sealed `PairingError`); `sealed class PairingError` mirroring the Swift cases (`InvalidCode`, `RateLimited`, `TlsRequired`, `Unreachable`, `TimedOut`, `Server(code, message)`).

- [ ] **Step 1: Write the failing happy-path + error tests**

Use a fake `ConnectionSurface`. Follow the JUnit 5 idiom. Fields to assert mirror Task 1. Structure:

```kotlin
package relay.session

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.*
import relay.protocol.*

class PairingControllerTest {
    // Fake ConnectionSurface delivering a scripted reply on send().
    // Fake SavedConnectionStore + TokenStore capturing writes.
    // (Construct against the real interfaces from core-net/core-storage.)

    @Test fun `pair mints token and persists config plus token`() = runTest {
        // scripted reply: ServerMessage.PairSuccess("tok","id","Pixel (paired)")
        // assert: one PairRequest sent with code/deviceName/platform
        // assert: store received a ConnectionConfig(host,port,useTLS from url; name=label)
        // assert: tokenStore.saveToken called with "tok" for config.id
    }

    @Test fun `error 401 maps to InvalidCode and disconnects`() = runTest { /* ... */ }
    @Test fun `error 429 maps to RateLimited`() = runTest { /* ... */ }
    @Test fun `silent server times out`() = runTest { /* ... */ }
}
```

Fill each test body concretely against the actual `ConnectionSurface`/store interfaces discovered when implementing (do not leave the bodies as comments in the committed test — this skeleton shows the four required cases; the implementer writes the real assertions, matching Task 1's exact shape).

- [ ] **Step 2: Run to verify fail**

Run: `./gradlew :core-session:testDebugUnitTest --tests "relay.session.PairingControllerTest"`
Expected: FAIL — `PairingController` unresolved.

- [ ] **Step 3: Implement PairingController**

Mirror Task 1's Swift logic: dial `url.wsUrl` pre-auth (use `connectRaw` after `CleartextPolicy.requireAllowed`, or `connect(config, token = "")`), subscribe, send `PairRequest`, await `PairSuccess`/`Error` with a 10 s `withTimeoutOrNull`, map errors, persist via `store.add` + `tokenStore.saveToken`, and always `disconnect()` in a `finally`. Use `kotlinx.coroutines` `CompletableDeferred<ServerMessage>` for the subscriber→await bridge:

```kotlin
package relay.session

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import relay.net.ConnectionSurface
import relay.protocol.*
import relay.storage.SavedConnectionStore
import relay.storage.TokenStore

sealed class PairingError : Exception() {
    object InvalidCode : PairingError()
    object RateLimited : PairingError()
    object TlsRequired : PairingError()
    object Unreachable : PairingError()
    object TimedOut : PairingError()
    data class Server(val code: Int, val text: String) : PairingError()
}

class PairingController(
    private val store: SavedConnectionStore,
    private val tokenStore: TokenStore,
    private val deviceName: String,
    private val platform: String,
    private val connectionFactory: () -> ConnectionSurface,
    private val timeoutMs: Long = 10_000L,
) {
    suspend fun pair(url: PairingURL): ConnectionConfig {
        val connection = connectionFactory()
        val dialConfig = ConnectionConfig(
            name = url.host, host = url.host,
            port = url.port.toUShort(), useTLS = url.useTLS)
        try {
            connection.connect(dialConfig, token = "")
        } catch (_: Exception) {
            throw PairingError.Unreachable
        }
        try {
            val reply = redeem(url.code, connection)
            val success = reply as? ServerMessage.PairSuccess ?: throw mapError(reply)
            val config = ConnectionConfig(
                name = success.label.ifEmpty { url.host },
                host = url.host, port = url.port.toUShort(), useTLS = url.useTLS)
            store.add(config)
            tokenStore.saveToken(success.token, config.id)
            return config
        } finally {
            connection.disconnect()
        }
    }

    private suspend fun redeem(code: String, connection: ConnectionSurface): ServerMessage {
        val deferred = CompletableDeferred<ServerMessage>()
        val subId = connection.addServerMessageSubscriber { msg ->
            if (msg.typeString == "pair_success" || msg.typeString == "error") {
                deferred.complete(msg)
            }
        }
        try {
            connection.send(ClientMessage.PairRequest(code, deviceName, platform))
            return withTimeoutOrNull(timeoutMs) { deferred.await() } ?: throw PairingError.TimedOut
        } catch (e: PairingError) {
            throw e
        } catch (_: Exception) {
            throw PairingError.Unreachable
        } finally {
            connection.removeSubscriber(subId)
        }
    }

    private fun mapError(message: ServerMessage): PairingError {
        val err = message as? ServerMessage.Error ?: return PairingError.Server(-1, "Unexpected reply")
        return when (err.code) {
            401 -> PairingError.InvalidCode
            429 -> PairingError.RateLimited
            else -> PairingError.Server(err.code, err.message)
        }
    }
}
```

Confirm the actual `ConnectionSurface` method names/signatures and `ServerMessage.Error` field names during implementation (research §3/§4 named `error` with `code`/`message`) and adjust to match exactly.

- [ ] **Step 4: Run tests to pass**

Run: `./gradlew :core-session:testDebugUnitTest --tests "relay.session.PairingControllerTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayAndroid/core-session/
git commit -m "feat(pairing): Android PairingController — redeem + persist"
```

---

## Task 7: Android — `pair` deep-link route + `parsePairingUrl`

**Files:**
- Modify: `ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/DeepLinks.kt`
- Modify: `ClaudeRelayAndroid/app/src/main/kotlin/relay/app/MainActivity.kt`
- Modify: nav graph (`RelayNavGraph.kt`) to consume a pending pairing on the Servers route
- Test: `ClaudeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/DeepLinksTest.kt` (add `pair` cases)

**Interfaces:**
- Consumes: `PairingURL.parse` (Task 5).
- Produces: `DeepLinks.parsePairingUrl(uri: String): PairingURL?`; a `_pendingPairing: StateFlow<PairingURL?>` on `MainActivity` mirroring `_pendingSessionId`; nav consumption on the Servers route.

- [ ] **Step 1: Add failing `pair` tests to DeepLinksTest**

```kotlin
@Test fun `parsePairingUrl parses a valid pair link`() {
    val u = DeepLinks.parsePairingUrl("coderelay://pair?host=h.local&port=9200&tls=0&code=K7QP2M4X")
    assertEquals("h.local", u?.host)
}
@Test fun `parsePairingUrl rejects a session link`() {
    assertNull(DeepLinks.parsePairingUrl("coderelay://session/${java.util.UUID.randomUUID()}"))
}
```

- [ ] **Step 2: Run to fail, then implement**

Run: `./gradlew :feature-workspace:testDebugUnitTest --tests "relay.feature.workspace.DeepLinksTest"` → FAIL.

Add to `DeepLinks.kt`:
```kotlin
fun parsePairingUrl(uri: String): relay.protocol.PairingURL? =
    relay.protocol.PairingURL.parse(uri)
```
(Thin delegate so the feature module has one deep-link entry point; parsing lives in `core-protocol`.)

- [ ] **Step 3: Run to pass**

Run: `./gradlew :feature-workspace:testDebugUnitTest --tests "relay.feature.workspace.DeepLinksTest"` → PASS.

- [ ] **Step 4: Wire MainActivity + nav**

In `MainActivity.kt`, add `_pendingPairing` StateFlow and a branch in `handleDeepLink` (research §2 quoted `:185-194`):
```kotlin
private val _pendingPairing = MutableStateFlow<PairingURL?>(null)
val pendingPairing: StateFlow<PairingURL?> = _pendingPairing.asStateFlow()

private fun handleDeepLink(intent: Intent?) {
    val data = intent?.data?.toString() ?: return
    DeepLinks.parsePairingUrl(data)?.let { _pendingPairing.value = it; return }
    DeepLinks.parseSessionId(data)?.let { _pendingSessionId.value = it }
}
```
In the nav graph, on the **Servers** route, collect `pendingPairing` and, when non-null, present the pairing sheet prefilled from it, then clear it (mirror `clearPendingSession()`).

- [ ] **Step 5: Verify + commit**

Run: `./gradlew :feature-workspace:testDebugUnitTest :app:compileDebugKotlin`
```bash
git add ClaudeRelayAndroid/feature-workspace/ ClaudeRelayAndroid/app/
git commit -m "feat(pairing): Android coderelay://pair deep-link route"
```

---

## Task 8: Android — pairing UI (scan + manual sheet) in feature-servers

**Files:**
- Create: `ClaudeRelayAndroid/feature-servers/src/main/kotlin/relay/feature/servers/PairWithHostSheet.kt`
- Create: `ClaudeRelayAndroid/feature-servers/src/main/kotlin/relay/feature/servers/PairingViewModel.kt`
- Modify: `ClaudeRelayAndroid/feature-servers/src/main/kotlin/relay/feature/servers/ServersScreen.kt`
- Reuse: `feature-workspace` `QrScannerScreen` (generalize its decode, or add a pairing variant)
- Test: `ClaudeRelayAndroid/feature-servers/src/test/kotlin/relay/feature/servers/PairingViewModelTest.kt`

**Interfaces:**
- Consumes: `PairingController` (Task 6), `PairingURL`, `PairingCode`, `SavedConnectionStore`, `TokenStore`, `QrScannerScreen` (research §1).
- Produces: `PairingViewModel` (validates fields, invokes controller, exposes `errorMessage`/`isPairing`); `PairWithHostSheet` composable with Host/Port/TLS/Code fields + `onPaired`; a "Pair" entry on `ServersScreen`.

- [ ] **Step 1: Write the failing view-model test**

Cover field validation + error mapping (the redeem itself is Task 6). JUnit 5, inject a fake `PairingController` seam or a fake controller factory:

```kotlin
package relay.feature.servers

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.*

class PairingViewModelTest {
    @Test fun `invalid port yields an error and no pairing`() = runTest {
        // set host="h.local", port="abc", code="K7QP2M4X"; call pair();
        // assert errorMessage != null and controller was never invoked
    }
    @Test fun `invalid code yields an error`() = runTest { /* code="123" */ }
    @Test fun `invalidCode error maps to a fresh-code message`() = runTest {
        // fake controller throws PairingError.InvalidCode; assert message mentions "expired"
    }
}
```

- [ ] **Step 2: Run to fail, then implement view model**

Run: `./gradlew :feature-servers:testDebugUnitTest --tests "relay.feature.servers.PairingViewModelTest"` → FAIL. Implement `PairingViewModel` (Compose `ViewModel`) mirroring Task 2's logic: validate `PairingCode.normalize` + port, build `PairingURL`, call `PairingController.pair`, translate `PairingError` to a string. Device name from `android.os.Build.MODEL`, platform `"android"`.

- [ ] **Step 3: Run to pass**

Run: `./gradlew :feature-servers:testDebugUnitTest --tests "relay.feature.servers.PairingViewModelTest"` → PASS.

- [ ] **Step 4: Build the sheet + scan entry**

`PairWithHostSheet` = a `ModalBottomSheet` with `OutlinedTextField`s for Host, Port, a TLS `Switch`, and a Code field, plus Cancel/Pair buttons — mirror `AddEditServerSheet.kt` (research §5), Code replacing Token. Add a "Pair" action on `ServersScreen` (near the Add FAB) offering "Scan QR Code" (launch `QrScannerScreen`, decode via `PairingURL.parse`, prefill the sheet) and "Enter Code Manually" (open the sheet empty). On `onPaired`, reload servers (the controller already persisted) and optionally auto-connect via the existing `connectAndOpen(config, token)` (research §6).

Generalize `QrScannerScreen`: add an `onQrDecoded: (String) -> Unit` variant (or a new `onPairScanned: (PairingURL) -> Unit`) so it isn't hard-wired to session-UUID parsing. Keep the existing `onSessionScanned` path working.

- [ ] **Step 5: Verify build + manual smoke**

Run: `./gradlew :feature-servers:testDebugUnitTest :app:assembleDebug`
Manual smoke (document in report, don't assume): install the debug APK on a device, `claude-relay setup` on the Mac, scan → server added + connects; `--no-qr` → type host + code → same.

- [ ] **Step 6: Commit**

```bash
git add ClaudeRelayAndroid/feature-servers/ ClaudeRelayAndroid/feature-workspace/
git commit -m "feat(pairing): Android scan + manual pairing UI"
```

---

## Task 9: Docs — README pairing-from-a-client flow

**Files:**
- Modify: `README.md`
- Modify: `ClaudeRelayApp/README.md`, `ClaudeRelayMac/README.md`, `ClaudeRelayAndroid/README.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Update the top-level README**

The 1a branch's README already leads Quick Start with `claude-relay setup` and notes QR scanning "lands with the next app release" plus a `token create` fallback. Update that note: QR scanning and manual code entry now ship in the apps. Add a short "Pairing a device" subsection: run `claude-relay setup`, then on the phone tap Pair → Scan QR (or Enter Code and type the host + code shown above the QR). Keep the `token create` manual path documented as the still-supported alternative.

- [ ] **Step 2: Update the per-app READMEs**

Add a one-paragraph "Pairing" note to each app README describing the entry point (iOS/Android: scan or manual; macOS: manual only) and that a paired device appears in `claude-relay token list` and is revocable per-device.

- [ ] **Step 3: Commit**

```bash
git add README.md ClaudeRelayApp/README.md ClaudeRelayMac/README.md ClaudeRelayAndroid/README.md
git commit -m "docs(pairing): document scanning and manual code entry in the apps"
```

---

## Self-Review

**1. Spec coverage** (against spec §Clients, lines 345–390, and Testing/Acceptance):

| Spec requirement | Task |
| --- | --- |
| `PairingURL` (shared, kit) — parse/validate | Shipped in 1a; Kotlin port = Task 5 |
| `PairingController` (ClaudeRelayClient): open connection, pair_request, await pair_success, persist (SavedConnectionStore + AuthManager), hand off | Task 1 (Swift), Task 6 (Kotlin) |
| Mirrors `AddEditServerViewModel.save()` | Task 1 Step 3 (build config → add → saveToken), stated in Global Constraints |
| Error surfaces: invalid/expired, rate-limited, unreachable, TLS-required | Task 1 `PairingError` + Tasks 2/4/8 message mapping |
| iOS: camera scanner on ServerListView + Enter-code sheet | Tasks 2, 3 |
| Android: CameraX/MLKit scanner + Enter-code sheet | Tasks 5–8 |
| macOS: Enter-code sheet only (no camera) | Task 4 |
| Deep-link `pair` route reusing handleDeepLink | Task 3 (iOS), Task 4 (macOS), Task 7 (Android) |
| Android barcode dependency check | Resolved: CameraX+MLKit+zxing already declared (research §8); Task 8 reuses `QrScannerScreen` |
| Testing: PairingURL cases; RelayMessageHandler already 1a; controller redeem | Task 1, Task 5 (URL/code/envelope), Task 6 |

Gap check: the spec's "camera scanner on ServerListView" for iOS is satisfied by Task 3 (net-new entry, since the existing scanner was only wired into session-attach). No spec client requirement is left without a task.

**2. Placeholder scan:** Task 6 Step 1 and Task 8 Step 1 present test *skeletons* with the four required cases named but bodies to be filled against interfaces confirmed at implementation time — this is deliberate for the Kotlin fakes (the exact `ConnectionSurface`/store constructor shapes must be read from the module at implementation), and each step names the exact assertions required (mirror Task 1). All Swift code blocks are complete. No "TBD"/"handle edge cases"/"similar to" placeholders remain.

**3. Type consistency:** `PairingController.pair(_:) -> ConnectionConfig` (Swift) / `pair(url): ConnectionConfig` (Kotlin); `PairingError` cases identical across platforms (`invalidCode/rateLimited/tlsRequired/unreachable/timedOut/server` ↔ `InvalidCode/RateLimited/TlsRequired/Unreachable/TimedOut/Server`); `ConnectionConfig(name:host:port:useTLS:)` with `port: UInt16`/`UShort` matches `PairingURL.port` (`UInt16`/`Int→toUShort()`); wire fields `code/deviceName/platform` and `token/tokenId/label` match the 1a Swift source exactly (verified against `ClientMessage.swift:34`, `ServerMessage.swift:32`). `pair_success.tokenId` is consistently not persisted (Global Constraints + Task 1 destructures it as `_`).

Note carried into execution: `PairingController` uses a `PairingConnection` protocol (Task 1) so `RelayConnection` need not gain a token-less connect — confirmed `connect(config:token:)` only stores the token, so dialing with `token: ""` is safe and no kit change is required.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-01-host-pairing-1b-clients.md`.
