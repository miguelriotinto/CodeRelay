# Server Prompt Optimizer — Plan 2: iOS + macOS Clients Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove on-device voice transcription from the iOS and macOS apps and replace the mic button with a single "magic wand" button that asks the relay to rewrite the draft at the agent's input line, with an exact Undo.

**Architecture:** `SessionController` (CodeRelayClient) learns the two new RPCs from Plan 1 (`optimize_prompt` / `replace_prompt`, 20 s waiter) and records the server's `protocolVersion` + `capabilities` from `auth_success`. `SharedSessionCoordinator` owns the wand state machine (availability → idle/optimizing → 10 s Undo window → toast text) so both apps render the same shared `WandButton`. Each app then deletes its speech UI/settings, runs a one-time migration that scrubs the old keys, the Bedrock keychain secret, and the downloaded model directory, and finally the `CodeRelaySpeech` package target, its WhisperKit/LLM.swift dependencies, and the CI pin-restore hack are removed.

**Tech Stack:** Swift tools 5.9, SwiftPM, XCTest, XcodeGen (`project.yml` → tracked `CodeRelay.xcodeproj`), SwiftUI (iOS 17 / macOS 14), `@AppStorage`, Keychain via `AuthManager`.

**Spec:** `docs/superpowers/specs/2026-09-13-server-prompt-optimizer-design.md` — this plan implements §6 (client side of the wire protocol), §7.1, §7.2, the Swift/iOS/macOS/shared/docs rows of §8, §9 (client copy), §10 (privacy footer), and the client rows of §11. Plan 1 (server + protocol) is already merged as PR #57; Plans 3 (Android) and 4 (Linux) follow.

## Global Constraints

- **Wire (from Plan 1, already in `CodeRelayKit`):** `ClientMessage.optimizePrompt(sessionId: UUID, shareScreen: Bool)` → type string `optimize_prompt`; `ClientMessage.replacePrompt(sessionId: UUID, text: String)` → `replace_prompt`; `ServerMessage.optimizePromptResult(status: String, original: String?, prompt: String?, message: String?)` → `optimize_prompt_result` with `status ∈ {ok, no_draft, passthrough, unconfigured, failed}`; `ServerMessage.replacePromptResult(status: String, message: String?)` → `replace_prompt_result` with `status ∈ {ok, failed}`; `ServerMessage.authSuccess(protocolVersion: Int?, tokenId: String?, capabilities: [String]?)`. Constants: `CodeRelayKit.protocolVersion == 2`, `CodeRelayKit.promptOptimizerCapability == "prompt_optimizer"`. Do not touch `Sources/CodeRelayKit`.
- **Gating (spec §7.1):** the wand is *available* only when the server's `auth_success.capabilities` contains `prompt_optimizer` **and** the server's `protocolVersion >= 2`. Clients send `optimize_prompt`/`replace_prompt` only to a server with `protocolVersion >= 2`. While the optimizer capability is missing, the wand renders dimmed and a tap shows the config hint as a toast; while the server is too old it shows the update-relay hint.
- **Timing (spec §7.1):** `optimize_prompt` and `replace_prompt` wait up to **20 s** (all other RPCs keep 10 s). `optimizing` state lasts for the RPC only. The Undo chip lives **10 s**. Toasts auto-dismiss after **4 s** (plan choice; spec says "toast").
- **Copy — byte-exact, defined once in `OptimizerStrings` (Task 1) and never retyped elsewhere:**
  - config hint: `Enable on the relay: claude-relay config set promptOptimizerEnabled true` (the spec renders the command in backticks; those are Markdown, not copy)
  - `no_draft` toast: `Type or dictate a prompt first`
  - `passthrough` toast: `Nothing to optimize`
  - `failed` toast: the server's `message` verbatim; when the server sent none: `Optimizer could not rewrite this prompt`
  - too-old server hint (spec gives only the phrase "update the relay"): `Update the relay to use the prompt optimizer`
  - Undo chip: `Optimized` and `Undo` (rendered as `Optimized · Undo`)
  - setting: `Share terminal screen with the optimizer` (default **on**, stored per device, sent as `shareScreen`)
  - setting footer (spec §10): `With this on, the relay also sends the last 40 lines of the terminal screen to the optimizer model. The draft and its working directory are always sent.`
  - shortcut UI: iOS toggle label `Optimizer Shortcut`, `UIKeyCommand.discoverabilityTitle` `Optimize Prompt`; macOS section header `Optimizer Shortcut`. Footers say "to optimize the prompt" in place of "to toggle speech recording".
  - Never invent other user-facing strings. Never log transcript/draft/prompt/screen text.
- **Working-tree precondition (hard):** the user has an uncommitted WIP fix in `Sources/CodeRelayClient/RelayConnection.swift`, `Sources/CodeRelayClient/SessionController.swift`, `Tests/CodeRelayClientTests/RelayConnectionTests.swift`, `Tests/CodeRelayClientTests/SessionControllerTestCase.swift`, `Tests/CodeRelayClientTests/SessionControllerTests.swift`, `Tests/CodeRelayClientTests/SessionSwitchLatencyTests.swift`. Task 1 edits `SessionController.swift`. **Before starting Task 1 run `git status --short`; if any of those six files shows `M`, STOP and ask the user to commit their fix first.** Never run `git add -A`, `git add .`, `git stash`, or `git checkout --` in this repo; always `git add` explicit paths.
- **Git:** branch `feat/prompt-optimizer-apple-clients` stacked on `rename/coderelay-layout` (`78dc218` or later). Every commit ends with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Every commit must leave `swift build`, `swift test`, and both Xcode app builds green.
- **XcodeGen:** after any `project.yml` edit run `/opt/homebrew/bin/xcodegen generate` and commit `CodeRelay.xcodeproj/project.pbxproj` with it. Never change `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` (the release skill owns them).
- **Verification (zsh):** `swift test --filter <X> 2>&1 | tail -5; echo EXIT=${pipestatus[1]}` — require both `0 failures` and `EXIT=0` (a piped `tail` hides a crashed xctest). App tests: `xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayMac -destination 'platform=macOS' -skipMacroValidation` and `xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -skipMacroValidation`.
- **Package.resolved:** Docker is not available locally, so the Linux resolve cannot be verified here. Task 6 replaces CI's "restore the macOS superset" step with a `git diff --exit-code -- Package.resolved` check after the Linux build; CI is the verification. Do not run the relay server binary directly.

## File Map

| Path | Task | Change |
|---|---|---|
| `Sources/CodeRelayClient/PromptOptimizer.swift` | 1 | **Create.** `OptimizeOutcome`, `ReplaceOutcome`, `OptimizerStrings`, `Notification.Name.optimizePromptShortcut` |
| `Sources/CodeRelayClient/SessionController.swift` | 1 | `serverProtocolVersion`, `serverCapabilities`, `optimizerTimeout`, `optimizePrompt(sessionId:shareScreen:)`, `replacePrompt(sessionId:text:)`, per-call timeout on `sendAndWaitForResponse` |
| `Tests/CodeRelayClientTests/SessionControllerOptimizerTests.swift` | 1 | **Create** |
| `Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift` | 2 | published optimizer state + `activeSessionId.didSet` clears Undo + `onAuthenticated` refresh |
| `Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator+Optimizer.swift` | 2 | **Create.** `OptimizerAvailability`, `OptimizerState`, `OptimizerUndo`, `optimizePrompt(shareScreen:)`, `undoOptimize()`, `refreshOptimizerAvailability()` |
| `Tests/CodeRelayClientTests/SharedSessionCoordinatorOptimizerTests.swift` | 2 | **Create** |
| `Sources/CodeRelayClient/Views/WandButton.swift` | 3 | **Create.** Shared SwiftUI wand + Undo chip + notice |
| `CodeRelayApp/Views/Components/MicButton.swift` | 4 | **Delete** |
| `CodeRelayApp/Views/ActiveTerminalView.swift`, `Views/Components/RelayTerminalView.swift`, `CodeRelayApp.swift`, `Models/AppSettings.swift`, `Views/SettingsView.swift` | 4 | Remove speech, wire wand, migration, setting |
| `CodeRelayAppTests/{AppSettingsBedrockTests,MockSpeechComponents,AppSettingsContinuousTests,SpeechEngineStateTests,OnDeviceSpeechEngineTests,WhisperHallucinationTests,TextCleanerStaticTests}.swift` | 4 | **Delete** |
| `CodeRelayAppTests/AppSettingsSpeechRemovalTests.swift` | 4 | **Create** |
| `CodeRelayMac/Views/MainWindow.swift`, `Helpers/RecordingShortcutMonitor.swift`, `AppDelegate.swift`, `Models/AppSettings.swift`, `Views/SettingsView.swift`, `CodeRelayMac.entitlements` | 5 | Remove speech, wire wand, migration, setting, entitlement |
| `CodeRelayMacTests/AppSettingsBedrockTests.swift` | 5 | **Delete** |
| `CodeRelayMacTests/AppSettingsSpeechRemovalTests.swift` | 5 | **Create** |
| `Sources/CodeRelaySpeech/**`, `Tests/CodeRelaySpeechTests/**` | 6 | **Delete** |
| `Package.swift`, `Package.resolved`, `project.yml`, `CodeRelay.xcodeproj/project.pbxproj`, `.github/workflows/ci.yml`, `.github/workflows/release.yml` | 6 | Drop CodeRelaySpeech / WhisperKit / LLM.swift, mic Info.plist keys, CI restore step |
| `Sources/CodeRelayClient/AuthManager.swift`, `Tests/CodeRelayClientTests/AuthManagerTests.swift` | 6 | Remove `saveBedrockToken`/`loadBedrockToken`; keep `deleteBedrockToken` |
| `CLAUDE.md`, `README.md`, `CodeRelayApp/README.md`, `CodeRelayMac/README.md`, `docs/linux-server-spec.md`, `docs/android-parity-audit.md`, superseded specs/plans | 7 | Docs |

---

### Task 1: `SessionController` learns the optimizer RPCs and the server's capabilities

**Files:**
- Create: `Sources/CodeRelayClient/PromptOptimizer.swift`
- Modify: `Sources/CodeRelayClient/SessionController.swift` (`init` :157, `authenticate` :193–215, new RPCs after `detach()` :335, `sendAndWaitForResponse` :387, `awaitResponse` :427/:485)
- Create: `Tests/CodeRelayClientTests/SessionControllerOptimizerTests.swift`

**Interfaces:**
- Consumes: `CodeRelayKit.ClientMessage.optimizePrompt/replacePrompt`, `ServerMessage.optimizePromptResult/replacePromptResult/authSuccess(capabilities:)`, `CodeRelayKit.promptOptimizerCapability`; test doubles `FakeConnection`, `SessionControllerTestCase` from `Tests/CodeRelayClientTests/SessionControllerTestCase.swift`.
- Produces (used by Tasks 2–5):
  - `public enum OptimizeOutcome: Equatable { case ok(original: String?); case noDraft; case passthrough; case unconfigured; case failed(message: String) }`
  - `public enum ReplaceOutcome: Equatable { case ok; case failed(message: String) }`
  - `public enum OptimizerStrings` with `static let` strings listed in Global Constraints.
  - `public extension Notification.Name { static let optimizePromptShortcut }`
  - `SessionController.init(connection:, responseTimeout: Duration = .seconds(10), optimizerTimeout: Duration = .seconds(20))`
  - `@Published public private(set) var serverProtocolVersion: Int` (0 until authenticated), `@Published public private(set) var serverCapabilities: Set<String>` (empty until authenticated)
  - `public func optimizePrompt(sessionId: UUID, shareScreen: Bool) async throws -> OptimizeOutcome`
  - `public func replacePrompt(sessionId: UUID, text: String) async throws -> ReplaceOutcome`

- [ ] **Step 0: Precondition**

Run: `git status --short`
Expected: no `M` on any of the six WIP files named in Global Constraints. If there is, STOP and ask the user to commit their desync fix.

Then: `git checkout -b feat/prompt-optimizer-apple-clients`

- [ ] **Step 1: Create the shared types + strings file**

