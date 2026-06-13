# Surface "Invalid token" & Stop the Reconnect Storm — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the server rejects a token as invalid, stop the silent auto-reconnect loop and show the user an actionable "Invalid token" message in both the workspace and the server list.

**Architecture:** The server already sends `auth_failure(reason:"Invalid token")` and the client already maps it to `SessionController.SessionError.authenticationFailed`. We add an `authRejected` terminal flag in `RecoveryController` that suppresses auto-recovery on the first auth rejection (cleared only by user-initiated retry), teach `ServerStatusChecker.probe` to distinguish a rejected token from an unreachable server via a `reachability` enum on `ServerStatus`, and add a friendly re-pair message for `authenticationFailed`.

**Tech Stack:** Swift 6, Swift Concurrency, XCTest, SwiftUI. Tests run via `swift test --filter ClaudeRelayClientTests`.

---

## File Structure

- `Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift` — add `Reachability` enum + `reachability` field to `ServerStatus`; classify `authenticationFailed` in `probe`.
- `Sources/ClaudeRelayClient/ViewModels/RecoveryController.swift` — add `authRejected` flag, gate auto-recovery on it, set it on auth-failure, clear it on user-initiated recovery; add test hooks.
- `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift` — add `authenticationFailed` case to `friendlyAttachErrorMessage`.
- `ClaudeRelayApp/Views/ServerListView.swift` — render `.invalidToken` distinctly (iOS dot + label).
- `ClaudeRelayMac/Views/ServerListWindow.swift` — pass invalid-token state through.
- `Tests/ClaudeRelayClientTests/RecoveryControllerTests.swift` — auth-rejection gating tests.
- `Tests/ClaudeRelayClientTests/ServerStatusCheckerTests.swift` (create) — probe classification tests.
- `Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift` (create or extend) — message mapping test.

---

## Task 1: Add `Reachability` to `ServerStatus`

**Files:**
- Modify: `Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift:3-8`
- Test: `Tests/ClaudeRelayClientTests/ServerStatusCheckerTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelayClientTests/ServerStatusCheckerTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayClient

@MainActor
final class ServerStatusCheckerTests: XCTestCase {

    func testDefaultStatusIsUnknownAndNotLive() {
        let status = ServerStatus()
        XCTAssertFalse(status.isLive)
        XCTAssertEqual(status.reachability, .unknown)
    }

    func testLiveStatusReportsLiveReachability() {
        let status = ServerStatus(isLive: true, reachability: .live)
        XCTAssertTrue(status.isLive)
        XCTAssertEqual(status.reachability, .live)
    }

    func testInvalidTokenStatusIsNotLive() {
        let status = ServerStatus(isLive: false, reachability: .invalidToken)
        XCTAssertFalse(status.isLive)
        XCTAssertEqual(status.reachability, .invalidToken)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ServerStatusCheckerTests`
Expected: FAIL — `ServerStatus` has no `reachability` member / initializer mismatch.

- [ ] **Step 3: Write minimal implementation**

Replace `ServerStatusChecker.swift:3-8` with:

```swift
public struct ServerStatus: Equatable {
    /// Coarse reachability classification, distinct from the boolean
    /// `isLive` so the UI can tell "server up but token rejected" apart
    /// from "server unreachable".
    public enum Reachability: Equatable {
        case unknown        // not yet probed
        case live           // reachable + token accepted
        case invalidToken   // reachable but auth rejected
        case unreachable    // could not connect / timed out
    }

    public var isLive: Bool = false
    public var reachability: Reachability = .unknown

    public init(isLive: Bool = false, reachability: Reachability = .unknown) {
        self.isLive = isLive
        self.reachability = reachability
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ServerStatusCheckerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift Tests/ClaudeRelayClientTests/ServerStatusCheckerTests.swift
git commit -m "feat(client): add Reachability to ServerStatus"
```

---

## Task 2: Classify auth rejection in `ServerStatusChecker.probe`

**Files:**
- Modify: `Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift:74-87`
- Test: `Tests/ClaudeRelayClientTests/ServerStatusCheckerTests.swift`

Note: `probe` makes a real network connection, so we don't unit-test it end to
end. Instead we extract the *error→status* mapping into a pure static helper
and test that. This keeps the test deterministic and offline.