```swift
// Sources/CodeRelayClient/PromptOptimizer.swift
import Foundation

/// Client-side view of `optimize_prompt_result` (spec §6). Unknown statuses
/// collapse into `.failed` so a newer server can never crash an older client.
public enum OptimizeOutcome: Equatable, Sendable {
    /// The relay replaced the draft. `original` is what it replaced, for Undo;
    /// the relay may omit it (nil) when it was not tracking the draft.
    case ok(original: String?)
    case noDraft
    case passthrough
    case unconfigured
    case failed(message: String)
}

/// Client-side view of `replace_prompt_result` (spec §6).
public enum ReplaceOutcome: Equatable, Sendable {
    case ok
    case failed(message: String)
}

/// Every user-facing string of the prompt-optimizer feature, byte-exact per
/// spec §7.1 / §9 / §10. Both apps read these; nothing retypes them.
public enum OptimizerStrings {
    public static let configHint = "Enable on the relay: claude-relay config set promptOptimizerEnabled true"
    public static let updateRelayHint = "Update the relay to use the prompt optimizer"
    public static let noDraft = "Type or dictate a prompt first"
    public static let passthrough = "Nothing to optimize"
    public static let couldNotRewrite = "Optimizer could not rewrite this prompt"
    public static let optimized = "Optimized"
    public static let undo = "Undo"
    public static let wandLabel = "Optimize Prompt"
    public static let shareScreenToggle = "Share terminal screen with the optimizer"
    public static let shareScreenFooter = "With this on, the relay also sends the last 40 lines of the terminal screen to the optimizer model. The draft and its working directory are always sent."
}

public extension Notification.Name {
    /// Posted by the hardware-keyboard shortcut (iOS `RelayTerminalView`,
    /// macOS `RecordingShortcutMonitor`); `WandButton` observes it and taps
    /// itself. Replaces the removed `toggleSpeechRecording`.
    static let optimizePromptShortcut = Notification.Name("optimizePromptShortcut")
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/CodeRelayClientTests/SessionControllerOptimizerTests.swift
import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

/// `optimize_prompt` / `replace_prompt` RPCs and the capability bookkeeping
/// `authenticate()` now does. Uses the FakeConnection harness from
/// `SessionControllerTestCase.swift`.
@MainActor
final class SessionControllerOptimizerTests: SessionControllerTestCase {

    private func authenticated(
        conn: FakeConnection,
        protocolVersion: Int = 2,
        capabilities: [String]? = [CodeRelayKit.promptOptimizerCapability],
        responseTimeout: Duration = .seconds(10),
        optimizerTimeout: Duration = .seconds(20)
    ) async throws -> SessionController {
        let controller = SessionController(
            connection: conn,
            responseTimeout: responseTimeout,
            optimizerTimeout: optimizerTimeout
        )
        conn.autoRespond = { message in
            if case .authRequest = message {
                return .authSuccess(protocolVersion: protocolVersion, tokenId: "tok", capabilities: capabilities)
            }
            return nil
        }
        try await controller.authenticate(token: "t")
        conn.autoRespond = nil
        return controller
    }

    // MARK: - auth_success bookkeeping

    func testAuthRecordsProtocolVersionAndCapabilities() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(conn: conn, protocolVersion: 2, capabilities: ["prompt_optimizer", "future"])
        XCTAssertEqual(controller.serverProtocolVersion, 2)
        XCTAssertEqual(controller.serverCapabilities, ["prompt_optimizer", "future"])
    }

    func testAuthWithoutCapabilitiesLeavesSetEmptyAndVersionZeroWhenAbsent() async throws {
        let conn = FakeConnection()
        let controller = SessionController(connection: conn)
        conn.autoRespond = { message in
            if case .authRequest = message { return .authSuccess(protocolVersion: nil, tokenId: nil, capabilities: nil) }
            return nil
        }
        try await controller.authenticate(token: "t")
        XCTAssertEqual(controller.serverProtocolVersion, 0)
        XCTAssertTrue(controller.serverCapabilities.isEmpty)
    }

    func testReauthReplacesCapabilities() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(conn: conn, capabilities: ["prompt_optimizer"])
        controller.resetAuth()
        conn.autoRespond = { message in
            if case .authRequest = message { return .authSuccess(protocolVersion: 2, tokenId: "tok", capabilities: []) }
            return nil
        }
        try await controller.authenticate(token: "t")
        XCTAssertTrue(controller.serverCapabilities.isEmpty)
    }

    // MARK: - optimize_prompt

    func testOptimizeSendsSessionIdAndShareScreen() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(conn: conn)
        let sessionId = UUID()
        conn.autoRespond = { message in
            if case .optimizePrompt(let id, let share) = message {
                XCTAssertEqual(id, sessionId)
                XCTAssertFalse(share)
                return .optimizePromptResult(status: "ok", original: "fix it", prompt: "Fix the failing test", message: nil)
            }
            return nil
        }
        let outcome = try await controller.optimizePrompt(sessionId: sessionId, shareScreen: false)
        XCTAssertEqual(outcome, .ok(original: "fix it"))
        XCTAssertEqual(conn.sentTypes.last, "optimize_prompt")
    }

    func testOptimizeMapsEveryStatus() async throws {
        let cases: [(String, String?, OptimizeOutcome)] = [
            ("ok", nil, .ok(original: nil)),
            ("no_draft", nil, .noDraft),
            ("passthrough", nil, .passthrough),
            ("unconfigured", nil, .unconfigured),
            ("failed", "Prompt too long to optimize", .failed(message: "Prompt too long to optimize")),
            ("failed", nil, .failed(message: OptimizerStrings.couldNotRewrite)),
            ("something_new", nil, .failed(message: OptimizerStrings.couldNotRewrite)),
        ]
        for (status, message, expected) in cases {
            let conn = FakeConnection()
            let controller = try await authenticated(conn: conn)
            conn.autoRespond = { m in
                if case .optimizePrompt = m {
                    return .optimizePromptResult(status: status, original: nil, prompt: nil, message: message)
                }
                return nil
            }
            let outcome = try await controller.optimizePrompt(sessionId: UUID(), shareScreen: true)
            XCTAssertEqual(outcome, expected, "status \(status)")
        }
    }

    func testOptimizeErrorReplyThrowsUnexpectedResponse() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(conn: conn)
        conn.autoRespond = { m in
            if case .optimizePrompt = m { return .error(code: 400, message: "Session not attached") }
            return nil
        }
        do {
            _ = try await controller.optimizePrompt(sessionId: UUID(), shareScreen: true)
            XCTFail("expected throw")
        } catch SessionError.unexpectedResponse(let message) {
            XCTAssertEqual(message, "Session not attached")
        }
    }

    func testOptimizeUsesTwentySecondWaiterNotTheDefault() async throws {
        // Default waiter 50 ms, optimizer waiter 400 ms: a reply at 200 ms must
        // still be accepted, proving the longer timeout is the one in force.
        let conn = FakeConnection()
        let controller = try await authenticated(
            conn: conn,
            responseTimeout: .milliseconds(50),
            optimizerTimeout: .milliseconds(400)
        )
        conn.autoRespond = nil
        let task = Task { try await controller.optimizePrompt(sessionId: UUID(), shareScreen: true) }
        try await Task.sleep(for: .milliseconds(200))
        conn.deliver(.optimizePromptResult(status: "passthrough", original: nil, prompt: nil, message: nil))
        let outcome = try await task.value
        XCTAssertEqual(outcome, .passthrough)
    }

    func testOptimizeTimesOutAfterOptimizerTimeout() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(
            conn: conn,
            responseTimeout: .milliseconds(50),
            optimizerTimeout: .milliseconds(150)
        )
        do {
            _ = try await controller.optimizePrompt(sessionId: UUID(), shareScreen: true)
            XCTFail("expected timeout")
        } catch SessionError.timeout {
            // expected
        }
    }

    // MARK: - replace_prompt

    func testReplaceSendsTextAndMapsOk() async throws {
        let conn = FakeConnection()
        let controller = try await authenticated(conn: conn)
        let sessionId = UUID()
        conn.autoRespond = { m in
            if case .replacePrompt(let id, let text) = m {
                XCTAssertEqual(id, sessionId)
                XCTAssertEqual(text, "original words")
                return .replacePromptResult(status: "ok", message: nil)
            }
            return nil
        }
        let outcome = try await controller.replacePrompt(sessionId: sessionId, text: "original words")
        XCTAssertEqual(outcome, .ok)
        XCTAssertEqual(conn.sentTypes.last, "replace_prompt")
    }

    func testReplaceMapsFailedAndUnknown() async throws {
        for (status, message, expected) in [
            ("failed", "Session not attached", ReplaceOutcome.failed(message: "Session not attached")),
            ("failed", nil, .failed(message: OptimizerStrings.couldNotRewrite)),
            ("weird", nil, .failed(message: OptimizerStrings.couldNotRewrite)),
        ] {
            let conn = FakeConnection()
            let controller = try await authenticated(conn: conn)
            conn.autoRespond = { m in
                if case .replacePrompt = m { return .replacePromptResult(status: status, message: message) }
                return nil
            }
            let outcome = try await controller.replacePrompt(sessionId: UUID(), text: "x")
            XCTAssertEqual(outcome, expected, "status \(status)")
        }
    }

    func testOtherRPCsStillUseDefaultTimeout() async throws {
        // listSessions must time out at the 50 ms default even though the
        // optimizer waiter is long.
        let conn = FakeConnection()
        let controller = try await authenticated(
            conn: conn,
            responseTimeout: .milliseconds(50),
            optimizerTimeout: .seconds(20)
        )
        let started = ContinuousClock.now
        do {
            _ = try await controller.listSessions()
            XCTFail("expected timeout")
        } catch SessionError.timeout {
            XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        }
    }
}
```

If `FakeConnection.autoRespond` in the committed harness replies *before* the waiter is installed (check `send` in `SessionControllerTestCase.swift`), the existing `SessionControllerForeignErrorTests` already rely on it working with `sendAndWaitForResponse`, so this pattern is safe as written. If `.error(code:message:)` has different labels in `ServerMessage`, copy the labels from `Sources/CodeRelayKit/Protocol/ServerMessage.swift`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter SessionControllerOptimizerTests 2>&1 | tail -5; echo EXIT=${pipestatus[1]}`
Expected: compile error — `optimizerTimeout`, `serverProtocolVersion`, `optimizePrompt(sessionId:shareScreen:)` do not exist.

- [ ] **Step 4: Implement in `SessionController.swift`**

Add the published state next to `isAuthenticated` (:84):

```swift
    /// `protocolVersion` the server reported in `auth_success` (0 when it sent
    /// none — a pre-versioning relay). Reset on re-auth.
    @Published public private(set) var serverProtocolVersion: Int = 0

    /// `capabilities` the server reported in `auth_success` (empty when none).
    /// `CodeRelayKit.promptOptimizerCapability` here means the wand may be used.
    @Published public private(set) var serverCapabilities: Set<String> = []
```

Store the second timeout next to `responseTimeout` (:153) and extend `init` (:157):

```swift
    private let responseTimeout: Duration
    /// Waiter for `optimize_prompt` / `replace_prompt` — the relay is calling a
    /// model, so these get 20 s (spec §7.1) while every other RPC keeps 10 s.
    private let optimizerTimeout: Duration

    public init(
        connection: any ConnectionSurface,
        responseTimeout: Duration = .seconds(10),
        optimizerTimeout: Duration = .seconds(20)
    ) {
        self.connection = connection
        self.responseTimeout = responseTimeout
        self.optimizerTimeout = optimizerTimeout
        // ...keep the rest of the existing init body unchanged...
    }
```

In `authenticate(token:)` (:193) change the success arm to keep the capabilities:

```swift
        case .authSuccess(let serverProtocolVersion, let serverTokenId, let capabilities):
            // (existing version-compat check stays exactly as it is)
            self.serverProtocolVersion = serverProtocolVersion ?? 0
            self.serverCapabilities = Set(capabilities ?? [])
            // ...existing isAuthenticated / authenticatedGeneration / tokenId assignments...