- [ ] **Step 1: Write the failing test**

Append to `ServerStatusCheckerTests.swift` (inside the class):

```swift
    func testMapInvalidTokenError() {
        let err = SessionController.SessionError.authenticationFailed(reason: "Invalid token")
        let status = ServerStatusChecker.statusForProbeFailure(err)
        XCTAssertFalse(status.isLive)
        XCTAssertEqual(status.reachability, .invalidToken)
    }

    func testMapTimeoutErrorIsUnreachable() {
        let err = SessionController.SessionError.timeout
        let status = ServerStatusChecker.statusForProbeFailure(err)
        XCTAssertFalse(status.isLive)
        XCTAssertEqual(status.reachability, .unreachable)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ServerStatusCheckerTests`
Expected: FAIL — `statusForProbeFailure` not defined.

- [ ] **Step 3: Write minimal implementation**

Add this static helper to `ServerStatusChecker` (place it just above `probe`,
around line 58):

```swift
    /// Maps a probe failure to a status. `authenticationFailed` means the
    /// socket reached the server but the token was rejected — surface that
    /// distinctly from an unreachable server.
    static func statusForProbeFailure(_ error: Error) -> ServerStatus {
        if let sessionErr = error as? SessionController.SessionError,
           case .authenticationFailed = sessionErr {
            return ServerStatus(isLive: false, reachability: .invalidToken)
        }
        return ServerStatus(isLive: false, reachability: .unreachable)
    }
```

Then update the `catch` block inside `probe` (`ServerStatusChecker.swift:84-87`)
from:

```swift
                    } catch {
                        connection.disconnect()
                        return ServerStatus()
                    }
```

to:

```swift
                    } catch {
                        connection.disconnect()
                        return Self.statusForProbeFailure(error)
                    }
```

And update the success return on line 83 from `ServerStatus(isLive: true)` to:

```swift
                        return ServerStatus(isLive: true, reachability: .live)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ServerStatusCheckerTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift Tests/ClaudeRelayClientTests/ServerStatusCheckerTests.swift
git commit -m "feat(client): classify invalid-token vs unreachable in status probe"
```

---

## Task 3: Add `authRejected` flag + auth-failure detection to `RecoveryController`

**Files:**
- Modify: `Sources/ClaudeRelayClient/ViewModels/RecoveryController.swift` (state fields ~line 50; `scheduleAutoRecovery` ~line 82; `restoreSession` catch ~line 253-273; test hooks ~line 310)
- Test: `Tests/ClaudeRelayClientTests/RecoveryControllerTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `RecoveryControllerTests.swift` (inside the class):

```swift
    // MARK: - Auth rejection

    func testScheduleAutoRecoveryBlockedWhenAuthRejected() {
        let (coordinator, controller) = makeCoordinatorAndController()
        controller._testOnly_setAuthRejected(true)

        controller.scheduleAutoRecovery()

        XCTAssertNil(coordinator.recoveryTask)
    }

    func testTriggerUserRecoveryClearsAuthRejected() {
        let (_, controller) = makeCoordinatorAndController()
        controller._testOnly_setAuthRejected(true)
        XCTAssertTrue(controller._testOnly_authRejected)

        controller.triggerUserRecovery()

        XCTAssertFalse(controller._testOnly_authRejected)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecoveryControllerTests`
Expected: FAIL — `_testOnly_setAuthRejected` / `_testOnly_authRejected` not defined.

- [ ] **Step 3: Write minimal implementation**

(a) Add the state field next to `autoRecoverySuspended` (after
`RecoveryController.swift:50`):

```swift
    /// True once the server rejected the token as invalid. Unlike the
    /// failure-count breaker, this trips on the FIRST auth rejection and is
    /// cleared ONLY by user-initiated recovery (e.g. after re-pairing). This
    /// is what stops the silent reconnect storm against a known-bad token.
    private var authRejected = false
```

(b) Add a gate in `scheduleAutoRecovery`, immediately after the
`autoRecoverySuspended` guard (after `RecoveryController.swift:92`):

```swift
        guard !authRejected else {
            recoveryLog.info("scheduleAutoRecovery: token rejected — awaiting user re-pair")
            return
        }
```

(c) In `triggerUserRecovery`, clear the flag alongside the breaker reset
(after the existing `consecutiveAutoRecoveryFailures = 0` at
`RecoveryController.swift:135`):

```swift
        authRejected = false
```

(d) In `restoreSession`'s catch block, set the flag inside the existing
app-level-error branch. Change the block at `RecoveryController.swift:258-268`
from:

```swift
            if SharedSessionCoordinator.isApplicationLevelError(error) {
                // Session no longer exists / invalid transition / etc. The
                // socket itself is fine — clear the active session and surface
                // a recoverable error. Don't tear the workspace down via
                // connectionTimedOut.
                if let activeId = coordinator.activeSessionId {
                    coordinator.evictTerminal(for: activeId)
                    coordinator.activeSessionId = nil
                }
                coordinator.sessionAttachError = coordinator.friendlyAttachErrorMessage(error)
                coordinator.sessionAttachFailed = true
            } else {
```

to:

```swift
            if SharedSessionCoordinator.isApplicationLevelError(error) {
                // Session no longer exists / invalid transition / etc. The
                // socket itself is fine — clear the active session and surface
                // a recoverable error. Don't tear the workspace down via
                // connectionTimedOut.
                if case SessionController.SessionError.authenticationFailed = error {
                    // Token rejected: stop auto-recovery entirely until the
                    // user re-pairs. Prevents the reconnect storm that trips
                    // the server's rate limiter.
                    authRejected = true
                }
                if let activeId = coordinator.activeSessionId {
                    coordinator.evictTerminal(for: activeId)
                    coordinator.activeSessionId = nil
                }
                coordinator.sessionAttachError = coordinator.friendlyAttachErrorMessage(error)
                coordinator.sessionAttachFailed = true
            } else {
```

(e) Add test hooks next to the existing ones (after
`RecoveryController.swift:311`):

```swift
    var _testOnly_authRejected: Bool { authRejected }
    func _testOnly_setAuthRejected(_ value: Bool) { authRejected = value }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RecoveryControllerTests`
Expected: PASS (existing tests + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/ViewModels/RecoveryController.swift Tests/ClaudeRelayClientTests/RecoveryControllerTests.swift
git commit -m "feat(client): stop auto-recovery on invalid token (authRejected gate)"
```

---

## Task 4: Friendly re-pair message for `authenticationFailed`

**Files:**
- Modify: `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift:552-568`
- Test: `Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift` (create if absent)

- [ ] **Step 1: Write the failing test**

Create (or append to) `Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayClient

@MainActor
final class SharedSessionCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> SharedSessionCoordinator {
        let connection = RelayConnection()
        return SharedSessionCoordinator(connection: connection, token: "test-token")
    }

    func testFriendlyMessageForAuthenticationFailed() {
        let coordinator = makeCoordinator()
        let err = SessionController.SessionError.authenticationFailed(reason: "Invalid token")
        let message = coordinator.friendlyAttachErrorMessage(err)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("token"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("re-pair"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SharedSessionCoordinatorTests`
Expected: FAIL — message returns raw `localizedDescription` ("Authentication failed: Invalid token"), no "re-pair" text.

- [ ] **Step 3: Write minimal implementation**

In `friendlyAttachErrorMessage` (`SharedSessionCoordinator.swift:552`), add an
`authenticationFailed` case before the final `return`. Change the start of the
method from:

```swift
    func friendlyAttachErrorMessage(_ error: Error) -> String {
        if let sessionErr = error as? SessionController.SessionError,
           case .unexpectedResponse(let detail) = sessionErr {
```

to:

```swift
    func friendlyAttachErrorMessage(_ error: Error) -> String {
        if let sessionErr = error as? SessionController.SessionError,
           case .authenticationFailed = sessionErr {
            return "Access token rejected. This server's token is no longer "
                + "valid — edit the server to re-pair it."
        }
        if let sessionErr = error as? SessionController.SessionError,
           case .unexpectedResponse(let detail) = sessionErr {
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SharedSessionCoordinatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift
git commit -m "feat(client): friendly re-pair message for invalid token"
```

---

## Task 5: Surface invalid-token on the iOS server list

**Files:**
- Modify: `ClaudeRelayApp/Views/ServerListView.swift:183-188`

No unit test (pure SwiftUI view binding); verified by build + manual check.

- [ ] **Step 1: Update the status dot + label**

Change `ServerListView.swift:183-188` from:

```swift
                        .fill(status?.isLive == true ? .green : .red)
```
and
```swift
                    Text(status?.isLive == true ? "Live" : "Offline")
```

to (matching surrounding code style — read the exact lines first and preserve
modifiers/indentation):

```swift
                        .fill(statusColor(status))
```
and
```swift
                    Text(statusLabel(status))
```

Then add two small helpers in the same view (near the other private helpers in
the file):

```swift
    private func statusColor(_ status: ServerStatus?) -> Color {
        switch status?.reachability {
        case .live:         return .green
        case .invalidToken: return .orange
        default:            return .red
        }
    }

    private func statusLabel(_ status: ServerStatus?) -> String {
        switch status?.reachability {
        case .live:         return "Live"
        case .invalidToken: return "Invalid token"
        default:            return "Offline"
        }
    }
```

- [ ] **Step 2: Build to verify**

Run: `swift build` (compiles the shared client; the iOS view itself is built in Xcode).
Then build the iOS app in Xcode (Cmd+B) to confirm the view compiles.
Expected: build succeeds; server list shows orange "Invalid token" when the token is bad.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/Views/ServerListView.swift
git commit -m "feat(ios): show 'Invalid token' on server list"
```

---

## Task 6: Surface invalid-token on the macOS server list

**Files:**
- Modify: `ClaudeRelayMac/Views/ServerListWindow.swift:28-32`

- [ ] **Step 1: Pass reachability through**

Read `ServerListWindow.swift:28-32` first. The current binding is:

```swift
                        isReachable: viewModel.statuses[connection.id]?.isLive ?? false
```

If the row component only accepts a `Bool`, keep `isReachable` as-is AND add an
adjacent invalid-token signal. Add a computed flag in the call site:

```swift
                        isReachable: viewModel.statuses[connection.id]?.isLive ?? false,
                        isTokenInvalid: viewModel.statuses[connection.id]?.reachability == .invalidToken
```

Then thread `isTokenInvalid` into the row view (locate the row struct it calls
— search `grep -n "isReachable" ClaudeRelayMac/Views/ServerListWindow.swift`)
and render an orange dot + "Invalid token" label when `isTokenInvalid` is true,
mirroring the iOS helpers in Task 5.

- [ ] **Step 2: Build to verify**

Build the macOS app in Xcode (Cmd+B).
Expected: build succeeds; macOS server list shows the invalid-token state.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/Views/ServerListWindow.swift
git commit -m "feat(mac): show 'Invalid token' on server list"
```

---

## Task 7: Full test + build verification

- [ ] **Step 1: Run the full client test suite**

Run: `swift test --filter ClaudeRelayClientTests`
Expected: all pass (existing + new tests from Tasks 1-4).

- [ ] **Step 2: Build all SPM targets**

Run: `swift build`
Expected: success, no warnings introduced.

- [ ] **Step 3: Manual smoke (optional but recommended)**

With a deliberately wrong token configured for a server: confirm the app shows
"Invalid token" on the list and the re-pair banner in the workspace, and that
the server logs no longer show a 1/second `rejected: rate-limited` storm
(`swift run claude-relay logs show | tail`).

---

## Self-Review Notes

- **Spec coverage:** Task 3 → recovery halt (spec component 1); Tasks 1-2 → probe classification (component 2); Task 4 → message mapping (component 3); Tasks 5-6 → both UI surfaces (decision: surface in both places). No client-side rate limiting added (scope guard honored). ✅
- **Type consistency:** `ServerStatus.Reachability` cases (`.unknown/.live/.invalidToken/.unreachable`) used identically in Tasks 1, 2, 5, 6. `authRejected` / `_testOnly_authRejected` / `_testOnly_setAuthRejected` consistent across Task 3. `SessionController.SessionError.authenticationFailed` matched the same way (case pattern, ignoring associated value) in Tasks 2, 3, 4. ✅
- **No placeholders:** every code step shows complete code. Tasks 5-6 require reading exact view lines first because surrounding SwiftUI modifiers aren't fully known — flagged explicitly rather than guessed. ✅