```

(Keep the existing `versionIncompatible` logic untouched; only the binding of the third associated value changes from `_` to `let capabilities`, plus the two assignments.)

Add the two RPCs immediately after `detach()` (:335):

```swift
    // MARK: - Prompt optimizer (spec §6)

    /// Ask the relay to rewrite the draft at the agent's input line. The relay
    /// types the rewrite itself; the reply only tells us how it went.
    public func optimizePrompt(sessionId: UUID, shareScreen: Bool) async throws -> OptimizeOutcome {
        let response = try await sendAndWaitForResponse(
            .optimizePrompt(sessionId: sessionId, shareScreen: shareScreen),
            expected: ["optimize_prompt_result"],
            timeout: optimizerTimeout
        )
        switch response {
        case .optimizePromptResult(let status, let original, _, let message):
            switch status {
            case "ok": return .ok(original: original)
            case "no_draft": return .noDraft
            case "passthrough": return .passthrough
            case "unconfigured": return .unconfigured
            default: return .failed(message: message ?? OptimizerStrings.couldNotRewrite)
            }
        case .error(_, let message):
            throw SessionError.unexpectedResponse(message)
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }

    /// Put `text` back at the input line (Undo). Same waiter as optimize.
    public func replacePrompt(sessionId: UUID, text: String) async throws -> ReplaceOutcome {
        let response = try await sendAndWaitForResponse(
            .replacePrompt(sessionId: sessionId, text: text),
            expected: ["replace_prompt_result"],
            timeout: optimizerTimeout
        )
        switch response {
        case .replacePromptResult(let status, let message):
            return status == "ok" ? .ok : .failed(message: message ?? OptimizerStrings.couldNotRewrite)
        case .error(_, let message):
            throw SessionError.unexpectedResponse(message)
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }
```

Thread a per-call override through the waiter. Change the signature at :387 to

```swift
    private func sendAndWaitForResponse(
        _ message: ClientMessage,
        expected: Set<String>,
        timeout: Duration? = nil
    ) async throws -> ServerMessage {
```

and pass `timeout` into the existing `awaitResponse(message, expected:)` call inside it. Change `awaitResponse` (:427) to take `timeout: Duration?` and replace `let timeout = responseTimeout` (:485) with `let timeout = timeout ?? self.responseTimeout`. No other call site changes (they pass no timeout).

- [ ] **Step 5: Run the new tests and the whole client suite**

Run: `swift test --filter SessionControllerOptimizerTests 2>&1 | tail -5; echo EXIT=${pipestatus[1]}`
Expected: `Executed 11 tests, with 0 failures`, `EXIT=0`.

Run: `swift test --filter CodeRelayClientTests 2>&1 | grep -E "Executed|error:|failed" | tail -5; echo EXIT=${pipestatus[1]}`
Expected: 0 failures, `EXIT=0`.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodeRelayClient/PromptOptimizer.swift Sources/CodeRelayClient/SessionController.swift Tests/CodeRelayClientTests/SessionControllerOptimizerTests.swift
git commit -m "feat(client): optimize_prompt/replace_prompt RPCs and auth_success capabilities on SessionController

20 s waiter for the two optimizer RPCs via a per-call timeout override;
every other RPC keeps the 10 s default. OptimizerStrings holds the byte-exact
spec copy for both apps.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `SharedSessionCoordinator` owns the wand state machine

**Files:**
- Modify: `Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift` (`activeSessionId.didSet` :14–19, published state after `sessionAttachError` ~:106, `onAuthenticated` closure :235)
- Create: `Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator+Optimizer.swift`
- Create: `Tests/CodeRelayClientTests/SharedSessionCoordinatorOptimizerTests.swift`

**Interfaces:**
- Consumes (Task 1): `SessionController.serverProtocolVersion`, `.serverCapabilities`, `.isAuthenticated`, `.optimizePrompt(sessionId:shareScreen:)`, `.replacePrompt(sessionId:text:)`, `OptimizeOutcome`, `ReplaceOutcome`, `OptimizerStrings`; existing `ensureAuthenticated()`, `withAuth(_:)`, `isRecovering`, `activeSessionId`, `CodeRelayKit.promptOptimizerCapability`.
- Produces (used by Tasks 3–5):
  - `public enum OptimizerAvailability: Equatable { case unknown, serverTooOld, unconfigured, available }`
  - `public enum OptimizerState: Equatable { case idle, optimizing }`
  - `public struct OptimizerUndo: Equatable { public let sessionId: UUID; public let original: String }`
  - `@Published public internal(set) var optimizerAvailability: OptimizerAvailability` (default `.unknown`)
  - `@Published public internal(set) var optimizerState: OptimizerState` (default `.idle`)
  - `@Published public internal(set) var optimizerUndo: OptimizerUndo?` (non-nil for 10 s after an `ok`)
  - `@Published public internal(set) var optimizerNotice: String?` (toast text, auto-cleared)
  - `public var optimizerUndoWindow: Duration = .seconds(10)`, `public var optimizerNoticeDuration: Duration = .seconds(4)` (tests shorten them)
  - `public var isWandEnabled: Bool`, `public var isOptimizerAvailable: Bool`, `public var wandHint: String?`
  - `public func optimizePrompt(shareScreen: Bool) async`, `public func undoOptimize() async`, `public func refreshOptimizerAvailability()`, `public func dismissOptimizerNotice()`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CodeRelayClientTests/SharedSessionCoordinatorOptimizerTests.swift
import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

/// Wand state transitions, toasts, and Undo on the shared coordinator (spec
/// §7.1 / §11). A FakeConnection-backed, already-authenticated
/// `SessionController` is injected through `coordinator.sessionController`;
/// `RelayConnection()` is never opened.
@MainActor
final class SharedSessionCoordinatorOptimizerTests: XCTestCase {

    private var conn: FakeConnection!
    private var coordinator: SharedSessionCoordinator!
    private let sessionId = UUID()

    override func setUp() async throws {
        try await super.setUp()
        conn = FakeConnection()
        coordinator = SharedSessionCoordinator(connection: RelayConnection(), token: "t")
        coordinator.optimizerUndoWindow = .milliseconds(150)
        coordinator.optimizerNoticeDuration = .milliseconds(150)
        coordinator.activeSessionId = sessionId
    }

    override func tearDown() async throws {
        coordinator.tearDown()
        coordinator = nil
        conn = nil
        try await super.tearDown()
    }

    /// Authenticates a controller against `conn` and hands it to the coordinator.
    private func inject(protocolVersion: Int = 2, capabilities: [String]? = [CodeRelayKit.promptOptimizerCapability]) async throws {
        let controller = SessionController(connection: conn)
        conn.autoRespond = { m in
            if case .authRequest = m {
                return .authSuccess(protocolVersion: protocolVersion, tokenId: "tok", capabilities: capabilities)
            }
            return nil
        }
        try await controller.authenticate(token: "t")
        conn.autoRespond = nil
        coordinator.sessionController = controller
        coordinator.refreshOptimizerAvailability()
    }

    private func respondToOptimize(_ result: ServerMessage) {
        conn.autoRespond = { m in
            if case .optimizePrompt = m { return result }
            return nil
        }
    }

    // MARK: - Availability

    func testAvailabilityUnknownBeforeAuth() {
        XCTAssertEqual(coordinator.optimizerAvailability, .unknown)
        XCTAssertFalse(coordinator.isOptimizerAvailable)
        XCTAssertNil(coordinator.wandHint)
    }

    func testAvailableWhenCapabilityPresentAndProtocolV2() async throws {
        try await inject()
        XCTAssertEqual(coordinator.optimizerAvailability, .available)
        XCTAssertTrue(coordinator.isOptimizerAvailable)
        XCTAssertNil(coordinator.wandHint)
    }

    func testUnconfiguredWhenCapabilityMissing() async throws {
        try await inject(capabilities: [])
        XCTAssertEqual(coordinator.optimizerAvailability, .unconfigured)
        XCTAssertEqual(coordinator.wandHint, OptimizerStrings.configHint)
    }

    func testServerTooOldWhenProtocolBelowTwo() async throws {
        try await inject(protocolVersion: 1, capabilities: [CodeRelayKit.promptOptimizerCapability])
        XCTAssertEqual(coordinator.optimizerAvailability, .serverTooOld)
        XCTAssertEqual(coordinator.wandHint, OptimizerStrings.updateRelayHint)
    }

    // MARK: - Enablement

    func testWandEnabledOnlyWhenIdleNotRecoveringWithActiveSession() async throws {
        try await inject()
        XCTAssertTrue(coordinator.isWandEnabled)
        coordinator.isRecovering = true
        XCTAssertFalse(coordinator.isWandEnabled)
        coordinator.isRecovering = false
        coordinator.activeSessionId = nil
        XCTAssertFalse(coordinator.isWandEnabled)
    }

    func testTapWhileUnconfiguredShowsConfigHintAndSendsNothing() async throws {
        try await inject(capabilities: [])
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertEqual(coordinator.optimizerNotice, OptimizerStrings.configHint)
        XCTAssertFalse(conn.sentTypes.contains("optimize_prompt"))
        XCTAssertEqual(coordinator.optimizerState, .idle)
    }

    func testTapWhileServerTooOldShowsUpdateHintAndSendsNothing() async throws {
        try await inject(protocolVersion: 1)
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertEqual(coordinator.optimizerNotice, OptimizerStrings.updateRelayHint)
        XCTAssertFalse(conn.sentTypes.contains("optimize_prompt"))
    }

    // MARK: - optimize → ok → Undo

    func testOkArmsUndoAndUndoSendsReplaceWithOriginal() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: "fix the thing", prompt: "Fix the thing.", message: nil))

        await coordinator.optimizePrompt(shareScreen: false)

        XCTAssertEqual(coordinator.optimizerState, .idle)
        XCTAssertEqual(coordinator.optimizerUndo, OptimizerUndo(sessionId: sessionId, original: "fix the thing"))
        XCTAssertNil(coordinator.optimizerNotice)
        if case .optimizePrompt(let id, let share) = conn.sentMessages.last {
            XCTAssertEqual(id, sessionId)
            XCTAssertFalse(share)
        } else {
            XCTFail("expected optimize_prompt, got \(conn.sentTypes)")
        }

        conn.autoRespond = { m in
            if case .replacePrompt = m { return .replacePromptResult(status: "ok", message: nil) }
            return nil
        }
        await coordinator.undoOptimize()

        if case .replacePrompt(let id, let text) = conn.sentMessages.last {
            XCTAssertEqual(id, sessionId)
            XCTAssertEqual(text, "fix the thing")
        } else {
            XCTFail("expected replace_prompt, got \(conn.sentTypes)")
        }
        XCTAssertNil(coordinator.optimizerUndo, "Undo is one-shot")
        XCTAssertEqual(coordinator.optimizerState, .idle)
    }

    func testStateIsOptimizingWhileRPCInFlightAndTapIsIgnoredMeanwhile() async throws {
        try await inject()
        conn.autoRespond = nil
        let first = Task { await coordinator.optimizePrompt(shareScreen: true) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(coordinator.optimizerState, .optimizing)
        XCTAssertFalse(coordinator.isWandEnabled)

        await coordinator.optimizePrompt(shareScreen: true) // second tap: ignored
        XCTAssertEqual(conn.sentTypes.filter { $0 == "optimize_prompt" }.count, 1)

        conn.deliver(.optimizePromptResult(status: "ok", original: "a", prompt: "b", message: nil))
        await first.value
        XCTAssertEqual(coordinator.optimizerState, .idle)
    }

    func testUndoExpiresAfterWindow() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: "a", prompt: "b", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertNotNil(coordinator.optimizerUndo)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(coordinator.optimizerUndo)
    }

    func testSwitchingSessionClearsUndo() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: "a", prompt: "b", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertNotNil(coordinator.optimizerUndo)
        coordinator.activeSessionId = UUID()
        XCTAssertNil(coordinator.optimizerUndo)
    }

    func testOkWithoutOriginalArmsNoUndo() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: nil, prompt: "b", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertNil(coordinator.optimizerUndo)
        XCTAssertNil(coordinator.optimizerNotice)
    }

    // MARK: - Toasts

    func testNoDraftPassthroughUnconfiguredFailedToasts() async throws {
        let cases: [(ServerMessage, String)] = [
            (.optimizePromptResult(status: "no_draft", original: nil, prompt: nil, message: nil), OptimizerStrings.noDraft),
            (.optimizePromptResult(status: "passthrough", original: nil, prompt: nil, message: nil), OptimizerStrings.passthrough),
            (.optimizePromptResult(status: "unconfigured", original: nil, prompt: nil, message: nil), OptimizerStrings.configHint),
            (.optimizePromptResult(status: "failed", original: nil, prompt: nil, message: "Optimizer key rejected on the relay"), "Optimizer key rejected on the relay"),
            (.optimizePromptResult(status: "failed", original: nil, prompt: nil, message: nil), OptimizerStrings.couldNotRewrite),
        ]
        for (reply, expected) in cases {
            try await inject()
            respondToOptimize(reply)
            await coordinator.optimizePrompt(shareScreen: true)
            XCTAssertEqual(coordinator.optimizerNotice, expected)
            XCTAssertNil(coordinator.optimizerUndo)
            coordinator.dismissOptimizerNotice()
        }
    }

    func testUnconfiguredReplyDowngradesAvailability() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "unconfigured", original: nil, prompt: nil, message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertEqual(coordinator.optimizerAvailability, .unconfigured)
    }

    func testErrorReplyBecomesToastWithServerMessage() async throws {
        try await inject()
        respondToOptimize(.error(code: 400, message: "Session not attached"))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertEqual(coordinator.optimizerNotice, "Session not attached")
        XCTAssertEqual(coordinator.optimizerState, .idle)
    }

    func testNoticeAutoDismisses() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "passthrough", original: nil, prompt: nil, message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        XCTAssertNotNil(coordinator.optimizerNotice)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(coordinator.optimizerNotice)
    }

    func testUndoFailureShowsServerMessage() async throws {
        try await inject()
        respondToOptimize(.optimizePromptResult(status: "ok", original: "a", prompt: "b", message: nil))
        await coordinator.optimizePrompt(shareScreen: true)
        conn.autoRespond = { m in
            if case .replacePrompt = m { return .replacePromptResult(status: "failed", message: "Session not attached") }
            return nil
        }
        await coordinator.undoOptimize()
        XCTAssertEqual(coordinator.optimizerNotice, "Session not attached")
        XCTAssertNil(coordinator.optimizerUndo)
    }
}
```

If `SharedSessionCoordinator.tearDown()` is not the method's name, use whatever `SharedSessionCoordinatorTests.testTearDownSetsFlag` calls.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SharedSessionCoordinatorOptimizerTests 2>&1 | tail -5; echo EXIT=${pipestatus[1]}`
Expected: compile error — `optimizerAvailability` etc. do not exist.

- [ ] **Step 3: Add the stored state to `SharedSessionCoordinator.swift`**

Below `sessionAttachError` (~:106) add:

```swift
    // MARK: - Prompt optimizer (behaviour in SharedSessionCoordinator+Optimizer.swift)

    /// What the wand may do, derived from `auth_success` (spec §7.1).
    @Published public internal(set) var optimizerAvailability: OptimizerAvailability = .unknown
    /// `.optimizing` only for the duration of one `optimize_prompt` /
    /// `replace_prompt` round trip.
    @Published public internal(set) var optimizerState: OptimizerState = .idle
    /// Non-nil for `optimizerUndoWindow` after a successful rewrite.
    @Published public internal(set) var optimizerUndo: OptimizerUndo?
    /// Transient toast text; auto-cleared after `optimizerNoticeDuration`.
    @Published public internal(set) var optimizerNotice: String?
    public var optimizerUndoWindow: Duration = .seconds(10)
    public var optimizerNoticeDuration: Duration = .seconds(4)
    var optimizerUndoTask: Task<Void, Never>?
    var optimizerNoticeTask: Task<Void, Never>?
```

Extend the `activeSessionId.didSet` (:14–19) so the Undo cannot fire at a different session:

```swift
    @Published public var activeSessionId: UUID? {
        didSet {
            guard activeSessionId != oldValue else { return }
            ownershipStore.saveActiveSession(activeSessionId)
            clearOptimizerUndo()
        }
    }
```

In `init` (:235) refresh availability whenever auth completes:

```swift
        authCoordinator.onAuthenticated = { [weak self] in
            self?.refreshOptimizerAvailability()
            self?.didAuthenticate()
        }
```

- [ ] **Step 4: Create the behaviour extension**

```swift
// Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator+Optimizer.swift
import Foundation
import CodeRelayKit

/// Whether the wand may be used against the connected relay (spec §7.1).
public enum OptimizerAvailability: Equatable, Sendable {
    /// Not authenticated yet.
    case unknown
    /// `protocolVersion < 2`: the relay predates the optimizer RPCs.
    case serverTooOld
    /// Relay speaks v2 but did not advertise `prompt_optimizer`.
    case unconfigured
    case available
}

public enum OptimizerState: Equatable, Sendable {
    case idle
    case optimizing
}

/// What Undo will put back, and at which session.
public struct OptimizerUndo: Equatable, Sendable {
    public let sessionId: UUID
    public let original: String

    public init(sessionId: UUID, original: String) {
        self.sessionId = sessionId
        self.original = original
    }
}

extension SharedSessionCoordinator {

    /// The button is tappable. Availability is deliberately *not* part of this:
    /// an unavailable wand is drawn dimmed and a tap shows the hint (spec §9).
    public var isWandEnabled: Bool {
        optimizerState == .idle && !isRecovering && activeSessionId != nil
    }

    public var isOptimizerAvailable: Bool { optimizerAvailability == .available }

    /// Tooltip / footer for a dimmed wand; nil when available or unknown.
    public var wandHint: String? {
        switch optimizerAvailability {
        case .available, .unknown: return nil
        case .serverTooOld: return OptimizerStrings.updateRelayHint
        case .unconfigured: return OptimizerStrings.configHint
        }
    }

    /// Re-derive availability from the current controller. Called after every
    /// authentication and before every optimize.
    public func refreshOptimizerAvailability() {
        guard let controller = sessionController, controller.isAuthenticated else {
            optimizerAvailability = .unknown
            return
        }
        if controller.serverProtocolVersion < 2 {
            optimizerAvailability = .serverTooOld
        } else if controller.serverCapabilities.contains(CodeRelayKit.promptOptimizerCapability) {
            optimizerAvailability = .available
        } else {
            optimizerAvailability = .unconfigured
        }
    }

    /// Wand tap. Never throws: every outcome becomes state or a toast.
    public func optimizePrompt(shareScreen: Bool) async {
        guard isWandEnabled, let sessionId = activeSessionId else { return }
        optimizerState = .optimizing
        defer { optimizerState = .idle }
        clearOptimizerUndo()

        do {
            _ = try await ensureAuthenticated()
            refreshOptimizerAvailability()
            switch optimizerAvailability {
            case .serverTooOld:
                showOptimizerNotice(OptimizerStrings.updateRelayHint)
                return
            case .unconfigured:
                showOptimizerNotice(OptimizerStrings.configHint)
                return
            case .unknown, .available:
                break
            }

            let outcome = try await withAuth { controller in
                try await controller.optimizePrompt(sessionId: sessionId, shareScreen: shareScreen)
            }
            switch outcome {
            case .ok(let original):
                if let original, activeSessionId == sessionId {
                    armOptimizerUndo(OptimizerUndo(sessionId: sessionId, original: original))
                }
            case .noDraft:
                showOptimizerNotice(OptimizerStrings.noDraft)
            case .passthrough:
                showOptimizerNotice(OptimizerStrings.passthrough)
            case .unconfigured:
                optimizerAvailability = .unconfigured
                showOptimizerNotice(OptimizerStrings.configHint)
            case .failed(let message):
                showOptimizerNotice(message)
            }
        } catch {
            showOptimizerNotice(optimizerMessage(for: error))
        }
    }

    /// Undo chip tap: put the original back. One-shot.
    public func undoOptimize() async {
        guard optimizerState == .idle, let undo = optimizerUndo, undo.sessionId == activeSessionId else { return }
        clearOptimizerUndo()
        optimizerState = .optimizing
        defer { optimizerState = .idle }
        do {
            let outcome = try await withAuth { controller in
                try await controller.replacePrompt(sessionId: undo.sessionId, text: undo.original)
            }
            if case .failed(let message) = outcome {
                showOptimizerNotice(message)
            }
        } catch {
            showOptimizerNotice(optimizerMessage(for: error))
        }
    }

    public func dismissOptimizerNotice() {
        optimizerNoticeTask?.cancel()
        optimizerNoticeTask = nil
        optimizerNotice = nil
    }

    // MARK: - Internals

    func showOptimizerNotice(_ text: String) {
        optimizerNoticeTask?.cancel()
        optimizerNotice = text
        let duration = optimizerNoticeDuration
        optimizerNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.optimizerNotice = nil
        }
    }

    func armOptimizerUndo(_ undo: OptimizerUndo) {
        optimizerUndoTask?.cancel()
        optimizerUndo = undo
        let window = optimizerUndoWindow
        optimizerUndoTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.optimizerUndo = nil
        }
    }

    func clearOptimizerUndo() {
        optimizerUndoTask?.cancel()
        optimizerUndoTask = nil
        optimizerUndo = nil
    }

    /// `.error` replies carry the relay's message (e.g. "Session not attached");
    /// anything else (timeout, dead socket) gets the generic fallback. Never
    /// includes draft/prompt text.
    private func optimizerMessage(for error: Error) -> String {
        if case SessionError.unexpectedResponse(let message) = error, !message.isEmpty {
            return message
        }
        return OptimizerStrings.couldNotRewrite
    }
}
```

`SharedSessionCoordinator` is `@MainActor`, so the extension's members inherit that isolation and the `Task { [weak self] in ... }` bodies run on the main actor.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter SharedSessionCoordinatorOptimizerTests 2>&1 | tail -5; echo EXIT=${pipestatus[1]}`
Expected: `Executed 17 tests, with 0 failures`, `EXIT=0`.

Run: `swift test --filter CodeRelayClientTests 2>&1 | grep -E "Executed|error:|failed" | tail -5; echo EXIT=${pipestatus[1]}`
Expected: 0 failures, `EXIT=0`.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator+Optimizer.swift Tests/CodeRelayClientTests/SharedSessionCoordinatorOptimizerTests.swift
git commit -m "feat(client): wand state machine on SharedSessionCoordinator

availability (unknown/serverTooOld/unconfigured/available) from auth_success,
idle→optimizing for one RPC, 10 s one-shot Undo via replace_prompt, 4 s toasts
with the spec's byte-exact copy.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Shared `WandButton` view and `SpeechRemovalMigration` helper

**Files:**
- Create: `Sources/CodeRelayClient/Views/WandButton.swift`
- Create: `Sources/CodeRelayClient/SpeechRemovalMigration.swift`
- Create: `Tests/CodeRelayClientTests/SpeechRemovalMigrationTests.swift`

**Interfaces:**
- Consumes (Task 2): `SharedSessionCoordinator.isWandEnabled`, `.isOptimizerAvailable`, `.wandHint`, `.optimizerState`, `.optimizerUndo`, `.optimizerNotice`, `.optimizePrompt(shareScreen:)`, `.undoOptimize()`, `.dismissOptimizerNotice()`; (Task 1) `OptimizerStrings`, `Notification.Name.optimizePromptShortcut`.
- Produces (used by Tasks 4–5):
  - `public struct WandButton: View` with `public init(coordinator: SharedSessionCoordinator, shareScreen: Bool, size: CGFloat = 44, fill: Color = Color.gray.opacity(0.5), onTap: (() -> Void)? = nil)`. It lays out `[notice chip] [Optimized · Undo chip] [wand]` in an `HStack(spacing: 8)`, so it is a drop-in for the old mic button's slot.
  - `public enum SpeechRemovalMigration { @discardableResult public static func run(defaults: UserDefaults, doneKey: String, legacyKeys: [String], modelsDirectory: URL, fileManager: FileManager = .default, deleteBedrockToken: () throws -> Void) -> Bool }` — the one-time cleanup both apps call with their own keys and paths (spec §7.2).

The view is pure SwiftUI and has no unit tests (same as `AgentSparkleIcon.swift`); verification is the package build plus both app builds in Tasks 4/5. The migration helper is pure and tested here.

- [ ] **Step 1: Write the failing migration tests**

```swift
// Tests/CodeRelayClientTests/SpeechRemovalMigrationTests.swift
import XCTest
@testable import CodeRelayClient

/// The shared one-time cleanup both apps run after voice transcription was
/// removed (spec §7.2 / §11): legacy defaults gone, model directory gone,
/// Bedrock secret gone, and the done-flag set only when all of that succeeded.
final class SpeechRemovalMigrationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var modelsDir: URL!
    private let doneKey = "test.speechRemovalMigrationDone"
    private let legacyKeys = ["a.legacy", "b.legacy", "c.whisperDownloaded"]

    override func setUp() {
        super.setUp()
        let suite = "SpeechRemovalMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        modelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRemoval-\(UUID().uuidString)/Models", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: modelsDir.deletingLastPathComponent())
        defaults = nil
        super.tearDown()
    }

    private func seedLegacyState() throws {
        for key in legacyKeys { defaults.set("x", forKey: key) }
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: modelsDir.appendingPathComponent("qwen35-0.8b-q4km.gguf"))
    }

    private func run(delete: () throws -> Void = {}) -> Bool {
        SpeechRemovalMigration.run(
            defaults: defaults, doneKey: doneKey, legacyKeys: legacyKeys,
            modelsDirectory: modelsDir, deleteBedrockToken: delete
        )
    }

    func testRemovesKeysDirectoryAndSecretThenMarksDone() throws {
        try seedLegacyState()
        var deleteCalls = 0
        XCTAssertTrue(run(delete: { deleteCalls += 1 }))
        XCTAssertEqual(deleteCalls, 1)
        for key in legacyKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsDir.path))
        XCTAssertTrue(defaults.bool(forKey: doneKey))
    }

    func testIsOneShot() throws {
        try seedLegacyState()
        var deleteCalls = 0
        _ = run(delete: { deleteCalls += 1 })
        defaults.set("again", forKey: "a.legacy")
        XCTAssertFalse(run(delete: { deleteCalls += 1 }), "already done → false")
        XCTAssertEqual(deleteCalls, 1)
        XCTAssertEqual(defaults.string(forKey: "a.legacy"), "again")
    }

    func testMissingModelDirectoryIsNotAFailure() {
        XCTAssertTrue(run())
        XCTAssertTrue(defaults.bool(forKey: doneKey))
    }

    func testKeychainFailureLeavesFlagUnsetSoItRetries() throws {
        try seedLegacyState()
        struct Boom: Error {}
        XCTAssertFalse(run(delete: { throw Boom() }))
        XCTAssertFalse(defaults.bool(forKey: doneKey))
        XCTAssertNil(defaults.object(forKey: "a.legacy"), "defaults are still scrubbed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsDir.path), "directory is still deleted")
    }

    func testRetryAfterFailureCompletes() throws {
        try seedLegacyState()
        struct Boom: Error {}
        _ = run(delete: { throw Boom() })
        XCTAssertTrue(run())
        XCTAssertTrue(defaults.bool(forKey: doneKey))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SpeechRemovalMigrationTests 2>&1 | tail -5; echo EXIT=${pipestatus[1]}`
Expected: compile error — `SpeechRemovalMigration` does not exist.

- [ ] **Step 3: Create the helper**

```swift
// Sources/CodeRelayClient/SpeechRemovalMigration.swift
import Foundation

/// One-time first-launch cleanup after voice transcription was removed from
/// the apps (spec §7.2). Each app passes its own `@AppStorage` key list, done
/// flag, and `SpeechModelStore` directory; the keychain delete is injected so
/// tests never touch the real keychain.
///
/// Returns `true` when the migration ran to completion in this call; `false`
/// when it had already run, or when a step failed — in which case the done
/// flag stays unset so the next launch retries. Removing defaults and deleting
/// the directory are best-effort and happen regardless of the keychain result.
public enum SpeechRemovalMigration {
    @discardableResult
    public static func run(
        defaults: UserDefaults,
        doneKey: String,
        legacyKeys: [String],
        modelsDirectory: URL,
        fileManager: FileManager = .default,
        deleteBedrockToken: () throws -> Void
    ) -> Bool {
        guard !defaults.bool(forKey: doneKey) else { return false }
        for key in legacyKeys { defaults.removeObject(forKey: key) }

        var succeeded = true
        if fileManager.fileExists(atPath: modelsDirectory.path) {
            do { try fileManager.removeItem(at: modelsDirectory) } catch { succeeded = false }
        }
        do { try deleteBedrockToken() } catch { succeeded = false }

        if succeeded { defaults.set(true, forKey: doneKey) }
        return succeeded
    }
}
```

- [ ] **Step 4: Run the migration tests**

Run: `swift test --filter SpeechRemovalMigrationTests 2>&1 | tail -5; echo EXIT=${pipestatus[1]}`
Expected: `Executed 5 tests, with 0 failures`, `EXIT=0`.

- [ ] **Step 5: Create the view**

```swift
// Sources/CodeRelayClient/Views/WandButton.swift
import SwiftUI

/// The "magic wand" prompt-optimizer button shared by the iOS and macOS apps
/// (spec §7.1 / §7.2). All state lives on `SharedSessionCoordinator`; this
/// view only renders it and forwards taps.
///
/// Layout, left to right: an optional toast chip (`optimizerNotice`), an
/// optional `Optimized · Undo` chip (`optimizerUndo`), then the wand itself.
/// Hosts drop it exactly where the mic button used to be.
public struct WandButton: View {
    @ObservedObject private var coordinator: SharedSessionCoordinator
    private let shareScreen: Bool
    private let size: CGFloat
    private let fill: Color
    private let onTap: (() -> Void)?

    /// - Parameters:
    ///   - shareScreen: the device's "Share terminal screen with the optimizer"
    ///     setting, forwarded as the RPC's `shareScreen`.
    ///   - size: diameter of the circular button (44 on iOS, 26 on macOS).
    ///   - fill: circle colour behind the glyph.
    ///   - onTap: platform hook run before the optimize starts (iOS haptics).
    public init(
        coordinator: SharedSessionCoordinator,
        shareScreen: Bool,
        size: CGFloat = 44,
        fill: Color = Color.gray.opacity(0.5),
        onTap: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.shareScreen = shareScreen
        self.size = size
        self.fill = fill
        self.onTap = onTap
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let notice = coordinator.optimizerNotice {
                chip {
                    Text(notice)
                        .lineLimit(2)
                        .onTapGesture { coordinator.dismissOptimizerNotice() }
                }
                .transition(.opacity)
            }
            if coordinator.optimizerUndo != nil {
                chip {
                    HStack(spacing: 4) {
                        Text(OptimizerStrings.optimized)
                        Text("·").foregroundStyle(.secondary)
                        Button(OptimizerStrings.undo) {
                            Task { await coordinator.undoOptimize() }
                        }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .disabled(!coordinator.isWandEnabled)
                    }
                }
                .transition(.opacity)
            }
            wand
        }
        .animation(.easeInOut(duration: 0.15), value: coordinator.optimizerNotice)
        .animation(.easeInOut(duration: 0.15), value: coordinator.optimizerUndo)
        .onReceive(NotificationCenter.default.publisher(for: .optimizePromptShortcut)) { _ in
            trigger()
        }
    }

    private var wand: some View {
        Button(action: trigger) {
            ZStack {
                Circle().fill(fill)
                if coordinator.optimizerState == .optimizing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: size * 0.38, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .opacity(coordinator.isOptimizerAvailable ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!coordinator.isWandEnabled)
        .help(coordinator.wandHint ?? OptimizerStrings.wandLabel)
        .accessibilityLabel(OptimizerStrings.wandLabel)
        .accessibilityHint(coordinator.wandHint ?? "")
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: max(11, size * 0.28)))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }

    private func trigger() {
        guard coordinator.isWandEnabled else { return }
        onTap?()
        Task { await coordinator.optimizePrompt(shareScreen: shareScreen) }
    }
}
```

`.help(_:)` is the macOS tooltip and is harmless on iOS; `ProgressView.tint` and `.controlSize` exist on both platforms at the deployment targets.

- [ ] **Step 6: Build the package**

Run: `swift build 2>&1 | tail -3; echo EXIT=${pipestatus[1]}`
Expected: `Build complete!`, `EXIT=0`.

- [ ] **Step 7: Commit**

```bash
git add Sources/CodeRelayClient/Views/WandButton.swift Sources/CodeRelayClient/SpeechRemovalMigration.swift Tests/CodeRelayClientTests/SpeechRemovalMigrationTests.swift
git commit -m "feat(client): shared WandButton and SpeechRemovalMigration helper

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: iOS — remove speech, wire the wand, migrate settings

**Files:**
- Delete: `CodeRelayApp/Views/Components/MicButton.swift`
- Delete: `CodeRelayAppTests/AppSettingsBedrockTests.swift`, `CodeRelayAppTests/MockSpeechComponents.swift`, `CodeRelayAppTests/AppSettingsContinuousTests.swift`, `CodeRelayAppTests/SpeechEngineStateTests.swift`, `CodeRelayAppTests/OnDeviceSpeechEngineTests.swift`, `CodeRelayAppTests/WhisperHallucinationTests.swift`, `CodeRelayAppTests/TextCleanerStaticTests.swift`
- Modify: `CodeRelayApp/Models/AppSettings.swift` (whole file), `CodeRelayApp/Views/ActiveTerminalView.swift` (:4, :22–27, :61–63, :65–101, :199–210, :223–235, :247–255, :433–437), `CodeRelayApp/Views/Components/RelayTerminalView.swift` (:85–105), `CodeRelayApp/CodeRelayApp.swift` (:6, `preloadTask`, :94–98, :143–160), `CodeRelayApp/Views/SettingsView.swift` (:16–55, :78–100, :103, :155, :190–197)
- Create: `CodeRelayAppTests/AppSettingsSpeechRemovalTests.swift`

**Interfaces:**
- Consumes: `WandButton`, `SpeechRemovalMigration.run(...)` (Task 3), `SharedSessionCoordinator` optimizer API (Task 2), `OptimizerStrings`, `.optimizePromptShortcut` (Task 1), `AuthManager.shared.deleteBedrockToken()` (exists; kept forever by Task 6).
- Produces: `AppSettings.shareScreenWithOptimizer: Bool` (`@AppStorage("shareScreenWithOptimizer")`, default `true`); `static func migrateSpeechRemoval(defaults:modelsDirectory:deleteBedrockToken:) -> Bool` (forwards to the shared helper with the iOS keys); `static let speechRemovalMigrationKey = "speechRemovalMigrationDone"`; `static let legacySpeechDefaultsKeys: [String]`; `static var legacySpeechModelsDirectory: URL`.

The `CodeRelaySpeech` product stays in `project.yml` until Task 6, so after this task the iOS target simply no longer imports it. Do not touch `project.yml` here.

- [ ] **Step 1: Write the failing migration tests**

```swift
// CodeRelayAppTests/AppSettingsSpeechRemovalTests.swift
import XCTest
@testable import CodeRelayApp

/// The iOS wiring of the shared `SpeechRemovalMigration` (spec §7.2 / §11):
/// the right legacy keys, the right done flag, and the Bedrock secret gone
/// after one launch. The helper's own edge cases are covered in
/// `SpeechRemovalMigrationTests` (CodeRelayClientTests).
@MainActor
final class AppSettingsSpeechRemovalTests: XCTestCase {

    private var defaults: UserDefaults!
    private var modelsDir: URL!

    override func setUp() {
        super.setUp()
        let suite = "AppSettingsSpeechRemovalTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        modelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRemoval-\(UUID().uuidString)/Models", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: modelsDir.deletingLastPathComponent())
        defaults = nil
        super.tearDown()
    }

    func testLegacyKeyListCoversEveryOldIOSSetting() {
        XCTAssertEqual(
            Set(AppSettings.legacySpeechDefaultsKeys),
            ["smartCleanupEnabled", "promptEnhancementEnabled", "bedrockRegion", "bedrockBearerToken",
             "continuousListeningEnabled", "wakeWord", "speechModelStore.whisperDownloaded"]
        )
        XCTAssertEqual(AppSettings.speechRemovalMigrationKey, "speechRemovalMigrationDone")
        XCTAssertEqual(AppSettings.legacySpeechModelsDirectory.lastPathComponent, "Models")
    }

    func testOneLaunchScrubsOldKeysDirectoryAndBedrockSecret() throws {
        for key in AppSettings.legacySpeechDefaultsKeys { defaults.set("x", forKey: key) }
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        var deleteCalls = 0

        let ok = AppSettings.migrateSpeechRemoval(
            defaults: defaults, modelsDirectory: modelsDir, deleteBedrockToken: { deleteCalls += 1 }
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(deleteCalls, 1)
        for key in AppSettings.legacySpeechDefaultsKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsDir.path))
        XCTAssertTrue(defaults.bool(forKey: AppSettings.speechRemovalMigrationKey))
        XCTAssertFalse(AppSettings.migrateSpeechRemoval(defaults: defaults, modelsDirectory: modelsDir, deleteBedrockToken: { deleteCalls += 1 }))
        XCTAssertEqual(deleteCalls, 1, "second launch is a no-op")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -skipMacroValidation -only-testing:CodeRelayAppTests/AppSettingsSpeechRemovalTests 2>&1 | grep -E "error:|Executed|BUILD" | tail -5`
Expected: compile error — `migrateSpeechRemoval` does not exist.

- [ ] **Step 3: Rewrite `CodeRelayApp/Models/AppSettings.swift`**

Keep every non-speech property exactly as it is (`hapticFeedbackEnabled`, `pushNotificationsEnabled`, `pushNotifyOnFinished`, `autoConnectEnabled`, `lastConnectedServerId`, `sessionNamingTheme`, `terminalFontSize`, `terminalScrollbackLines`, `recordingShortcutEnabled`, `recordingShortcutFlags`, `recordingShortcutKey`, `migrateShortcutIfNeeded()`, the `UIKeyModifierFlags.symbolString` / `shortcutModifierFlags` / `shortcutDisplayString` helpers — `ModifierFlags`-style tests depend on these names). Remove: `import CodeRelaySpeech`; `smartCleanupEnabled`, `promptEnhancementEnabled`, `bedrockRegion`, `bedrockBearerToken`, `bedrockTokenSubscriptions`, `bedrockDebounce`, `legacyBedrockKey`, `migrateBedrockTokenIfNeeded()`, `migrateBedrockToken(...)`, `loadBedrockToken(...)`, `continuousListeningEnabled`, `wakeWord`, `currentSpeechOptions()`, and the Bedrock `sink` in `init`. Add:

```swift
    // MARK: - Prompt optimizer (spec §7.1)

    /// Sent as `shareScreen` on every `optimize_prompt`. Per device, default on.
    @AppStorage("shareScreenWithOptimizer") var shareScreenWithOptimizer = true

    // MARK: - Speech-removal migration (spec §7.2)

    static let speechRemovalMigrationKey = "speechRemovalMigrationDone"

    /// Every `@AppStorage` key the speech feature ever wrote on iOS, plus the
    /// old `SpeechModelStore` ready flag.
    static let legacySpeechDefaultsKeys = [
        "smartCleanupEnabled",
        "promptEnhancementEnabled",
        "bedrockRegion",
        "bedrockBearerToken",
        "continuousListeningEnabled",
        "wakeWord",
        "speechModelStore.whisperDownloaded",
    ]

    /// Where `SpeechModelStore` kept downloaded Whisper/LLM weights on iOS.
    static var legacySpeechModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Models", isDirectory: true)
    }

    /// iOS wiring of the shared one-time cleanup (see `SpeechRemovalMigration`).
    @discardableResult
    static func migrateSpeechRemoval(
        defaults: UserDefaults,
        modelsDirectory: URL,
        deleteBedrockToken: () throws -> Void
    ) -> Bool {
        SpeechRemovalMigration.run(
            defaults: defaults,
            doneKey: speechRemovalMigrationKey,
            legacyKeys: legacySpeechDefaultsKeys,
            modelsDirectory: modelsDirectory,
            deleteBedrockToken: deleteBedrockToken
        )
    }
```

and in `init`, where `migrateBedrockTokenIfNeeded()` used to be called, call:

```swift
        AppSettings.migrateSpeechRemoval(
            defaults: .standard,
            modelsDirectory: AppSettings.legacySpeechModelsDirectory,
            deleteBedrockToken: { try AuthManager.shared.deleteBedrockToken() }
        )
```

`AuthManager.deleteBedrockToken()` is already `throws` (see `AuthManager.swift:139`).

- [ ] **Step 4: Rewrite `SettingsView.swift`**

Delete the "Speech to Text" section (:16–36), the "AWS Bedrock" section (:38–55) and `speechFooterText` (:190–197). Replace the `Section("General") { ... }` (:78–100) header/footer form so the toggle sits inside it:

```swift
            Section {
                // ...existing General rows unchanged...
                Toggle(OptimizerStrings.shareScreenToggle, isOn: $settings.shareScreenWithOptimizer)
            } header: {
                Text("General")
            } footer: {
                Text(OptimizerStrings.shareScreenFooter)
            }
```

Add `import CodeRelayClient` at the top if it is not already imported. In the shortcut section change `Toggle("Recording Shortcut", …)` (:103) to `Toggle("Optimizer Shortcut", …)` and the footer (:155) to `"Press \(settings.shortcutDisplayString) to optimize the prompt when a hardware keyboard is connected."` (keep the existing interpolation expression exactly as it is; only the surrounding words change).

- [ ] **Step 5: Rewire `ActiveTerminalView.swift`**

- Remove `import CodeRelaySpeech` (:4).
- Remove `speechEngine` and `continuousEngine` (:22–26); keep `@ObservedObject private var settings = AppSettings.shared` (:27).
- Remove `.onAppear { speechEngine.preloadInBackground() }` (:61–63).
- In the floating `HStack(spacing: 10)` (:65–101) replace the `MicButton(...)` call (:67–72) with:

```swift
                    WandButton(
                        coordinator: coordinator,
                        shareScreen: settings.shareScreenWithOptimizer,
                        size: 44,
                        fill: Color.gray.opacity(0.5),
                        onTap: {
                            if settings.hapticFeedbackEnabled {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        }
                    )
```

  (`coordinator` is the `SessionCoordinator` the view already observes; it is a `SharedSessionCoordinator` subclass so it passes directly.) The keyboard toggle button that follows stays untouched.
- Remove the "Speech Error" alert (:199–210), the `.task(id: optionsHash)` continuous-listening block (:223–235) and `optionsHash` (:247–255).
- In `extension Notification.Name` (:433–437) delete `toggleSpeechRecording`; keep `terminalRequestFocus` and `terminalResignFocus`.

- [ ] **Step 6: Repurpose the hardware shortcut in `CodeRelayApp/Views/Components/RelayTerminalView.swift`**

At :85–98 keep the `UserDefaults` reads (`recordingShortcutEnabled`, `recordingShortcutKey`, `recordingShortcutFlags`) and the `UIKeyCommand` construction, but change `discoverabilityTitle = "Toggle Recording"` to `discoverabilityTitle = "Optimize Prompt"` and the selector target to `#selector(handleOptimizeShortcut)`. Replace :103–105 with:

```swift
    /// Hardware-keyboard shortcut → the wand (spec §7.2). The storage keys keep
    /// their `recordingShortcut*` names so users' existing bindings survive.
    @objc private func handleOptimizeShortcut() {
        NotificationCenter.default.post(name: .optimizePromptShortcut, object: nil)
    }
```

Add `import CodeRelayClient` if the file lacks it.

- [ ] **Step 7: Clean `CodeRelayApp.swift`**

Remove `import CodeRelaySpeech` (:6), the `preloadTask` `@State`, the `.task { … preloadSpeechModels() … }` / `.onDisappear { preloadTask?.cancel() }` pair (:94–98) and `preloadSpeechModels()` (:143–160).

- [ ] **Step 8: Delete the files**

```bash
git rm CodeRelayApp/Views/Components/MicButton.swift \
  CodeRelayAppTests/AppSettingsBedrockTests.swift CodeRelayAppTests/MockSpeechComponents.swift \
  CodeRelayAppTests/AppSettingsContinuousTests.swift CodeRelayAppTests/SpeechEngineStateTests.swift \
  CodeRelayAppTests/OnDeviceSpeechEngineTests.swift CodeRelayAppTests/WhisperHallucinationTests.swift \
  CodeRelayAppTests/TextCleanerStaticTests.swift
```

Then `grep -rn "CodeRelaySpeech\|toggleSpeechRecording\|speechEngine\|continuousEngine\|MicButton\|bedrock\|wakeWord\|smartCleanup\|promptEnhancement" CodeRelayApp CodeRelayAppTests` must print nothing except the `legacySpeechDefaultsKeys` literals and the migration test.

- [ ] **Step 9: Build and test the iOS app**

Run: `xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -skipMacroValidation 2>&1 | grep -E "error:|Executed|TEST" | tail -8`
Expected: `** TEST SUCCEEDED **`; `AppSettingsSpeechRemovalTests` 2 tests, 0 failures; the retained `AlertFieldSelectionTests`, `TerminalScrollSyncTests`, `TerminalSwipeScrollTests` still pass.

- [ ] **Step 10: Commit**

```bash
git add CodeRelayApp/Models/AppSettings.swift CodeRelayApp/Views/ActiveTerminalView.swift CodeRelayApp/Views/Components/RelayTerminalView.swift CodeRelayApp/CodeRelayApp.swift CodeRelayApp/Views/SettingsView.swift CodeRelayAppTests/AppSettingsSpeechRemovalTests.swift
git commit -m "feat(ios): replace the mic with the prompt-optimizer wand; scrub speech settings on first launch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

(The `git rm` in Step 8 already staged the deletions.)

---

### Task 5: macOS — remove speech, wire the wand, migrate settings, drop the mic entitlement

**Files:**
- Delete: `CodeRelayMacTests/AppSettingsBedrockTests.swift`
- Modify: `CodeRelayMac/Models/AppSettings.swift` (whole file), `CodeRelayMac/Views/MainWindow.swift` (:4, :7–11, :176, :285–293, :403–606), `CodeRelayMac/Helpers/RecordingShortcutMonitor.swift` (whole file, 64 lines), `CodeRelayMac/AppDelegate.swift` (:5, :43–45), `CodeRelayMac/Views/SettingsView.swift` (:4, :22–30, :114–149, :151, :202, :325–447), `CodeRelayMac/CodeRelayMac.entitlements` (:7–8)
- Create: `CodeRelayMacTests/AppSettingsSpeechRemovalTests.swift`

**Interfaces:**
- Consumes: `WandButton`, `SpeechRemovalMigration.run(...)` (Task 3), coordinator optimizer API (Task 2), `OptimizerStrings`, `.optimizePromptShortcut` (Task 1), `AuthManager.shared.deleteBedrockToken()`.
- Produces: `AppSettings.shareScreenWithOptimizer` (`@AppStorage("com.clauderelay.mac.shareScreenWithOptimizer")`, default `true`); `static func migrateSpeechRemoval(defaults:modelsDirectory:deleteBedrockToken:) -> Bool`; `static let speechRemovalMigrationKey = "com.clauderelay.mac.speechRemovalMigrationDone"`; `static let legacySpeechDefaultsKeys: [String]`; `static var legacySpeechModelsDirectory: URL`. `RecordingShortcutMonitor` keeps its name, `shared`, `start()`, `stop()`; `Notification.Name.showServerList` / `.connectToServer` stay in its file.

`project.yml` is untouched here (Task 6 removes the `CodeRelaySpeech` product and `NSMicrophoneUsageDescription`).

- [ ] **Step 1: Write the failing migration tests**

```swift
// CodeRelayMacTests/AppSettingsSpeechRemovalTests.swift
import XCTest
// Module is c99-sanitized from PRODUCT_NAME "Code[Relay]" — see project.yml.
@testable import Code_Relay_

/// The macOS wiring of the shared `SpeechRemovalMigration` (spec §7.2 / §11).
/// The helper's edge cases are covered in `SpeechRemovalMigrationTests`
/// (CodeRelayClientTests).
@MainActor
final class AppSettingsSpeechRemovalTests: XCTestCase {

    private var defaults: UserDefaults!
    private var modelsDir: URL!

    override func setUp() {
        super.setUp()
        let suite = "AppSettingsSpeechRemovalTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        modelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRemoval-\(UUID().uuidString)/ClaudeRelay/Models", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: modelsDir.deletingLastPathComponent().deletingLastPathComponent())
        defaults = nil
        super.tearDown()
    }

    func testLegacyKeyListCoversEveryOldMacSetting() {
        XCTAssertEqual(
            Set(AppSettings.legacySpeechDefaultsKeys),
            ["com.clauderelay.mac.smartCleanupEnabled", "com.clauderelay.mac.promptEnhancementEnabled",
             "com.clauderelay.mac.continuousListeningEnabled", "com.clauderelay.mac.wakeWord",
             "com.clauderelay.mac.bedrockRegion", "com.clauderelay.mac.bedrockBearerToken",
             "com.clauderelay.mac.whisperDownloaded"]
        )
        XCTAssertEqual(AppSettings.speechRemovalMigrationKey, "com.clauderelay.mac.speechRemovalMigrationDone")
        XCTAssertEqual(
            Array(AppSettings.legacySpeechModelsDirectory.pathComponents.suffix(2)),
            ["ClaudeRelay", "Models"]
        )
    }

    func testOneLaunchScrubsOldKeysDirectoryAndBedrockSecret() throws {
        for key in AppSettings.legacySpeechDefaultsKeys { defaults.set("x", forKey: key) }
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        var deleteCalls = 0

        let ok = AppSettings.migrateSpeechRemoval(
            defaults: defaults, modelsDirectory: modelsDir, deleteBedrockToken: { deleteCalls += 1 }
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(deleteCalls, 1)
        for key in AppSettings.legacySpeechDefaultsKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsDir.path))
        XCTAssertTrue(defaults.bool(forKey: AppSettings.speechRemovalMigrationKey))
        XCTAssertFalse(AppSettings.migrateSpeechRemoval(defaults: defaults, modelsDirectory: modelsDir, deleteBedrockToken: { deleteCalls += 1 }))
        XCTAssertEqual(deleteCalls, 1, "second launch is a no-op")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayMac -destination 'platform=macOS' -skipMacroValidation -only-testing:CodeRelayMacTests/AppSettingsSpeechRemovalTests 2>&1 | grep -E "error:|Executed|BUILD" | tail -5`
Expected: compile error — `migrateSpeechRemoval` does not exist.

- [ ] **Step 3: Rewrite `CodeRelayMac/Models/AppSettings.swift`**

Keep unchanged: `lastServerId`, `hapticFeedbackEnabled`, `showWindowOnLaunch`, `sessionNamingTheme`, `launchAtLoginEnabled`, `autoConnectEnabled`, `pushNotificationsEnabled`, `pushNotifyOnFinished`, `terminalFontSize`, `terminalScrollbackLines`, `recordingShortcutEnabled`, `recordingShortcutModifiers`, `recordingShortcutKey`, and the `NSEvent.ModifierFlags.symbolString` / `shortcutModifierFlags` / `shortcutDisplayString` helpers (`ModifierFlagsTests` uses them). Remove: `import CodeRelaySpeech` (:4); `legacyBedrockKey`, `migrateBedrockTokenIfNeeded()`, `loadBedrockTokenWithFallback()`, `migrateBedrockToken(...)`, `loadBedrockToken(...)` (:27–80); the five speech `@AppStorage`s (:99–103); `bedrockBearerToken` + its `bedrockTokenSubscriptions` sink (:109 and the `init` body that seeds/saves it); `currentSpeechOptions()` (:126+). Add:

```swift
    // MARK: - Prompt optimizer (spec §7.1)

    /// Sent as `shareScreen` on every `optimize_prompt`. Per device, default on.
    @AppStorage("com.clauderelay.mac.shareScreenWithOptimizer") var shareScreenWithOptimizer = true

    // MARK: - Speech-removal migration (spec §7.2)

    static let speechRemovalMigrationKey = "com.clauderelay.mac.speechRemovalMigrationDone"

    /// Every `@AppStorage` key the speech feature ever wrote on macOS, plus the
    /// old `SpeechModelStore` ready flag.
    static let legacySpeechDefaultsKeys = [
        "com.clauderelay.mac.smartCleanupEnabled",
        "com.clauderelay.mac.promptEnhancementEnabled",
        "com.clauderelay.mac.continuousListeningEnabled",
        "com.clauderelay.mac.wakeWord",
        "com.clauderelay.mac.bedrockRegion",
        "com.clauderelay.mac.bedrockBearerToken",
        "com.clauderelay.mac.whisperDownloaded",
    ]

    /// Where `SpeechModelStore` kept downloaded weights on macOS.
    static var legacySpeechModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClaudeRelay", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// macOS wiring of the shared one-time cleanup (see `SpeechRemovalMigration`).
    @discardableResult
    static func migrateSpeechRemoval(
        defaults: UserDefaults,
        modelsDirectory: URL,
        deleteBedrockToken: () throws -> Void
    ) -> Bool {
        SpeechRemovalMigration.run(
            defaults: defaults,
            doneKey: speechRemovalMigrationKey,
            legacyKeys: legacySpeechDefaultsKeys,
            modelsDirectory: modelsDirectory,
            deleteBedrockToken: deleteBedrockToken
        )
    }
```

In `init`, where `migrateBedrockTokenIfNeeded()` was called, call:

```swift
        AppSettings.migrateSpeechRemoval(
            defaults: .standard,
            modelsDirectory: AppSettings.legacySpeechModelsDirectory,
            deleteBedrockToken: { try AuthManager.shared.deleteBedrockToken() }
        )
```

If nothing else remains in `init` besides this call and `super`-less setup, keep the `init` — the migration must still run once per launch on `AppSettings.shared`.

- [ ] **Step 4: Rewrite `CodeRelayMac/Views/SettingsView.swift`**

- Remove `import CodeRelaySpeech` (:4).
- In the `TabView` (:22–30) delete the `SpeechSettingsTab().tabItem { Label("Speech", systemImage: "mic") }` entry (:26–27).
- Delete `SpeechSettingsTab` entirely (:325–447).
- In `GeneralSettingsTab`, directly after the "Appearance" `SettingsGroup` (after :149) insert:

```swift
                SettingsSectionHeader(title: "Prompt Optimizer")
                SettingsGroup {
                    SettingsGroupRow(showDivider: false) {
                        Text(OptimizerStrings.shareScreenToggle)
                        Spacer()
                        Toggle("", isOn: $settings.shareScreenWithOptimizer)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                SettingsSectionFooter(text: OptimizerStrings.shareScreenFooter)
```

  (Same row shape as the "Notifications" group at :205–224: label, `Spacer`, hidden-label switch; the footer sits *outside* the group.)
- Rename the section header at :151 from `"Recording Shortcut"` to `"Optimizer Shortcut"`, and the footer string at :202 from `"Press \(settings.shortcutDisplayString) to toggle speech recording."` to `"Press \(settings.shortcutDisplayString) to optimize the prompt."`.

- [ ] **Step 5: Rewire `MainWindow.swift`**

- Remove `import CodeRelaySpeech` (:4) and the `speechEngine` / `continuousEngine` state (:7–10); keep `settings` (:11).
- Replace `micToolbarButton` (:285–293) with:

```swift
    private var wandToolbarButton: some View {
        WandButton(
            coordinator: coordinator,
            shareScreen: settings.shareScreenWithOptimizer,
            size: 26,
            fill: Color.gray.opacity(0.5)
        )
    }
```

  `Color.gray.opacity(0.5)` is the fill `MacMicButton` used in its idle state (:581), so the toolbar's look does not change. Change the `ToolbarItem(placement: .primaryAction) { micToolbarButton }` at :176 to `{ wandToolbarButton }`. `coordinator` there is the unwrapped `SessionCoordinator` (a `SharedSessionCoordinator` subclass) that `MainWindow` already passes to the old button.
- Delete `private struct MacMicButton` (:403–606).

- [ ] **Step 6: Repurpose `RecordingShortcutMonitor.swift`**

Replace the file's contents with (the matching logic is the existing one verbatim; only the doc comment, the log line, the posted notification and the `Notification.Name` extension change):

```swift
import AppKit
import CodeRelayClient

/// Posts `.optimizePromptShortcut` when the user's configured shortcut is pressed
/// (spec §7.2 — the former speech-recording shortcut now triggers the wand; the
/// class and the `recordingShortcut*` settings keep their names so existing
/// bindings survive the upgrade).
///
/// Uses a local `NSEvent.addLocalMonitorForEvents` monitor, which fires BEFORE
/// `performKeyEquivalent:` dispatches menu shortcuts. That means the configured
/// shortcut can use any modifier+letter combo, including ones that collide with
/// menu commands — our monitor sees and consumes them first.
///
/// The monitor is paused whenever `KeyCaptureInterceptor` is mid-capture (so the
/// user's key presses during the "Change" flow don't trigger the optimizer).
@MainActor
final class RecordingShortcutMonitor {
    static let shared = RecordingShortcutMonitor()

    private var monitor: Any?

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        NSLog("[RecordingShortcut] monitor installed")
    }

    func stop() {
        if let current = monitor {
            NSEvent.removeMonitor(current)
            monitor = nil
            NSLog("[RecordingShortcut] monitor removed")
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Skip while KeyCapture is active to avoid triggering during 'Change shortcut' flow
        if KeyCaptureInterceptor.shared.isActive { return event }

        let settings = AppSettings.shared
        guard settings.recordingShortcutEnabled else { return event }

        let savedKey = settings.recordingShortcutKey.lowercased()
        guard !savedKey.isEmpty else { return event }

        let savedMods = settings.shortcutModifierFlags.intersection([.command, .option, .shift, .control])
        let eventMods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let eventKey = event.charactersIgnoringModifiers?.lowercased() ?? ""

        guard eventKey == savedKey, eventMods == savedMods else { return event }

        NSLog("[RecordingShortcut] matched — posting optimizePromptShortcut")
        NotificationCenter.default.post(name: .optimizePromptShortcut, object: nil)
        return nil // consume
    }
}

extension Notification.Name {
    static let showServerList = Notification.Name("com.coderelay.mac.showServerList")
    static let connectToServer = Notification.Name("com.coderelay.mac.connectToServer")
}
```

- [ ] **Step 7: Clean `AppDelegate.swift`**

Remove `import CodeRelaySpeech` (:5) and the `applicationWillTerminate` body that calls `TextCleaner.shared.unload()` (:43–45). If that leaves an empty method, delete the method and its doc comment. `RecordingShortcutMonitor.shared.start()` (:59) stays.

- [ ] **Step 8: Remove the microphone entitlement**

In `CodeRelayMac/CodeRelayMac.entitlements` delete the pair

```xml
    <key>com.apple.security.device.audio-input</key>
    <true/>
```

(:7–8). All other keys stay.

- [ ] **Step 9: Delete the old test and grep**

```bash
git rm CodeRelayMacTests/AppSettingsBedrockTests.swift
grep -rn "CodeRelaySpeech\|toggleSpeechRecording\|speechEngine\|continuousEngine\|MacMicButton\|bedrock\|wakeWord\|smartCleanup\|promptEnhancement\|TextCleaner\|audio-input" CodeRelayMac CodeRelayMacTests
```

Expected grep output: only the `legacySpeechDefaultsKeys` literals in `AppSettings.swift` and the migration test.

- [ ] **Step 10: Build and test the macOS app**

Run: `xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayMac -destination 'platform=macOS' -skipMacroValidation 2>&1 | grep -E "error:|Executed|TEST" | tail -8`
Expected: `** TEST SUCCEEDED **`; `AppSettingsSpeechRemovalTests` 2 tests, 0 failures; `AddEditServerViewModelTests`, `MenuBarActivityTests`, `ModifierFlagsTests`, `SessionNavigationTests` still pass.

- [ ] **Step 11: Commit**

```bash
git add CodeRelayMac/Models/AppSettings.swift CodeRelayMac/Views/MainWindow.swift CodeRelayMac/Helpers/RecordingShortcutMonitor.swift CodeRelayMac/AppDelegate.swift CodeRelayMac/Views/SettingsView.swift CodeRelayMac/CodeRelayMac.entitlements CodeRelayMacTests/AppSettingsSpeechRemovalTests.swift
git commit -m "feat(mac): replace the mic with the prompt-optimizer wand; scrub speech settings; drop audio-input entitlement

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Delete `CodeRelaySpeech`, its dependencies, the mic Info.plist keys, and the CI pin-restore hack

**Files:**
- Delete: `Sources/CodeRelaySpeech/` (22 Swift files, `CLAUDE.md`, `Resources/{SileroVAD.mlmodelc,SmartTurnV3.mlpackage,WhisperLogMel8s.mlpackage}`), `Tests/CodeRelaySpeechTests/` (17 files + `Fixtures/`)
- Modify: `Package.swift` (:4–7, :105–147), `Package.resolved` and `CodeRelay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (both drop the `llm.swift`, `swift-syntax`, `whisperkit` pins), `project.yml` (:29, :41–42, :78, :101, :116, :145, :164), `CodeRelay.xcodeproj/project.pbxproj` (regenerated), `.github/workflows/ci.yml` (:21, :30–31, :87–96, :104), `.github/workflows/release.yml` (:84–90, :274–275), `Sources/CodeRelayClient/AuthManager.swift` (:107–143), `Tests/CodeRelayClientTests/AuthManagerTests.swift` (:65–105, :114–121)

**Interfaces:**
- Produces: `AuthManager.deleteBedrockToken() throws` remains public (the migration in Tasks 4/5 calls it forever); `static let bedrockAccount = "com.clauderelay.bedrock.bearerToken"` becomes internal so the test can seed the entry. `saveBedrockToken`/`loadBedrockToken` are gone.

- [ ] **Step 1: Update `AuthManagerTests.swift` first (failing)**

Delete `testBedrockTokenSaveAndLoad`, `testBedrockTokenLoadReturnsNilWhenMissing`, `testBedrockTokenSaveEmptyDeletes`, `testBedrockTokenOverwrite`, `testBedrockTokenIsolatedFromPerConnectionTokens` (:65–105, keep `testBedrockTokenDeleteIsIdempotent`). In the error-propagation tests (:114–121) drop the `loadBedrockToken`/`saveBedrockToken` lines and keep only the `deleteBedrockToken` expectation with the throwing store. Add:

```swift
    /// A pre-upgrade install has the Bedrock secret under the fixed account;
    /// the migration's delete must actually remove it, not just not throw.
    func testDeleteBedrockTokenRemovesTheLegacySecret() throws {
        let service = "com.coderemote.relay" // AuthManager's private keychain service
        try keychain.add(service: service, account: AuthManager.bedrockAccount, data: Data("old-secret".utf8))
        try manager.deleteBedrockToken()
        XCTAssertNil(try keychain.get(service: service, account: AuthManager.bedrockAccount))
    }
```

`KeychainStoring` is `add(service:account:data:)` / `get(service:account:) -> Data?` (`AuthManager.swift:7–16`); `InMemoryKeychainStore` at the bottom of `AuthManagerTests.swift` implements it.

Run: `swift test --filter AuthManagerTests 2>&1 | tail -5; echo EXIT=${pipestatus[1]}`
Expected: compile error — `bedrockAccount` is private.

- [ ] **Step 2: Trim `AuthManager.swift`**

Replace :107–143 with:

```swift
    // MARK: - Legacy Bedrock secret

    /// Keychain account the removed speech feature used for its AWS Bedrock
    /// bearer token. Kept only so `deleteBedrockToken()` can scrub it on the
    /// first launch after the upgrade (spec §7.2); nothing writes it anymore.
    static let bedrockAccount = "com.clauderelay.bedrock.bearerToken"

    /// Removes the legacy Bedrock token. Idempotent — a missing item is not an error.
    public func deleteBedrockToken() throws {
        // keep the existing body of the old deleteBedrockToken() here verbatim
    }
```

Delete `saveBedrockToken(_:)` and `loadBedrockToken()`.

Run: `swift test --filter AuthManagerTests 2>&1 | tail -5; echo EXIT=${pipestatus[1]}`
Expected: 0 failures, `EXIT=0`.

- [ ] **Step 3: Remove the speech package target**

```bash
git rm -r Sources/CodeRelaySpeech Tests/CodeRelaySpeechTests
```

Edit `Package.swift`:
- Header comment (:4–7): drop the sentences about `CodeRelaySpeech` / WhisperKit / LLM.swift; the Apple-only conditional now guards `CodeRelayClient` alone.
- Inside `if buildsAppleClients {` (:105): remove the `CodeRelaySpeech` product (:108), the WhisperKit and LLM.swift `package.dependencies.append(...)` lines (:111–112), the `CodeRelaySpeech` target (:121–130) and `CodeRelaySpeechTests` target (:139–144). Keep `CodeRelayClient`, `CodeRelayClientTests`, and `serverTestDependencies.append("CodeRelayClient")`.
- The `else { serverTestExcludes ... }` branch (:147): remove any exclude that names a CodeRelaySpeech path; keep the client ones.

Edit `Package.resolved`: remove the `llm.swift`, `swift-syntax`, and `whisperkit` pin objects (keep valid JSON; run `swift package resolve` afterwards and confirm `git diff --stat Package.resolved` shows only those three removals and no new pins).

Run: `swift build 2>&1 | tail -3; echo EXIT=${pipestatus[1]}` → `Build complete!`, `EXIT=0`.
Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1; echo EXIT=${pipestatus[1]}` → 0 failures, `EXIT=0`. Record the new test count for the docs task (it was 1469 with CodeRelaySpeech).

- [ ] **Step 4: Drop the speech product and mic strings from `project.yml`, regenerate**

Remove these lines from `project.yml`:
- `CodeRelayApp` dependencies: the `- package: CodeRelayClient` / `product: CodeRelaySpeech` pair (:28–29).
- `CodeRelayApp` settings: `INFOPLIST_KEY_NSMicrophoneUsageDescription` (:41) and `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` (:42).
- `CodeRelayAppTests` dependencies: the `CodeRelaySpeech` pair (:77–78).
- `CodeRelayMac` dependencies: the `CodeRelaySpeech` pair (:100–101); settings `INFOPLIST_KEY_NSMicrophoneUsageDescription` (:116); `info.properties` `NSMicrophoneUsageDescription` (:145).
- `CodeRelayMacTests` dependencies: the `CodeRelaySpeech` pair (:163–164).

Do not touch `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`. Then:

```bash
/opt/homebrew/bin/xcodegen generate
xcodebuild -resolvePackageDependencies -project CodeRelay.xcodeproj -scheme CodeRelayMac 2>&1 | tail -2
grep -c "CodeRelaySpeech\|NSMicrophoneUsageDescription\|NSSpeechRecognitionUsageDescription" project.yml CodeRelay.xcodeproj/project.pbxproj
grep -c "whisperkit\|llm.swift\|swift-syntax" CodeRelay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

Expected: `0` for all three greps. The workspace `Package.resolved` is tracked and pins the same three packages; the resolve step drops them (if it does not, delete the three pin objects by hand — same edit as Step 3). Stage it with the commit in Step 6.

Run both app test suites (commands in Global Constraints) → `** TEST SUCCEEDED **` twice.

- [ ] **Step 5: CI — replace the pin-restore step with a diff check**

`.github/workflows/ci.yml`:
- :21 — delete "(incl. the WhisperKit/swift-syntax compile)".
- :30–31 — delete the swift-syntax/WhisperKit comment lines.
- :87–96 — replace the "Package.resolved is unchanged (macOS superset preserved)" step (the `git checkout -- Package.resolved` + pin loop) with:

```yaml
      - name: Package.resolved is unchanged after the Linux resolve
        run: git diff --exit-code -- Package.resolved
```

- :104 — delete the LLM.swift macro comment. Keep `-skipMacroValidation` on the xcodebuild lines (:134/:172); it is harmless and out of scope here.

`.github/workflows/release.yml`:
- :84–90 — delete the comment paragraph about CodeRelaySpeech → WhisperKit.
- :274–275 — replace the restore step with the same `git diff --exit-code -- Package.resolved` step.

Run: `grep -n "WhisperKit\|whisperkit\|swift-syntax\|LLM.swift\|CodeRelaySpeech" .github/workflows/*.yml` → no output.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved project.yml CodeRelay.xcodeproj/project.pbxproj CodeRelay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved .github/workflows/ci.yml .github/workflows/release.yml Sources/CodeRelayClient/AuthManager.swift Tests/CodeRelayClientTests/AuthManagerTests.swift
git commit -m "chore: remove CodeRelaySpeech, WhisperKit and LLM.swift; drop mic usage strings and the CI pin-restore step

Package.resolved no longer needs a macOS superset: CI now fails if the Linux
resolve changes it. AuthManager keeps deleteBedrockToken() for the one-time
migration.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

(The `git rm -r` in Step 3 already staged the deletions.) Spec §8 asks Plan 2 to resolve on both platforms and diff before the restore step is deleted. Docker is not available on this machine, so the Linux half of that check is the `linux-server` CI job: push the branch after this commit (`git push -u origin feat/prompt-optimizer-apple-clients`) and confirm that job's new `Package.resolved is unchanged` step passes. The branch's CI must be green before Task 7 is considered done; if the diff step fails, the Linux resolve still differs and the fix is in `Package.swift` (a dependency still declared conditionally), not in the CI step.

---

### Task 7: Documentation

**Files:**
- Modify: `CLAUDE.md` (:28, :32, :50–51, :198, :239–241, :245–248, :257), `README.md` (:22–24, :39, :45, :313–315, :355, :379–380, :475), `CodeRelayApp/README.md` (:51, :57, :64–65, :67–70), `CodeRelayMac/README.md` (:3, :57, :92, :103, :109–111, :120, :127), `docs/linux-server-spec.md` (:27, :59, :71, :474), `docs/android-parity-audit.md` (Apple-side speech rows only)
- Modify (one header line each): `docs/superpowers/specs/2026-04-10-on-device-speech-engine-design.md`, `docs/superpowers/specs/2026-04-10-settings-prompt-improvement-design.md`, `docs/superpowers/specs/2026-05-08-continuous-voice-input-design.md`, `docs/superpowers/specs/2026-05-08-continuous-voice-v2-design.md`, `docs/superpowers/plans/2026-04-10-on-device-speech-engine.md`, `docs/superpowers/plans/2026-05-08-continuous-voice-input.md`, `docs/superpowers/plans/2026-05-08-continuous-voice-v2.md`

Leave alone: `README.md:16`, `:371` and `docs/linux-client-spec.md` (Android/Linux speech — Plans 3/4 own them); `docs/herdr-feature-spec.md` (spec §8 lists it, but `grep -niE "speech|whisper|dictat|microphone|voice|bedrock"` finds nothing in it) and `docs/claude-code-recommendations.md` (its only hit, :191 "Voice-typo tolerance", is about dictation typos in general and stays true with system dictation); `docs/superpowers/plans/2026-06-06-android-relay-client-m3-speech.md` (Plan 3).

- [ ] **Step 1: `CLAUDE.md`**

- :28 — rewrite the iOS-app note as: `**iOS app**: Open \`CodeRelay.xcodeproj\` in Xcode, Cmd+R. After changing CodeRelayClient or CodeRelayKit sources, rebuild the iOS app in Xcode to pick up changes.`
- :32 — in the Linux-server paragraph: change "the two Apple client libraries (`CodeRelayClient`, `CodeRelaySpeech`) and their deps (WhisperKit, LLM.swift) are not declared" to "the Apple client library (`CodeRelayClient`) is not declared"; replace the test count with the number recorded in Task 6 Step 3; delete the sentence beginning "**Do not commit a Linux-resolved `Package.resolved`**" through "(CI restores it)." and replace it with "CI fails if the Linux resolve changes `Package.resolved`."
- :50–51 — the architecture bullet list: change "Six SPM targets" to "Five SPM targets", delete the `CodeRelaySpeech` bullet, and change the `CodeRelayApp/` bullet to "Depends on CodeRelayClient + SwiftTerm."
- :198 — delete the `AudioCaptureSession.maximumDuration` memory-bounds bullet.
- :239–241 — delete the "### Speech Layer Concurrency" section (heading + both paragraphs).
- :245–248 — delete the "### Continuous Listening Pipeline" section.
- :257 — in the App-side settings paragraph delete the sentence about continuous-listening settings and `turnEndSilenceTimeout`; append: "`shareScreenWithOptimizer` (per device, default on) is sent as `shareScreen` on every `optimize_prompt`."
- Add, after the "Key Pattern: sendAndWaitForResponse" section, a short section:

```markdown
### Prompt Optimizer (client side)

The magic-wand button (`WandButton` in CodeRelayClient, hosted by both apps
where the mic used to be) is a thin renderer over `SharedSessionCoordinator`'s
optimizer state: `optimizerAvailability` (derived from `auth_success`'s
`protocolVersion` and `capabilities` — the wand is dimmed and a tap shows the
config hint unless the relay advertises `prompt_optimizer` on protocol v2),
`optimizerState` (`optimizing` only for one RPC), `optimizerUndo` (10 s,
one-shot `replace_prompt` of the original) and `optimizerNotice` (4 s toast).
`optimize_prompt` / `replace_prompt` use a 20 s waiter
(`SessionController.optimizerTimeout`); everything else keeps 10 s. All copy is
in `OptimizerStrings`. The hardware shortcut (`recordingShortcut*` settings,
`RecordingShortcutMonitor` on macOS) now posts `.optimizePromptShortcut`.
Voice input is the OS's own dictation into the terminal; the apps no longer
ship a speech stack, and `SpeechRemovalMigration` scrubs the old settings,
the Bedrock keychain item and the model directory once per install.
```

- [ ] **Step 2: `README.md`**

At each of :22–24, :39, :45, :313–315, :355, :379–380, :475: replace the description of on-device voice transcription / Whisper / Bedrock enhancement on iOS and macOS with a mention of the prompt optimizer, and delete lines that only describe microphone permissions on those two apps. Add one paragraph (under the features section that :22–24 belongs to):

```markdown
**Prompt optimizer.** The wand button (or the keyboard shortcut you used for
recording) asks the relay to rewrite whatever you have typed at the agent's
input line into a well-structured coding-agent prompt. The relay types the
rewrite for you and never presses Enter; a 10-second Undo puts your original
back. Enable it on the relay with `claude-relay config set promptOptimizerEnabled true`
plus an API key file (see Configuration). To dictate, use your device's own
dictation into the terminal — the apps no longer ship a speech engine.
```

Do not touch :16 and :371 (Android).

- [ ] **Step 3: App READMEs**

`CodeRelayApp/README.md` :51, :57, :64–65, :67–70 and `CodeRelayMac/README.md` :3, :57, :92, :103, :109–111, :120, :127: delete the speech/Whisper/Bedrock/wake-word bullets and the microphone-permission notes; where a feature list mentions the mic button, replace it with one bullet: `- Prompt optimizer wand (server-side; needs \`promptOptimizerEnabled\` on the relay) with 10 s Undo`. In `CodeRelayMac/README.md` also update the shortcut bullet to say the shortcut triggers the optimizer.

- [ ] **Step 4: `docs/linux-server-spec.md` and `docs/android-parity-audit.md`**

- `docs/linux-server-spec.md` :27, :59, :71, :474: change every "CodeRelayClient and CodeRelaySpeech" / "WhisperKit, LLM.swift" phrasing to name only `CodeRelayClient`; where it explains the `Package.resolved` superset rule, replace it with "CI checks that the Linux resolve leaves `Package.resolved` unchanged."
- `docs/android-parity-audit.md`: in rows that compare Android speech against the iOS/macOS speech stack, change the iOS/macOS cell to "Removed — replaced by the server-side prompt optimizer (wand)". Leave the Android cells alone.

- [ ] **Step 5: Superseded headers**

Insert as line 3 (after the H1 and its blank line) of each of the seven superseded specs/plans listed in Files:

```markdown
> **Superseded (2026-09-14):** on-device voice transcription was removed from the iOS and macOS apps by `docs/superpowers/specs/2026-09-13-server-prompt-optimizer-design.md`. Kept for history only.
```

- [ ] **Step 6: Verify and commit**

```bash
grep -rn "CodeRelaySpeech\|WhisperKit\|wake word\|wake-word\|Bedrock" CLAUDE.md README.md CodeRelayApp/README.md CodeRelayMac/README.md docs/linux-server-spec.md | grep -v "promptOptimizerProvider\|bedrock\b.*optimizer\|Superseded"
```

Expected: only the prompt-optimizer `bedrock` provider lines in `CLAUDE.md`/`README.md` configuration sections.

```bash
git add CLAUDE.md README.md CodeRelayApp/README.md CodeRelayMac/README.md docs/linux-server-spec.md docs/android-parity-audit.md \
  docs/superpowers/specs/2026-04-10-on-device-speech-engine-design.md docs/superpowers/specs/2026-04-10-settings-prompt-improvement-design.md \
  docs/superpowers/specs/2026-05-08-continuous-voice-input-design.md docs/superpowers/specs/2026-05-08-continuous-voice-v2-design.md \
  docs/superpowers/plans/2026-04-10-on-device-speech-engine.md docs/superpowers/plans/2026-05-08-continuous-voice-input.md docs/superpowers/plans/2026-05-08-continuous-voice-v2.md
git commit -m "docs: Apple clients use the server prompt optimizer; speech stack removed

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Done criteria (spec §11, client rows)

- `swift build && swift test` green on macOS with no WhisperKit checkout in `.build/checkouts` (`ls .build/checkouts | grep -i whisper` prints nothing).
- Both Xcode app test suites green; iOS and macOS builds contain no `NSMicrophoneUsageDescription`.
- CI green on the branch, including the `linux-server` job's `Package.resolved` diff check.
- Manual smoke (not automatable here): against a relay with the optimizer enabled, tap the wand with a draft typed → the draft is rewritten in place and `Optimized · Undo` appears for 10 s; Undo restores the original byte-for-byte. Against a relay with it disabled, the wand is dimmed and a tap shows `Enable on the relay: claude-relay config set promptOptimizerEnabled true`.
