# Host Pairing — Plan 1a (Host Side: Server + Kit + CLI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `claude-relay setup` print a scannable QR whose one-time code a device can exchange over the WebSocket for a freshly minted per-device token, and make the CLI aware of which launchd manager owns the service.

**Architecture:** A new in-memory `PairingCodeStore` actor holds short-lived single-use codes, minted through the existing localhost-only admin API (`POST /pair/create`) and redeemed pre-auth over the WebSocket via two new envelope messages (`pair_request` / `pair_success`). The CLI gains `setup` (health-check → resolve service manager → mint → render QR), `hook install`, and a shared `ServiceManagerDetector` that stops every service command from driving the wrong launchd label.

**Tech Stack:** Swift 6, SwiftNIO, ArgumentParser, XCTest, CoreImage (`CIQRCodeGenerator`, system framework — no new SPM dependency).

**Spec:** `docs/superpowers/specs/2026-07-31-host-pairing-and-provisioning-design.md`

**Scope:** Host side only. The iOS/macOS/Android clients that consume this are **Plan 1b**. This plan is independently shippable: it fixes a live service-command bug, adds `hook install`, and `setup` produces a QR that Plan 1b's clients (and the integration test in Task 9) can redeem.

## Global Constraints

- **Swift 6 strict concurrency.** `ChannelHandlerContext` is NOT `Sendable`: to use it inside a `Task`, wrap it in `UnsafeTransfer` and only touch `ctx.value` inside `eventLoop.execute { }`. Async work in `RelayMessageHandler` goes through the existing `bridgeToEventLoop(context:work:onSuccess:onFailure:)` helper.
- **Wire type strings must be unique across `ClientMessage.allTypeStrings` and `ServerMessage.allTypeStrings`.** The envelope decoder checks client strings first. New strings: `pair_request` (client), `pair_success` (server).
- **`ClientMessage`/`ServerMessage` cannot be decoded standalone** — always via `MessageEnvelope`.
- **Date encoding:** the WebSocket server uses a *default* `JSONEncoder` (Double timestamps); the Admin HTTP API uses `.iso8601`. Never mix them. `POST /pair/create` is admin → `.iso8601`.
- **Admin API is localhost-only** (binds 127.0.0.1), body cap 64 KB → 413. That binding is the entire auth model for admin routes; add no other auth.
- **`PairingCodeStore` must be injected with NO default parameter value** into `AdminRoutes.handle`, `WebSocketServer.init` and `RelayMessageHandler.init`. It is in-memory, so a defaulted parameter would give each connection its own empty store and codes would never be redeemable.
- **Rate limiting:** `main.swift` builds `RateLimiter(maxAttempts: 10, windowSeconds: 60)`. Per-connection pairing attempts cap at 3, mirroring `RelayMessageHandler.maxAuthAttempts = 3`.
- **Test framework is XCTest** (not swift-testing). Server tests may subclass `SessionManagerTestCase`.
- **`swift test` in full hangs deterministically** at `GitRootResolver` (pre-existing since 22 Jul, unrelated). Always verify with `swift test --filter <SuiteName>`. Never claim a full green run.
- **SwiftLint:** line length warning 140, error 200. Identifier min length 2.
- **Never** run the server binary directly or `pkill` it. Service management is via the CLI or `brew services`.

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/ClaudeRelayKit/Security/PairingCode.swift` (new) | Code alphabet, generation, normalization, formatting. Pure. |
| `Sources/ClaudeRelayKit/Protocol/PairingURL.swift` (new) | Build + parse/validate `coderelay://pair?…`. Pure. Shared with Plan 1b. |
| `Sources/ClaudeRelayKit/Protocol/ClientMessage.swift` | Add `.pairRequest`. |
| `Sources/ClaudeRelayKit/Protocol/ServerMessage.swift` | Add `.pairSuccess`. |
| `Sources/ClaudeRelayServer/Actors/PairingCodeStore.swift` (new) | Pending-code lifecycle: mint, redeem, expiry sweep, cap eviction. |
| `Sources/ClaudeRelayServer/Network/AdminRoutes.swift` | `POST /pair/create`. |
| `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift` | `handlePairRequest` in the pre-auth switch. |
| `Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift`, `WebSocketServer.swift`, `main.swift` | Thread the shared store through. |
| `Sources/ClaudeRelayCLI/ServiceManagerDetector.swift` (new) | Which launchd manager owns the service + nudge text. Pure, injectable. |
| `Sources/ClaudeRelayCLI/TerminalQRRenderer.swift` (new) | Payload → half-block ANSI QR. Pure. |
| `Sources/ClaudeRelayCLI/HostAddressResolver.swift` (new) | Pick the host that goes in the QR. |
| `Sources/ClaudeRelayCLI/Commands/SetupCommand.swift` (new) | `claude-relay setup`. |
| `Sources/ClaudeRelayCLI/Commands/HookCommands.swift` (new) | `claude-relay hook install|uninstall`. |
| `Sources/ClaudeRelayCLI/Commands/ServiceCommands.swift` | Wire nudges into all six service commands. |

---

### Task 1: `PairingCode` — alphabet, generation, normalization

**Files:**
- Create: `Sources/ClaudeRelayKit/Security/PairingCode.swift`
- Test: `Tests/ClaudeRelayKitTests/PairingCodeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PairingCode.generate() -> String` (8 raw chars), `PairingCode.normalize(_ input: String) -> String?`, `PairingCode.formatted(_ code: String) -> String`, `PairingCode.alphabet: [Character]`, `PairingCode.length: Int`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeRelayKit

final class PairingCodeTests: XCTestCase {

    func testAlphabetIsCrockfordBase32WithoutAmbiguousLetters() {
        XCTAssertEqual(PairingCode.alphabet.count, 32)
        for banned: Character in ["I", "L", "O", "U"] {
            XCTAssertFalse(PairingCode.alphabet.contains(banned), "\(banned) is ambiguous")
        }
        // Uppercase + digits only.
        for ch in PairingCode.alphabet {
            XCTAssertTrue(ch.isUppercase || ch.isNumber, "unexpected symbol \(ch)")
        }
    }

    func testGenerateProducesCodeOfExpectedLengthFromAlphabet() {
        let code = PairingCode.generate()
        XCTAssertEqual(code.count, PairingCode.length)
        for ch in code {
            XCTAssertTrue(PairingCode.alphabet.contains(ch), "\(ch) not in alphabet")
        }
    }

    func testGenerateIsNotConstant() {
        let codes = Set((0..<50).map { _ in PairingCode.generate() })
        XCTAssertGreaterThan(codes.count, 45, "generation looks non-random")
    }

    func testNormalizeStripsHyphensWhitespaceAndUppercases() {
        XCTAssertEqual(PairingCode.normalize(" k7qp-2m4x "), "K7QP2M4X")
        XCTAssertEqual(PairingCode.normalize("K7QP2M4X"), "K7QP2M4X")
    }

    func testNormalizeMapsVisuallyConfusableInput() {
        // Users type O for 0 and I/L for 1 — accept and fold them.
        XCTAssertEqual(PairingCode.normalize("OI2345L7"), "012345 17".replacingOccurrences(of: " ", with: ""))
    }

    func testNormalizeRejectsWrongLengthOrIllegalCharacters() {
        XCTAssertNil(PairingCode.normalize("K7QP2M4"))      // too short
        XCTAssertNil(PairingCode.normalize("K7QP2M4XX"))    // too long
        XCTAssertNil(PairingCode.normalize("K7QP2M4!"))     // illegal symbol
        XCTAssertNil(PairingCode.normalize(""))
    }

    func testFormattedGroupsInFours() {
        XCTAssertEqual(PairingCode.formatted("K7QP2M4X"), "K7QP-2M4X")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PairingCodeTests`
Expected: FAIL — "cannot find 'PairingCode' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import Security

/// A short, human-transcribable one-time pairing code.
///
/// Alphabet is Crockford Base32 — the 10 digits plus 22 uppercase letters,
/// excluding `I`, `L`, `O` and `U`. That removes every `0`/`O` and `1`/`I`/`L`
/// confusion when a user reads a code off a screen and types it on a phone.
/// `U` is excluded by the same standard (it keeps accidental profanity out of
/// generated codes).
///
/// 8 characters over a 32-symbol alphabet is 40 bits of entropy. Combined with
/// the server's per-IP rate limit and a 5-minute TTL, that is far out of reach
/// of online guessing.
public enum PairingCode {

    public static let length = 8

    public static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Characters a user might type instead of the canonical symbol.
    private static let confusables: [Character: Character] = [
        "I": "1", "L": "1", "O": "0", "U": "V"
    ]

    /// Generates a fresh code using the system CSPRNG.
    ///
    /// Rejection-samples raw bytes so every symbol is equally likely: 256 is
    /// not a multiple of 32, so a bare `byte % 32` would bias the first 8
    /// symbols. (256 happens to be divisible by 32, but the rejection guard is
    /// kept so the alphabet can change size without silently introducing bias.)
    public static func generate() -> String {
        var out = ""
        out.reserveCapacity(length)
        let count = alphabet.count
        let limit = (256 / count) * count
        while out.count < length {
            var byte: UInt8 = 0
            let status = withUnsafeMutablePointer(to: &byte) {
                SecRandomCopyBytes(kSecRandomDefault, 1, $0)
            }
            precondition(status == errSecSuccess, "Failed to generate random bytes")
            guard Int(byte) < limit else { continue }
            out.append(alphabet[Int(byte) % count])
        }
        return out
    }

    /// Canonicalizes user input, or returns nil if it cannot be a valid code.
    /// Strips hyphens and whitespace, uppercases, and folds confusable letters.
    public static func normalize(_ input: String) -> String? {
        var out = ""
        out.reserveCapacity(length)
        for raw in input.uppercased() {
            if raw == "-" || raw.isWhitespace { continue }
            let ch = confusables[raw] ?? raw
            guard alphabet.contains(ch) else { return nil }
            out.append(ch)
        }
        return out.count == length ? out : nil
    }

    /// Renders a code for display, grouped in fours: `K7QP-2M4X`.
    /// The hyphen is presentation only; `normalize` strips it.
    public static func formatted(_ code: String) -> String {
        guard code.count == length else { return code }
        let mid = code.index(code.startIndex, offsetBy: length / 2)
        return "\(code[code.startIndex..<mid])-\(code[mid...])"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PairingCodeTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayKit/Security/PairingCode.swift Tests/ClaudeRelayKitTests/PairingCodeTests.swift
git commit -m "feat(kit): PairingCode — Crockford Base32 one-time pairing codes"
```

---

### Task 2: `PairingURL` — build and parse the deep link

**Files:**
- Create: `Sources/ClaudeRelayKit/Protocol/PairingURL.swift`
- Test: `Tests/ClaudeRelayKitTests/PairingURLTests.swift`

**Interfaces:**
- Consumes: `PairingCode.normalize`, `PairingCode.length` (Task 1).
- Produces: `struct PairingURL { let host: String; let port: UInt16; let useTLS: Bool; let code: String }`, `PairingURL.init?(url: URL)`, `PairingURL.init?(string: String)`, `var urlString: String`, `static let scheme = "clauderelay"`, `static let host = "pair"`.

Plan 1b's clients depend on this parser, so validation lives here rather than in any UI layer.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeRelayKit

final class PairingURLTests: XCTestCase {

    func testRoundTripsThroughURLString() throws {
        let original = PairingURL(host: "silverwing.local", port: 9200, useTLS: false, code: "K7QP2M4X")
        let parsed = try XCTUnwrap(PairingURL(string: original.urlString))
        XCTAssertEqual(parsed.host, "silverwing.local")
        XCTAssertEqual(parsed.port, 9200)
        XCTAssertFalse(parsed.useTLS)
        XCTAssertEqual(parsed.code, "K7QP2M4X")
    }

    func testURLStringShape() {
        let url = PairingURL(host: "silverwing.local", port: 9200, useTLS: false, code: "K7QP2M4X")
        XCTAssertEqual(url.urlString,
            "coderelay://pair?host=silverwing.local&port=9200&tls=0&code=K7QP2M4X")
    }

    func testTLSFlagParsesBothWays() throws {
        let secure = try XCTUnwrap(PairingURL(string:
            "coderelay://pair?host=example.com&port=443&tls=1&code=K7QP2M4X"))
        XCTAssertTrue(secure.useTLS)
        let plain = try XCTUnwrap(PairingURL(string:
            "coderelay://pair?host=example.com&port=443&tls=0&code=K7QP2M4X"))
        XCTAssertFalse(plain.useTLS)
    }

    func testNormalizesHyphenatedAndLowercaseCode() throws {
        let parsed = try XCTUnwrap(PairingURL(string:
            "coderelay://pair?host=a.local&port=9200&tls=0&code=k7qp-2m4x"))
        XCTAssertEqual(parsed.code, "K7QP2M4X")
    }

    func testRejectsWrongSchemeOrAction() {
        XCTAssertNil(PairingURL(string: "https://pair?host=a.local&port=9200&tls=0&code=K7QP2M4X"))
        // The session deep link must not parse as a pairing link.
        XCTAssertNil(PairingURL(string: "coderelay://session/\(UUID().uuidString)"))
    }

    func testRejectsMissingParameters() {
        XCTAssertNil(PairingURL(string: "coderelay://pair?port=9200&tls=0&code=K7QP2M4X"))
        XCTAssertNil(PairingURL(string: "coderelay://pair?host=a.local&tls=0&code=K7QP2M4X"))
        XCTAssertNil(PairingURL(string: "coderelay://pair?host=a.local&port=9200&tls=0"))
    }

    func testRejectsOutOfRangeOrNonNumericPort() {
        XCTAssertNil(PairingURL(string: "coderelay://pair?host=a.local&port=0&tls=0&code=K7QP2M4X"))
        XCTAssertNil(PairingURL(string: "coderelay://pair?host=a.local&port=70000&tls=0&code=K7QP2M4X"))
        XCTAssertNil(PairingURL(string: "coderelay://pair?host=a.local&port=abc&tls=0&code=K7QP2M4X"))
    }

    func testRejectsBadCode() {
        XCTAssertNil(PairingURL(string: "coderelay://pair?host=a.local&port=9200&tls=0&code=SHORT"))
        XCTAssertNil(PairingURL(string: "coderelay://pair?host=a.local&port=9200&tls=0&code=K7QP2M4%21"))
    }

    func testRejectsEmptyOrWhitespaceHost() {
        XCTAssertNil(PairingURL(string: "coderelay://pair?host=&port=9200&tls=0&code=K7QP2M4X"))
        XCTAssertNil(PairingURL(string: "coderelay://pair?host=%20&port=9200&tls=0&code=K7QP2M4X"))
    }

    func testRejectsHostThatCannotFormAWebSocketURL() {
        // A host with a space or a slash would produce an invalid ws:// URL.
        XCTAssertNil(PairingURL(string: "coderelay://pair?host=a%20b&port=9200&tls=0&code=K7QP2M4X"))
        XCTAssertNil(PairingURL(string: "coderelay://pair?host=a%2Fb&port=9200&tls=0&code=K7QP2M4X"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PairingURLTests`
Expected: FAIL — "cannot find 'PairingURL' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The `coderelay://pair?host=&port=&tls=&code=` deep link produced by
/// `claude-relay setup` and consumed by the apps.
///
/// Parsing and validation live here, in the shared kit, so the server-side
/// producer and all three clients agree on exactly what a valid pairing link
/// is — and so hostile input is rejected in one tested place.
public struct PairingURL: Equatable, Sendable {
    public static let scheme = "clauderelay"
    public static let host = "pair"

    public let host: String
    public let port: UInt16
    public let useTLS: Bool
    /// Always normalized (uppercase, no hyphen).
    public let code: String

    public init(host: String, port: UInt16, useTLS: Bool, code: String) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.code = code
    }

    public var urlString: String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "tls", value: useTLS ? "1" : "0"),
            URLQueryItem(name: "code", value: code)
        ]
        return components.url?.absoluteString ?? ""
    }

    /// The WebSocket URL a client should dial to redeem this code.
    public var wsURL: URL? {
        URL(string: "\(useTLS ? "wss" : "ws")://\(host):\(port)")
    }

    public init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url: url)
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        guard let rawHost = value("host")?.trimmingCharacters(in: .whitespaces),
              !rawHost.isEmpty,
              let rawPort = value("port"), let port = UInt16(rawPort), port >= 1,
              let rawCode = value("code"), let code = PairingCode.normalize(rawCode)
        else { return nil }

        let useTLS = value("tls") == "1"

        // Reject anything that cannot form a usable ws:// URL (spaces, slashes,
        // other RFC 3986-illegal host characters).
        guard URL(string: "\(useTLS ? "wss" : "ws")://\(rawHost):\(port)") != nil,
              rawHost.rangeOfCharacter(from: CharacterSet(charactersIn: " /?#@")) == nil
        else { return nil }

        self.host = rawHost
        self.port = port
        self.useTLS = useTLS
        self.code = code
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PairingURLTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayKit/Protocol/PairingURL.swift Tests/ClaudeRelayKitTests/PairingURLTests.swift
git commit -m "feat(kit): PairingURL — parse/build the coderelay://pair deep link"
```

---

### Task 3: Wire messages — `pair_request` and `pair_success`

**Files:**
- Modify: `Sources/ClaudeRelayKit/Protocol/ClientMessage.swift` (add case, typeString, allTypeStrings, encode, decode)
- Modify: `Sources/ClaudeRelayKit/Protocol/ServerMessage.swift` (same four places)
- Test: `Tests/ClaudeRelayKitTests/PairingMessageTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ClientMessage.pairRequest(code: String, deviceName: String, platform: String)`; `ServerMessage.pairSuccess(token: String, tokenId: String, label: String)`.

`platform` is a plain `String` (not the existing `PushPlatform` enum) because pairing predates any push decision and is only used for the token label.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeRelayKit

final class PairingMessageTests: XCTestCase {

    func testPairRequestRoundTripsThroughEnvelope() throws {
        let message = ClientMessage.pairRequest(code: "K7QP2M4X", deviceName: "Miguel's iPhone", platform: "ios")
        let data = try JSONEncoder().encode(MessageEnvelope.client(message))
        let decoded = try JSONDecoder().decode(MessageEnvelope.self, from: data)
        guard case .client(let out) = decoded else { return XCTFail("expected client envelope") }
        XCTAssertEqual(out, message)
    }

    func testPairSuccessRoundTripsThroughEnvelope() throws {
        let message = ServerMessage.pairSuccess(token: "tok-abc", tokenId: "1a2b3c4d", label: "Miguel's iPhone (paired)")
        let data = try JSONEncoder().encode(MessageEnvelope.server(message))
        let decoded = try JSONDecoder().decode(MessageEnvelope.self, from: data)
        guard case .server(let out) = decoded else { return XCTFail("expected server envelope") }
        XCTAssertEqual(out, message)
    }

    func testTypeStrings() {
        XCTAssertEqual(ClientMessage.pairRequest(code: "K7QP2M4X", deviceName: "d", platform: "ios").typeString,
                       "pair_request")
        XCTAssertEqual(ServerMessage.pairSuccess(token: "t", tokenId: "i", label: "l").typeString,
                       "pair_success")
    }

    func testTypeStringsAreRegisteredAndUniqueAcrossDirections() {
        XCTAssertTrue(ClientMessage.allTypeStrings.contains("pair_request"))
        XCTAssertTrue(ServerMessage.allTypeStrings.contains("pair_success"))
        XCTAssertTrue(ClientMessage.allTypeStrings.isDisjoint(with: ServerMessage.allTypeStrings),
                      "envelope decoding requires disjoint type-string sets")
    }

    func testPairRequestWireKeys() throws {
        let message = ClientMessage.pairRequest(code: "K7QP2M4X", deviceName: "iPhone", platform: "ios")
        let data = try JSONEncoder().encode(MessageEnvelope.client(message))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "pair_request")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["code"] as? String, "K7QP2M4X")
        XCTAssertEqual(payload["deviceName"] as? String, "iPhone")
        XCTAssertEqual(payload["platform"] as? String, "ios")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PairingMessageTests`
Expected: FAIL — "type 'ClientMessage' has no member 'pairRequest'".

- [ ] **Step 3: Write minimal implementation**

In `ClientMessage.swift`, add the case after `.unregisterPushToken`:

```swift
    /// Redeem a one-time pairing code for a freshly minted per-device token.
    /// Sent **before** `authRequest` on a brand-new connection.
    case pairRequest(code: String, deviceName: String, platform: String)
```

Add to `typeString`:

```swift
        case .pairRequest:         return "pair_request"
```

Add to `allTypeStrings` (inside the existing set literal):

```swift
        "pair_request",
```

Add `deviceName` to `PayloadCodingKeys` (it already has `token`, `code` is new too):

```swift
        case platform, deviceId, enabled, notifyOnFinished, topic
        case code, deviceName
```

Add to `encodePayload`:

```swift
        case .pairRequest(let code, let deviceName, let platform):
            try container.encode(code, forKey: .code)
            try container.encode(deviceName, forKey: .deviceName)
            try container.encode(platform, forKey: .platform)
```

Add to `decode`:

```swift
        case "pair_request":
            return .pairRequest(
                code: try container.decode(String.self, forKey: .code),
                deviceName: try container.decode(String.self, forKey: .deviceName),
                platform: try container.decode(String.self, forKey: .platform))
```

> Note: `ClientMessage.PayloadCodingKeys` has no `code` key today, but
> `ServerMessage.PayloadCodingKeys` already declares `code` (used by `.error`).
> Add `code` only to the client enum's keys.

In `ServerMessage.swift`, add the case:

```swift
    /// A pairing code was redeemed: here is the newly minted device token.
    case pairSuccess(token: String, tokenId: String, label: String)
```

Add to `typeString`:

```swift
        case .pairSuccess:         return "pair_success"
```

Add to `allTypeStrings`:

```swift
        "pair_success",
```

Add `token` and `label` to `ServerMessage.PayloadCodingKeys` (it already has `tokenId`):

```swift
        case agentState, title, workingDir, accepted, text, tokenId
        case token, label
```

Add to `encodePayload`:

```swift
        case .pairSuccess(let token, let tokenId, let label):
            try container.encode(token, forKey: .token)
            try container.encode(tokenId, forKey: .tokenId)
            try container.encode(label, forKey: .label)
```

Add to `decode`:

```swift
        case "pair_success":
            return .pairSuccess(
                token: try container.decode(String.self, forKey: .token),
                tokenId: try container.decode(String.self, forKey: .tokenId),
                label: try container.decode(String.self, forKey: .label))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PairingMessageTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the existing protocol suites for regressions**

Run: `swift test --filter ClaudeRelayKitTests`
Expected: PASS — the new enum cases must not break existing envelope tests. If a `switch` elsewhere is now non-exhaustive, the build will say so; fix those call sites.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelayKit/Protocol/ClientMessage.swift Sources/ClaudeRelayKit/Protocol/ServerMessage.swift Tests/ClaudeRelayKitTests/PairingMessageTests.swift
git commit -m "feat(protocol): add pair_request / pair_success wire messages"
```

---

### Task 4: `PairingCodeStore` actor

**Files:**
- Create: `Sources/ClaudeRelayServer/Actors/PairingCodeStore.swift`
- Test: `Tests/ClaudeRelayServerTests/PairingCodeStoreTests.swift`

**Interfaces:**
- Consumes: `PairingCode.generate()` (Task 1).
- Produces:
  - `actor PairingCodeStore`
  - `init(ttl: TimeInterval = 300, maxPending: Int = 8, now: @Sendable @escaping () -> Date = { Date() })`
  - `func mint(label: String?) -> PairingGrant`
  - `func redeem(_ code: String) -> PairingGrant?`
  - `func pendingCount() -> Int`
  - `struct PairingGrant: Sendable, Equatable { let code: String; let label: String?; let expiresAt: Date }`

The injectable `now` closure makes expiry testable without sleeping.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class PairingCodeStoreTests: XCTestCase {

    /// A controllable clock so expiry is tested without sleeping.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ start: Date) { value = start }
        var current: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    private func makeStore(ttl: TimeInterval = 300, maxPending: Int = 8)
        -> (PairingCodeStore, Clock) {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = PairingCodeStore(ttl: ttl, maxPending: maxPending, now: { clock.current })
        return (store, clock)
    }

    func testMintProducesRedeemableCode() async {
        let (store, _) = makeStore()
        let grant = await store.mint(label: "iPhone")
        XCTAssertEqual(grant.code.count, PairingCode.length)
        let redeemed = await store.redeem(grant.code)
        XCTAssertEqual(redeemed?.label, "iPhone")
    }

    func testRedeemIsSingleUse() async {
        let (store, _) = makeStore()
        let grant = await store.mint(label: nil)
        XCTAssertNotNil(await store.redeem(grant.code))
        XCTAssertNil(await store.redeem(grant.code), "a code must not be redeemable twice")
        XCTAssertEqual(await store.pendingCount(), 0)
    }

    func testRedeemRejectsUnknownCode() async {
        let (store, _) = makeStore()
        _ = await store.mint(label: nil)
        XCTAssertNil(await store.redeem("00000000"))
    }

    func testRedeemNormalizesHyphenatedLowercaseInput() async {
        let (store, _) = makeStore()
        let grant = await store.mint(label: nil)
        let typed = PairingCode.formatted(grant.code).lowercased()
        XCTAssertNotNil(await store.redeem(typed))
    }

    func testExpiredCodeIsNotRedeemable() async {
        let (store, clock) = makeStore(ttl: 300)
        let grant = await store.mint(label: nil)
        clock.advance(301)
        XCTAssertNil(await store.redeem(grant.code))
    }

    func testCodeIsStillValidJustBeforeExpiry() async {
        let (store, clock) = makeStore(ttl: 300)
        let grant = await store.mint(label: nil)
        clock.advance(299)
        XCTAssertNotNil(await store.redeem(grant.code))
    }

    func testExpiresAtReflectsTTL() async {
        let (store, clock) = makeStore(ttl: 300)
        let before = clock.current
        let grant = await store.mint(label: nil)
        XCTAssertEqual(grant.expiresAt.timeIntervalSince(before), 300, accuracy: 0.001)
    }

    func testMintingPastCapEvictsOldest() async {
        let (store, clock) = makeStore(maxPending: 3)
        let first = await store.mint(label: "first")
        clock.advance(1)
        let second = await store.mint(label: "second")
        clock.advance(1)
        _ = await store.mint(label: "third")
        clock.advance(1)
        _ = await store.mint(label: "fourth")

        XCTAssertEqual(await store.pendingCount(), 3)
        XCTAssertNil(await store.redeem(first.code), "oldest should have been evicted")
        XCTAssertNotNil(await store.redeem(second.code))
    }

    func testExpiredEntriesAreSweptOnMint() async {
        let (store, clock) = makeStore(ttl: 60, maxPending: 8)
        _ = await store.mint(label: nil)
        _ = await store.mint(label: nil)
        XCTAssertEqual(await store.pendingCount(), 2)
        clock.advance(61)
        _ = await store.mint(label: nil)
        XCTAssertEqual(await store.pendingCount(), 1, "stale entries should be swept")
    }

    func testRedeemRejectsMalformedInputWithoutTouchingStore() async {
        let (store, _) = makeStore()
        let grant = await store.mint(label: nil)
        XCTAssertNil(await store.redeem("!!!"))
        XCTAssertEqual(await store.pendingCount(), 1)
        XCTAssertNotNil(await store.redeem(grant.code))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PairingCodeStoreTests`
Expected: FAIL — "cannot find 'PairingCodeStore' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import ClaudeRelayKit

/// A grant issued by `PairingCodeStore.mint` and returned by a successful
/// `redeem`.
public struct PairingGrant: Sendable, Equatable {
    public let code: String
    public let label: String?
    public let expiresAt: Date
}

/// Holds the short-lived, single-use pairing codes that a device exchanges for
/// a real auth token.
///
/// **In-memory by design.** Codes live ~5 minutes; persisting them would keep a
/// credential on disk for no benefit and let one survive a restart. A
/// consequence is that this store must be created **once** in `main.swift` and
/// injected into both the admin route (which mints) and every WebSocket handler
/// (which redeems) — a per-connection instance would never see a minted code.
public actor PairingCodeStore {

    private struct Entry {
        let label: String?
        let expiresAt: Date
        /// Mint order, used to evict the oldest when at capacity.
        let sequence: UInt64
    }

    private let ttl: TimeInterval
    private let maxPending: Int
    private let now: @Sendable () -> Date

    private var entries: [String: Entry] = [:]
    private var nextSequence: UInt64 = 0

    public init(
        ttl: TimeInterval = 300,
        maxPending: Int = 8,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.ttl = ttl
        self.maxPending = maxPending
        self.now = now
    }

    /// Mints a fresh code. Sweeps expired entries first, then evicts the oldest
    /// if still at capacity.
    public func mint(label: String?) -> PairingGrant {
        sweepExpired()

        while entries.count >= maxPending {
            guard let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key else { break }
            entries.removeValue(forKey: oldest)
        }

        var code = PairingCode.generate()
        // Astronomically unlikely, but a collision would silently overwrite a
        // pending grant, so re-roll instead.
        while entries[code] != nil { code = PairingCode.generate() }

        let expiresAt = now().addingTimeInterval(ttl)
        entries[code] = Entry(label: label, expiresAt: expiresAt, sequence: nextSequence)
        nextSequence += 1
        return PairingGrant(code: code, label: label, expiresAt: expiresAt)
    }

    /// Redeems a code, removing it. Returns nil if the code is malformed,
    /// unknown, or expired. Accepts hyphenated/lowercase user input.
    public func redeem(_ input: String) -> PairingGrant? {
        guard let code = PairingCode.normalize(input) else { return nil }
        guard let entry = entries[code] else { return nil }
        entries.removeValue(forKey: code)
        guard entry.expiresAt > now() else { return nil }
        return PairingGrant(code: code, label: entry.label, expiresAt: entry.expiresAt)
    }

    public func pendingCount() -> Int {
        sweepExpired()
        return entries.count
    }

    private func sweepExpired() {
        let cutoff = now()
        entries = entries.filter { $0.value.expiresAt > cutoff }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PairingCodeStoreTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayServer/Actors/PairingCodeStore.swift Tests/ClaudeRelayServerTests/PairingCodeStoreTests.swift
git commit -m "feat(server): PairingCodeStore — in-memory single-use pairing codes"
```

---

### Task 5: `POST /pair/create` admin route

**Files:**
- Modify: `Sources/ClaudeRelayServer/Network/AdminRoutes.swift` (add `pairingStore` param to `handle`, add route + handler)
- Modify: `Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift` (accept + forward the store)
- Modify: `Sources/ClaudeRelayServer/main.swift` (construct the store, pass to admin server)
- Test: `Tests/ClaudeRelayServerTests/PairCreateRouteTests.swift`
- Test: `Tests/ClaudeRelayServerTests/AdminRoutesEndpointTests.swift` (update the shared `route` helper)

**Interfaces:**
- Consumes: `PairingCodeStore.mint(label:)`, `PairingGrant` (Task 4).
- Produces: `AdminRoutes.handle(method:uri:body:sessionManager:tokenStore:pairingStore:)` — **`pairingStore` has no default value.** Response JSON: `{"code": "K7QP2M4X", "formattedCode": "K7QP-2M4X", "expiresAt": "<iso8601>", "wsPort": 9200, "tls": false}`.

The route deliberately does **not** choose the host — that is the CLI's job (Task 8), since only the CLI knows about `--host`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import NIOCore
import NIOHTTP1
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class PairCreateRouteTests: SessionManagerTestCase {

    private func route(
        _ method: HTTPMethod,
        _ uri: String,
        body: [String: Any]? = nil,
        pairingStore: PairingCodeStore
    ) async -> (status: Int, json: [String: Any]?) {
        var buf: ByteBuffer?
        if let body, let data = try? JSONSerialization.data(withJSONObject: body) {
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            buf = buffer
        }
        let response = await AdminRoutes.handle(
            method: method, uri: uri, body: buf,
            sessionManager: makeManager(), tokenStore: tokenStore,
            pairingStore: pairingStore
        )
        let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        return (response.statusCode, json)
    }

    func testPairCreateReturnsRedeemableCode() async throws {
        let store = PairingCodeStore()
        let (status, json) = await route(.POST, "/pair/create", body: ["label": "iPhone"], pairingStore: store)
        XCTAssertEqual(status, 200)
        let code = try XCTUnwrap(json?["code"] as? String)
        XCTAssertEqual(code.count, PairingCode.length)
        XCTAssertEqual(json?["formattedCode"] as? String, PairingCode.formatted(code))
        // The minted code must be redeemable from the SAME store instance.
        let grant = await store.redeem(code)
        XCTAssertEqual(grant?.label, "iPhone")
    }

    func testPairCreateWorksWithoutLabel() async throws {
        let store = PairingCodeStore()
        let (status, json) = await route(.POST, "/pair/create", pairingStore: store)
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(json?["code"] as? String)
    }

    func testPairCreateEmitsISO8601Expiry() async throws {
        let store = PairingCodeStore(ttl: 300)
        let (_, json) = await route(.POST, "/pair/create", pairingStore: store)
        let raw = try XCTUnwrap(json?["expiresAt"] as? String)
        let formatter = ISO8601DateFormatter()
        XCTAssertNotNil(formatter.date(from: raw), "admin API must emit ISO8601, not a Double")
    }

    func testPairCreateReportsWSPortAndTLS() async throws {
        let store = PairingCodeStore()
        let (_, json) = await route(.POST, "/pair/create", pairingStore: store)
        XCTAssertNotNil(json?["wsPort"] as? Int)
        XCTAssertNotNil(json?["tls"] as? Bool)
    }

    func testUnknownPairSubpathIs404() async {
        let store = PairingCodeStore()
        let (status, _) = await route(.POST, "/pair/nope", pairingStore: store)
        XCTAssertEqual(status, 404)
    }

    func testGetPairCreateIsNotAllowed() async {
        let store = PairingCodeStore()
        let (status, _) = await route(.GET, "/pair/create", pairingStore: store)
        XCTAssertEqual(status, 404)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PairCreateRouteTests`
Expected: FAIL — `AdminRoutes.handle` has no `pairingStore:` parameter.

- [ ] **Step 3: Write minimal implementation**

In `AdminRoutes.handle`, add the parameter and the route. The signature becomes:

```swift
    static func handle(
        method: HTTPMethod,
        uri: String,
        body: ByteBuffer?,
        sessionManager: SessionManager,
        tokenStore: TokenStore,
        pairingStore: PairingCodeStore
    ) async -> AdminResponse {
```

Add to the dispatch `switch`, next to the `hook` case:

```swift
        case (.POST, "pair"):
            return await handlePairCreate(components, body: body, pairingStore: pairingStore)
```

Add the handler:

```swift
    // MARK: - Pairing (F11)

    /// `POST /pair/create` — mint a one-time pairing code for a device to
    /// redeem over the WebSocket. Body (optional): `{"label": "<device name>"}`.
    ///
    /// Localhost-only, like every admin route: whoever can reach this port is
    /// already on the machine and could read the token store directly, so the
    /// code adds no privilege. It exists so the *token* never has to be
    /// displayed or transcribed.
    private static func handlePairCreate(
        _ components: [String],
        body: ByteBuffer?,
        pairingStore: PairingCodeStore
    ) async -> AdminResponse {
        guard components == ["pair", "create"] else { return .error("Not found", status: 404) }

        var label: String?
        if let body, let data = body.getData(at: body.readerIndex, length: body.readableBytes),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            label = (json["label"] as? String)?.trimmingCharacters(in: .whitespaces)
            if label?.isEmpty == true { label = nil }
        }

        let grant = await pairingStore.mint(label: label)
        let config = (try? ConfigManager.load()) ?? .default

        let payload: [String: Any] = [
            "code": grant.code,
            "formattedCode": PairingCode.formatted(grant.code),
            "expiresAt": ISO8601DateFormatter().string(from: grant.expiresAt),
            "wsPort": Int(config.wsPort),
            "tls": !(config.tlsCert?.isEmpty ?? true)
        ]
        return .json(payload)
    }
```

> If `AdminResponse` has no `.json([String: Any])` helper, look at how
> `handleHookState` and `handlePostTokens` build their responses in this same
> file and follow that pattern exactly.

In `AdminHTTPServer.swift`, add a stored `pairingStore` property, accept it in `init` (no default), and pass it at the `AdminRoutes.handle` call site (~line 138).

In `main.swift`, construct the store once after `rateLimiter` (~line 38) and pass it to the admin server:

```swift
let pairingStore = PairingCodeStore()
```

- [ ] **Step 4: Update the existing shared route helper**

`AdminRoutesEndpointTests.route(...)` calls `AdminRoutes.handle` and will no longer compile. Add `pairingStore: PairingCodeStore()` to that call so the existing suite builds.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter PairCreateRouteTests`
Expected: PASS (6 tests).

Run: `swift test --filter AdminRoutesEndpointTests`
Expected: PASS — no regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelayServer/Network/AdminRoutes.swift Sources/ClaudeRelayServer/Network/AdminHTTPServer.swift Sources/ClaudeRelayServer/main.swift Tests/ClaudeRelayServerTests/PairCreateRouteTests.swift Tests/ClaudeRelayServerTests/AdminRoutesEndpointTests.swift
git commit -m "feat(server): POST /pair/create admin route mints pairing codes"
```

---

### Task 6: `handlePairRequest` — redeem pre-auth over the WebSocket

**Files:**
- Modify: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`
- Modify: `Sources/ClaudeRelayServer/Network/WebSocketServer.swift` (thread the store)
- Modify: `Sources/ClaudeRelayServer/main.swift` (pass the store to `WebSocketServer`)
- Test: `Tests/ClaudeRelayServerTests/PairRequestHandlerTests.swift`
- Test: `Tests/ClaudeRelayServerTests/RelayMessageHandlerTests.swift` (update `makeFixture`)

**Interfaces:**
- Consumes: `PairingCodeStore.redeem(_:)` (Task 4), `ClientMessage.pairRequest` / `ServerMessage.pairSuccess` (Task 3), `TokenStore.create(label:expiryDays:)`.
- Produces: pre-auth handling of `pair_request`; `RelayMessageHandler.init(…, pairingStore: PairingCodeStore)` with **no default**.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import Foundation
import NIO
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import ClaudeRelayKit
@testable import ClaudeRelayServer

/// Covers the pre-auth `pair_request` branch: a valid code mints a token, a
/// bad code is rate-limited, and pairing does not by itself authenticate.
final class PairRequestHandlerTests: XCTestCase {

    private struct Fixture {
        let channel: NIOAsyncTestingChannel
        let handler: RelayMessageHandler
        let tokenStore: TokenStore
        let pairingStore: PairingCodeStore
        let tempDir: URL
    }

    private func makeFixture(
        rateLimiter: RateLimiter? = nil,
        pairingStore: PairingCodeStore = PairingCodeStore()
    ) async throws -> Fixture {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairRequestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let tokenStore = TokenStore(directory: tempDir)
        let config = RelayConfig(detachTimeout: 5, scrollbackSize: 4096)
        let manager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )
        let handler = RelayMessageHandler(
            sessionManager: manager,
            tokenStore: tokenStore,
            rateLimiter: rateLimiter ?? RateLimiter(maxAttempts: 100, windowSeconds: 60),
            clipboardService: NoopClipboardService(),
            pushStore: PushRegistrationStore(directory: tempDir),
            pairingStore: pairingStore
        )
        let channel = await NIOAsyncTestingChannel(handler: handler)
        let sentinel = try SocketAddress(ipAddress: "127.0.0.1", port: 9999)
        try await channel.connect(to: sentinel).get()
        try await Task.sleep(for: .milliseconds(30))
        return Fixture(channel: channel, handler: handler, tokenStore: tokenStore,
                       pairingStore: pairingStore, tempDir: tempDir)
    }

    private func cleanup(_ fixture: Fixture) async {
        _ = try? await fixture.channel.finish()
        try? FileManager.default.removeItem(at: fixture.tempDir)
    }

    private func textFrame(_ json: String) -> WebSocketFrame {
        let utf8 = Array(json.utf8)
        var buf = ByteBufferAllocator().buffer(capacity: utf8.count)
        buf.writeBytes(utf8)
        return WebSocketFrame(fin: true, opcode: .text, data: buf)
    }

    private func send(_ frame: WebSocketFrame, on fixture: Fixture) async throws {
        try await fixture.channel.writeInbound(frame)
        try await Task.sleep(for: .milliseconds(40))
    }

    private func serverMessages(_ channel: NIOAsyncTestingChannel) async throws -> [ServerMessage] {
        var out: [ServerMessage] = []
        while let frame: WebSocketFrame = try await channel.readOutbound() {
            guard frame.opcode == .text else { continue }
            let buffer = frame.data
            let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
            let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: Data(bytes))
            if case .server(let msg) = envelope { out.append(msg) }
        }
        return out
    }

    private func pairFrame(code: String) -> WebSocketFrame {
        textFrame("""
        {"type":"pair_request","payload":{"code":"\(code)","deviceName":"Test iPhone","platform":"ios"}}
        """)
    }

    // MARK: - Happy path

    func testValidCodeMintsTokenAndReturnsPairSuccess() async throws {
        let store = PairingCodeStore()
        let fixture = try await makeFixture(pairingStore: store)
        defer { Task { await cleanup(fixture) } }

        let grant = await store.mint(label: "Test iPhone")
        try await send(pairFrame(code: grant.code), on: fixture)

        let messages = try await serverMessages(fixture.channel)
        guard let success = messages.compactMap({ msg -> (String, String, String)? in
            if case .pairSuccess(let token, let tokenId, let label) = msg { return (token, tokenId, label) }
            return nil
        }).first else {
            return XCTFail("expected pair_success, got \(messages)")
        }

        XCTAssertFalse(success.0.isEmpty, "token must be returned")
        XCTAssertFalse(success.1.isEmpty, "tokenId must be returned")
        XCTAssertTrue(success.2.contains("Test iPhone"), "label should name the device, got \(success.2)")

        // The returned token must actually validate.
        let info = await fixture.tokenStore.validate(token: success.0)
        XCTAssertNotNil(info, "minted token must be valid")
        XCTAssertEqual(info?.id, success.1)
    }

    func testPairingAloneDoesNotAuthenticate() async throws {
        let store = PairingCodeStore()
        let fixture = try await makeFixture(pairingStore: store)
        defer { Task { await cleanup(fixture) } }

        let grant = await store.mint(label: nil)
        try await send(pairFrame(code: grant.code), on: fixture)
        XCTAssertFalse(fixture.handler.isAuthenticated,
                       "pair_success must not authenticate; the client still sends auth_request")
    }

    func testPairThenAuthOnSameConnectionSucceeds() async throws {
        let store = PairingCodeStore()
        let fixture = try await makeFixture(pairingStore: store)
        defer { Task { await cleanup(fixture) } }

        let grant = await store.mint(label: "iPhone")
        try await send(pairFrame(code: grant.code), on: fixture)
        let paired = try await serverMessages(fixture.channel)
        guard case .pairSuccess(let token, _, _)? = paired.first(where: {
            if case .pairSuccess = $0 { return true } else { return false }
        }) else { return XCTFail("expected pair_success") }

        try await send(textFrame("""
        {"type":"auth_request","payload":{"token":"\(token)","protocolVersion":1}}
        """), on: fixture)

        XCTAssertTrue(fixture.handler.isAuthenticated, "the minted token must authenticate")
    }

    // MARK: - Failure paths

    func testUnknownCodeIsRejectedWith401() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanup(fixture) } }

        try await send(pairFrame(code: "00000000"), on: fixture)
        let messages = try await serverMessages(fixture.channel)
        let codes = messages.compactMap { msg -> Int? in
            if case .error(let code, _) = msg { return code }
            return nil
        }
        XCTAssertTrue(codes.contains(401), "expected a 401, got \(messages)")
        XCTAssertFalse(fixture.handler.isAuthenticated)
    }

    func testExpiredCodeIsRejected() async throws {
        // ttl 0 => expired the instant it is minted.
        let store = PairingCodeStore(ttl: 0)
        let fixture = try await makeFixture(pairingStore: store)
        defer { Task { await cleanup(fixture) } }

        let grant = await store.mint(label: nil)
        try await send(pairFrame(code: grant.code), on: fixture)
        let messages = try await serverMessages(fixture.channel)
        XCTAssertTrue(messages.contains { if case .error(401, _) = $0 { return true } else { return false } },
                      "expected 401 for an expired code, got \(messages)")
    }

    func testCodeCannotBeRedeemedTwiceAcrossConnections() async throws {
        let store = PairingCodeStore()
        let first = try await makeFixture(pairingStore: store)
        let grant = await store.mint(label: nil)
        try await send(pairFrame(code: grant.code), on: first)
        _ = try await serverMessages(first.channel)
        await cleanup(first)

        let second = try await makeFixture(pairingStore: store)
        defer { Task { await cleanup(second) } }
        try await send(pairFrame(code: grant.code), on: second)
        let messages = try await serverMessages(second.channel)
        XCTAssertTrue(messages.contains { if case .error(401, _) = $0 { return true } else { return false } },
                      "a redeemed code must not work again")
    }

    func testBadCodeRecordsRateLimiterFailure() async throws {
        let limiter = RateLimiter(maxAttempts: 2, windowSeconds: 60)
        let fixture = try await makeFixture(rateLimiter: limiter)
        defer { Task { await cleanup(fixture) } }

        try await send(pairFrame(code: "00000000"), on: fixture)
        try await send(pairFrame(code: "00000001"), on: fixture)
        try await Task.sleep(for: .milliseconds(50))

        // The handler's remoteIP is the sentinel address it connected to.
        let ip = fixture.handler.remoteIP
        XCTAssertTrue(await limiter.isBlocked(ip: ip),
                      "repeated bad codes must feed the shared rate limiter")
    }

    func testThreeBadCodesClosesTheConnection() async throws {
        let fixture = try await makeFixture()
        try await send(pairFrame(code: "00000000"), on: fixture)
        try await send(pairFrame(code: "00000001"), on: fixture)
        try await send(pairFrame(code: "00000002"), on: fixture)
        try await Task.sleep(for: .milliseconds(60))
        let active = fixture.channel.isActive
        try? FileManager.default.removeItem(at: fixture.tempDir)
        XCTAssertFalse(active, "the per-connection attempt cap should close the socket")
    }

    func testPairRequestAfterAuthIsRejected() async throws {
        let store = PairingCodeStore()
        let fixture = try await makeFixture(pairingStore: store)
        defer { Task { await cleanup(fixture) } }

        let (token, _) = try await fixture.tokenStore.create(label: "existing")
        try await send(textFrame("""
        {"type":"auth_request","payload":{"token":"\(token)","protocolVersion":1}}
        """), on: fixture)
        XCTAssertTrue(fixture.handler.isAuthenticated)
        _ = try await serverMessages(fixture.channel)

        let grant = await store.mint(label: nil)
        try await send(pairFrame(code: grant.code), on: fixture)
        let messages = try await serverMessages(fixture.channel)
        XCTAssertTrue(messages.contains { if case .error(400, _) = $0 { return true } else { return false } },
                      "pairing on an already-authenticated connection is a 400, got \(messages)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PairRequestHandlerTests`
Expected: FAIL — `RelayMessageHandler.init` has no `pairingStore:` parameter.

- [ ] **Step 3: Write minimal implementation**

Add the stored property and init parameter (**no default value**):

```swift
    private let pairingStore: PairingCodeStore
    /// Bad pairing codes on this connection. Mirrors `authAttempts`.
    private var pairAttempts = 0
    private static let maxPairAttempts = 3
```

```swift
    init(sessionManager: SessionManager, tokenStore: TokenStore, rateLimiter: RateLimiter,
         clipboardService: ClipboardService,
         pushStore: PushRegistrationStore = PushRegistrationStore(directory: RelayConfig.configDirectory),
         pairingStore: PairingCodeStore) {
        // ... existing assignments ...
        self.pairingStore = pairingStore
    }
```

Add the pre-auth case in `handleUnauthenticatedMessage`, before `default:`:

```swift
        case .pairRequest(let code, let deviceName, let platform):
            handlePairRequest(code: code, deviceName: deviceName, platform: platform, context: context)
```

Add to `handleAuthenticatedMessage`, next to the existing `.authRequest` rejection:

```swift
        case .pairRequest:
            sendServerMessage(.error(code: 400, message: "Already authenticated"), context: context)
```

Add the failure type next to `AuthFailure`:

```swift
    private enum PairFailure: Error {
        case invalidCode
    }
```

Add the handler near `handleAuth`:

```swift
    /// Redeem a one-time pairing code for a freshly minted per-device token.
    ///
    /// Runs **pre-auth**, so it is bounded by the same 10 s auth timer armed in
    /// `handlerAdded`: the client must follow `pair_success` with an
    /// `auth_request` inside that window. Pairing deliberately does NOT set
    /// `isAuthenticated` — the client authenticates with the token it just
    /// received, which keeps exactly one code path for becoming authenticated.
    private func handlePairRequest(code: String, deviceName: String, platform: String,
                                   context: ChannelHandlerContext) {
        let pairingStore = self.pairingStore
        let tokenStore = self.tokenStore

        // Label the token after the device so it is identifiable and
        // individually revocable in `claude-relay token list`.
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmedName.isEmpty ? platform : String(trimmedName.prefix(60))
        let label = "\(safeName) (paired)"

        bridgeToEventLoop(
            context: context,
            work: {
                guard await pairingStore.redeem(code) != nil else {
                    throw PairFailure.invalidCode
                }
                let (plaintext, info) = try await tokenStore.create(label: label)
                return PairSuccessPayload(token: plaintext, tokenId: info.id, label: label)
            },
            onSuccess: { handler, ctx, payload in
                RelayLogger.log(category: "auth",
                    "Pairing succeeded for \(payload.label) — minted token \(payload.tokenId)")
                handler.sendServerMessage(
                    .pairSuccess(token: payload.token, tokenId: payload.tokenId, label: payload.label),
                    context: ctx
                )
            },
            onFailure: { handler, ctx, _ in
                handler.pairAttempts += 1
                let remote = handler.remoteIP
                RelayLogger.log(.error, category: "auth",
                    "Pairing failed — invalid code (attempt \(handler.pairAttempts)/\(Self.maxPairAttempts)) from \(remote)")
                let limiter = handler.rateLimiter
                Task { await limiter.recordFailure(ip: remote) }
                handler.sendServerMessage(
                    .error(code: 401, message: "Invalid or expired pairing code"), context: ctx)
                if handler.pairAttempts >= Self.maxPairAttempts {
                    ctx.close(promise: nil)
                }
            }
        )
    }
```

Add the payload struct next to `AuthSuccessPayload`:

```swift
    private struct PairSuccessPayload: Sendable {
        let token: String
        let tokenId: String
        let label: String
    }
```

In `WebSocketServer.swift`: add a stored `pairingStore` property, add `pairingStore: PairingCodeStore` to `init` (**no default**), and pass it into the `RelayMessageHandler(...)` construction in `upgradePipelineHandler` (~line 86).

In `main.swift`: pass `pairingStore: pairingStore` to `WebSocketServer(...)` (~line 78).

- [ ] **Step 4: Update the existing handler fixture**

`RelayMessageHandlerTests.makeFixture` constructs `RelayMessageHandler` and will no longer compile. Add `pairingStore: PairingCodeStore()` to that call.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter PairRequestHandlerTests`
Expected: PASS (9 tests).

Run: `swift test --filter RelayMessageHandlerTests`
Expected: PASS — no regressions.

Run: `swift test --filter WebSocketIntegrationTests`
Expected: PASS — the server still boots with the new required parameter.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift Sources/ClaudeRelayServer/Network/WebSocketServer.swift Sources/ClaudeRelayServer/main.swift Tests/ClaudeRelayServerTests/PairRequestHandlerTests.swift Tests/ClaudeRelayServerTests/RelayMessageHandlerTests.swift
git commit -m "feat(server): redeem pairing codes pre-auth via pair_request"
```

---

### Task 7: `ServiceManagerDetector` + nudges in every service command

**Files:**
- Create: `Sources/ClaudeRelayCLI/ServiceManagerDetector.swift`
- Modify: `Sources/ClaudeRelayCLI/Commands/ServiceCommands.swift`
- Test: `Tests/ClaudeRelayCLITests/ServiceManagerDetectorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum ServiceOwner: Equatable { case homebrew, launchAgent, both, none }`
  - `struct ServiceManagerDetector { init(homebrewPlistExists: Bool, launchAgentPlistExists: Bool, binaryPath: String); var owner: ServiceOwner; var installedViaHomebrew: Bool; func startCommand() -> String?; func stopCommand() -> String?; func restartCommand() -> String?; func nudge(for verb: ServiceVerb) -> String? }`
  - `enum ServiceVerb: String { case start, stop, restart, load, unload }`
  - `static let homebrewPlistName = "homebrew.mxcl.clauderelay.plist"`, `static let launchAgentPlistName = "com.claude.relay.plist"`
  - `static func detect() -> ServiceManagerDetector` (reads the real filesystem)

**Why this task exists:** on a Homebrew install — the documented path — `start`/`stop`/`restart`/`unload` currently target `com.claude.relay`, a label that was never loaded, and fail with a raw `launchctl failed:` error. Verified on this machine: `launchctl list` shows only `homebrew.mxcl.clauderelay`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeRelayCLI

final class ServiceManagerDetectorTests: XCTestCase {

    private func detector(brew: Bool, agent: Bool, binary: String = "/opt/homebrew/bin/claude-relay")
        -> ServiceManagerDetector {
        ServiceManagerDetector(homebrewPlistExists: brew, launchAgentPlistExists: agent, binaryPath: binary)
    }

    // MARK: - Owner resolution

    func testOwnerIsHomebrewWhenOnlyBrewPlistPresent() {
        XCTAssertEqual(detector(brew: true, agent: false).owner, .homebrew)
    }

    func testOwnerIsLaunchAgentWhenOnlyCLIPlistPresent() {
        XCTAssertEqual(detector(brew: false, agent: true).owner, .launchAgent)
    }

    func testOwnerIsBothWhenTwoManagersPresent() {
        XCTAssertEqual(detector(brew: true, agent: true).owner, .both)
    }

    func testOwnerIsNoneWhenNoPlistPresent() {
        XCTAssertEqual(detector(brew: false, agent: false).owner, .none)
    }

    // MARK: - Installer hint

    func testInstalledViaHomebrewForAppleSiliconPrefix() {
        XCTAssertTrue(detector(brew: false, agent: false, binary: "/opt/homebrew/bin/claude-relay").installedViaHomebrew)
    }

    func testInstalledViaHomebrewForIntelPrefix() {
        XCTAssertTrue(detector(brew: false, agent: false, binary: "/usr/local/bin/claude-relay").installedViaHomebrew)
    }

    func testLocalBuildIsNotHomebrew() {
        XCTAssertFalse(detector(brew: false, agent: false, binary: "/Users/me/CodeRelay/.build/debug/claude-relay").installedViaHomebrew)
    }

    // MARK: - Correct command per owner

    func testHomebrewOwnerYieldsBrewCommands() {
        let d = detector(brew: true, agent: false)
        XCTAssertEqual(d.startCommand(), "brew services start clauderelay")
        XCTAssertEqual(d.stopCommand(), "brew services stop clauderelay")
        XCTAssertEqual(d.restartCommand(), "brew services restart clauderelay")
    }

    func testLaunchAgentOwnerYieldsCLICommands() {
        let d = detector(brew: false, agent: true)
        XCTAssertEqual(d.startCommand(), "claude-relay start")
        XCTAssertEqual(d.stopCommand(), "claude-relay stop")
        XCTAssertEqual(d.restartCommand(), "claude-relay restart")
    }

    // MARK: - Nudges

    func testStartStopRestartAreNudgedUnderHomebrew() {
        let d = detector(brew: true, agent: false)
        for verb in [ServiceVerb.start, .stop, .restart] {
            let nudge = d.nudge(for: verb)
            XCTAssertNotNil(nudge, "\(verb) should be nudged under Homebrew")
            XCTAssertTrue(nudge!.contains("brew services"), "nudge should name the right tool: \(nudge!)")
        }
    }

    func testNoNudgeUnderLaunchAgentOwnership() {
        let d = detector(brew: false, agent: true)
        for verb in [ServiceVerb.start, .stop, .restart, .load, .unload] {
            XCTAssertNil(d.nudge(for: verb), "\(verb) is this manager's own command")
        }
    }

    func testLoadIsNudgedUnderHomebrewToAvoidASecondManager() {
        let nudge = detector(brew: true, agent: false).nudge(for: .load)
        XCTAssertNotNil(nudge)
        XCTAssertTrue(nudge!.contains("brew services start clauderelay"), nudge!)
    }

    func testLoadIsNotNudgedOnAFreshMachine() {
        XCTAssertNil(detector(brew: false, agent: false).nudge(for: .load))
    }

    func testBothManagersProduceAWarningForEveryVerb() {
        let d = detector(brew: true, agent: true)
        for verb in [ServiceVerb.start, .stop, .restart, .load, .unload] {
            let nudge = d.nudge(for: verb)
            XCTAssertNotNil(nudge, "\(verb) should warn when two managers exist")
            XCTAssertTrue(nudge!.lowercased().contains("two"), nudge!)
        }
    }

    func testStartOnFreshMachineNudgesTowardSetup() {
        let nudge = detector(brew: false, agent: false).nudge(for: .start)
        XCTAssertNotNil(nudge)
        XCTAssertTrue(nudge!.contains("claude-relay setup"), nudge!)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ServiceManagerDetectorTests`
Expected: FAIL — "cannot find 'ServiceManagerDetector' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Which launchd manager owns the relay service.
enum ServiceOwner: Equatable {
    case homebrew
    case launchAgent
    case both
    case none
}

enum ServiceVerb: String {
    case start, stop, restart, load, unload
}

/// Works out which launchd manager owns the service so the CLI never drives the
/// wrong label.
///
/// Two managers exist and they are mutually exclusive in practice:
///
/// | Manager             | Label / plist                  |
/// | ------------------- | ------------------------------ |
/// | `brew services`     | `homebrew.mxcl.clauderelay`    |
/// | `claude-relay load` | `com.claude.relay`             |
///
/// Every service command used to hardcode `com.claude.relay`, so on a Homebrew
/// install — the documented path — `start`/`stop`/`restart`/`unload` failed with
/// a raw `launchctl failed:` error against a label that was never loaded.
/// `status`/`health` were unaffected because they talk to the admin HTTP API.
struct ServiceManagerDetector {

    static let homebrewPlistName = "homebrew.mxcl.clauderelay.plist"
    static let launchAgentPlistName = "com.claude.relay.plist"

    private let homebrewPlistExists: Bool
    private let launchAgentPlistExists: Bool
    private let binaryPath: String

    init(homebrewPlistExists: Bool, launchAgentPlistExists: Bool, binaryPath: String) {
        self.homebrewPlistExists = homebrewPlistExists
        self.launchAgentPlistExists = launchAgentPlistExists
        self.binaryPath = binaryPath
    }

    /// Reads the real filesystem. Injected values are used by tests.
    static func detect() -> ServiceManagerDetector {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let fm = FileManager.default
        return ServiceManagerDetector(
            homebrewPlistExists: fm.fileExists(
                atPath: launchAgents.appendingPathComponent(homebrewPlistName).path),
            launchAgentPlistExists: fm.fileExists(
                atPath: launchAgents.appendingPathComponent(launchAgentPlistName).path),
            binaryPath: CommandLine.arguments.first ?? ""
        )
    }

    var owner: ServiceOwner {
        switch (homebrewPlistExists, launchAgentPlistExists) {
        case (true, true):   return .both
        case (true, false):  return .homebrew
        case (false, true):  return .launchAgent
        case (false, false): return .none
        }
    }

    /// True when this CLI binary lives under a Homebrew prefix — used to nudge
    /// about the *installer* on a machine with no service installed yet.
    var installedViaHomebrew: Bool {
        binaryPath.hasPrefix("/opt/homebrew/") || binaryPath.hasPrefix("/usr/local/")
    }

    func startCommand() -> String? { command(for: .start) }
    func stopCommand() -> String? { command(for: .stop) }
    func restartCommand() -> String? { command(for: .restart) }

    private func command(for verb: ServiceVerb) -> String? {
        switch owner {
        case .homebrew, .both: return "brew services \(verb.rawValue) clauderelay"
        case .launchAgent:     return "claude-relay \(verb.rawValue)"
        case .none:            return nil
        }
    }

    /// A message to print instead of driving the wrong manager, or nil when the
    /// command is the right one for this host.
    ///
    /// Deliberately a *nudge*: we print the correct command rather than shelling
    /// out to Homebrew on the user's behalf. A command documented as driving
    /// launchctl silently invoking brew would be surprising, and the nudge
    /// teaches the right tool for next time.
    func nudge(for verb: ServiceVerb) -> String? {
        switch owner {
        case .both:
            return """
            Two service managers are installed for clauderelay:
              • \(Self.homebrewPlistName) (Homebrew)
              • \(Self.launchAgentPlistName) (claude-relay load)
            Both will try to bind the WebSocket port. Remove one before continuing:
              brew services stop clauderelay     # keep the CLI-managed agent
              claude-relay unload                # keep the Homebrew-managed one
            """

        case .homebrew:
            if verb == .load {
                return """
                clauderelay is managed by Homebrew services.
                Running `load` would install a second launchd agent competing for the same port.
                Use this instead:
                  brew services start clauderelay
                Pass --force to install the CLI-managed agent anyway.
                """
            }
            if verb == .unload {
                return """
                clauderelay is managed by Homebrew services; `unload` only removes a
                CLI-installed agent, and there isn't one. To stop the running service:
                  brew services stop clauderelay
                """
            }
            return """
            clauderelay is managed by Homebrew services. Use:
              brew services \(verb.rawValue) clauderelay
            """

        case .launchAgent:
            return nil

        case .none:
            switch verb {
            case .load:
                return nil
            case .unload:
                return "No service is installed — nothing to unload."
            case .start, .stop, .restart:
                let installer = installedViaHomebrew
                    ? "  brew services start clauderelay"
                    : "  claude-relay setup"
                return """
                No service is installed yet, so there is nothing to \(verb.rawValue).
                Install and start it with:
                \(installer)
                """
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ServiceManagerDetectorTests`
Expected: PASS (15 tests).

- [ ] **Step 5: Wire the nudges into `ServiceCommands.swift`**

Add a shared helper in that file:

```swift
/// Prints the nudge and returns true when the caller should stop.
/// `--quiet` suppresses the text but still blocks the wrong action.
private func nudgeBlocks(_ verb: ServiceVerb, quiet: Bool) -> Bool {
    guard let nudge = ServiceManagerDetector.detect().nudge(for: verb) else { return false }
    if !quiet { print(nudge) }
    return true
}
```

Then, as the first statement of each `run()`:

- `StartCommand`: `if nudgeBlocks(.start, quiet: globals.quiet) { throw ExitCode.failure }`
- `StopCommand`: `if nudgeBlocks(.stop, quiet: globals.quiet) { throw ExitCode.failure }`
- `RestartCommand`: `if nudgeBlocks(.restart, quiet: globals.quiet) { throw ExitCode.failure }`
- `UnloadCommand`: `if nudgeBlocks(.unload, quiet: globals.quiet) { throw ExitCode.failure }`
- `LoadCommand`: add `@Flag(name: .long, help: "Install the CLI-managed agent even if another manager owns the service") var force = false`, then `if !force, nudgeBlocks(.load, quiet: globals.quiet) { throw ExitCode.failure }`

In `StatusCommand.run()`, after a successful status print, report the owner:

```swift
        let owner = ServiceManagerDetector.detect().owner
        if globals.json {
            // owner is added to the JSON payload below
        } else if !globals.quiet {
            switch owner {
            case .homebrew:    print("  Managed by: Homebrew services")
            case .launchAgent: print("  Managed by: claude-relay (launchd agent)")
            case .both:        print("  Managed by: WARNING — two managers installed")
            case .none:        print("  Managed by: no launchd agent installed")
            }
        }
```

For `--json`, add a `"manager"` string field (`"homebrew"`, `"launchAgent"`, `"both"`, `"none"`) to the emitted object.

- [ ] **Step 6: Verify the fix by hand on this machine**

This machine is Homebrew-managed, so this is a real before/after check.

Run: `swift build 2>&1 | tail -5`
Expected: builds clean.

Run: `swift run claude-relay stop`
Expected: prints the `brew services stop clauderelay` nudge and exits non-zero — **not** a `launchctl failed:` error, and the running server is untouched.

Run: `swift run claude-relay status`
Expected: normal status output plus `Managed by: Homebrew services`.

Run: `swift run claude-relay health`
Expected: `OK` — the live server is still running and was never stopped.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeRelayCLI/ServiceManagerDetector.swift Sources/ClaudeRelayCLI/Commands/ServiceCommands.swift Tests/ClaudeRelayCLITests/ServiceManagerDetectorTests.swift
git commit -m "fix(cli): detect the owning launchd manager and nudge instead of driving the wrong label"
```

---

### Task 8: `TerminalQRRenderer` + `HostAddressResolver`

**Files:**
- Create: `Sources/ClaudeRelayCLI/TerminalQRRenderer.swift`
- Create: `Sources/ClaudeRelayCLI/HostAddressResolver.swift`
- Test: `Tests/ClaudeRelayCLITests/TerminalQRRendererTests.swift`
- Test: `Tests/ClaudeRelayCLITests/HostAddressResolverTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct TerminalQRRenderer { init(quietZone: Int = 2); func matrix(for payload: String) -> [[Bool]]?; func render(_ payload: String) -> String? }`
  - `enum HostCandidateKind { case bonjour, lan, loopback, cgnat }`
  - `struct HostCandidate: Equatable { let host: String; let kind: HostCandidateKind }`
  - `struct HostAddressResolver { static func choose(from candidates: [HostCandidate]) -> HostCandidate?; static func requiresTLS(_ candidate: HostCandidate) -> Bool }`

> **USER CONTRIBUTION POINT — `HostAddressResolver.choose`.** This is the ~8-line
> policy decision the user asked to own (spec §"Host selection policy"). The
> plan supplies the surrounding types, the tests, and `requiresTLS`; the ordering
> logic in `choose` is the user's to write. See Step 5.

- [ ] **Step 1: Write the failing QR test**

```swift
import XCTest
@testable import ClaudeRelayCLI

final class TerminalQRRendererTests: XCTestCase {

    private let payload = "coderelay://pair?host=silverwing.local&port=9200&tls=0&code=K7QP2M4X"

    func testMatrixIsSquareAndIncludesQuietZone() throws {
        let renderer = TerminalQRRenderer(quietZone: 2)
        let matrix = try XCTUnwrap(renderer.matrix(for: payload))
        XCTAssertFalse(matrix.isEmpty)
        for row in matrix {
            XCTAssertEqual(row.count, matrix.count, "matrix must be square")
        }
        // A 70-char payload at correction level M yields 39 modules; +2 quiet
        // zone each side = 43.
        XCTAssertEqual(matrix.count, 43)
    }

    func testQuietZoneIsAllLightModules() throws {
        let renderer = TerminalQRRenderer(quietZone: 2)
        let matrix = try XCTUnwrap(renderer.matrix(for: payload))
        for row in matrix.prefix(2) {
            XCTAssertFalse(row.contains(true), "top quiet zone must be blank")
        }
        for row in matrix.suffix(2) {
            XCTAssertFalse(row.contains(true), "bottom quiet zone must be blank")
        }
        for row in matrix {
            XCTAssertFalse(row.prefix(2).contains(true), "left quiet zone must be blank")
            XCTAssertFalse(row.suffix(2).contains(true), "right quiet zone must be blank")
        }
    }

    func testMatrixIsDeterministic() throws {
        let renderer = TerminalQRRenderer()
        let first = try XCTUnwrap(renderer.matrix(for: payload))
        let second = try XCTUnwrap(renderer.matrix(for: payload))
        XCTAssertEqual(first, second)
    }

    func testFinderPatternPresentAtTopLeftOfDataArea() throws {
        let renderer = TerminalQRRenderer(quietZone: 2)
        let matrix = try XCTUnwrap(renderer.matrix(for: payload))
        // A QR finder pattern is a 7x7 dark border; module (2,2) starts it.
        for i in 2..<9 {
            XCTAssertTrue(matrix[2][i], "top edge of finder pattern at col \(i)")
            XCTAssertTrue(matrix[i][2], "left edge of finder pattern at row \(i)")
        }
        XCTAssertFalse(matrix[4][4] == false && matrix[5][5] == false,
                       "finder pattern centre should be dark")
    }

    func testRenderUsesHalfHeightRowsAndExplicitColours() throws {
        let renderer = TerminalQRRenderer(quietZone: 2)
        let matrix = try XCTUnwrap(renderer.matrix(for: payload))
        let output = try XCTUnwrap(renderer.render(payload))
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        // Half-block glyphs pack two module rows per text row.
        XCTAssertEqual(lines.count, (matrix.count + 1) / 2)
        // Explicit SGR colours: a dark terminal theme would otherwise invert
        // the modules and most scanners fail on an inverted QR.
        XCTAssertTrue(output.contains("\u{1B}[38;2;"), "expected explicit foreground colour")
        XCTAssertTrue(output.contains("\u{1B}[48;2;"), "expected explicit background colour")
        XCTAssertTrue(output.contains("\u{1B}[0m"), "expected SGR reset")
    }

    func testRenderReturnsNilForEmptyPayload() {
        XCTAssertNil(TerminalQRRenderer().render(""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalQRRendererTests`
Expected: FAIL — "cannot find 'TerminalQRRenderer' in scope".

- [ ] **Step 3: Write the QR implementation**

```swift
import CoreImage
import Foundation

/// Renders a QR code as terminal text using half-block glyphs.
///
/// Uses CoreImage's `CIQRCodeGenerator`, a system framework, so this adds no
/// SPM dependency — the same generator the iOS and macOS apps already use for
/// session-sharing QR codes. It emits one pixel per QR module, which we read
/// back as a boolean matrix.
///
/// Two details matter for scannability:
///
/// 1. **Quiet zone.** The QR spec requires a light margin; without it many
///    scanners will not lock on.
/// 2. **Explicit colours.** We emit 24-bit SGR foreground/background rather than
///    inheriting the terminal theme. On a dark theme the modules would otherwise
///    be inverted, and most scanners fail on an inverted QR — the most common
///    way terminal QR codes break.
struct TerminalQRRenderer {

    /// Light modules of margin added on every side.
    let quietZone: Int

    init(quietZone: Int = 2) {
        self.quietZone = quietZone
    }

    /// `true` = dark module. Includes the quiet zone.
    func matrix(for payload: String) -> [[Bool]]? {
        guard !payload.isEmpty,
              let data = payload.data(using: .isoLatin1),
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let image = filter.outputImage else { return nil }
        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        // Software renderer: deterministic, and no GPU context in a CLI.
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = context.createCGImage(image, from: extent) else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let colourSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let bitmap = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: colourSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let side = width + quietZone * 2
        var result = [[Bool]](repeating: [Bool](repeating: false, count: side), count: side)
        for y in 0..<height {
            for x in 0..<width {
                // Dark module = low luminance.
                let dark = pixels[y * width + x] < 128
                result[y + quietZone][x + quietZone] = dark
            }
        }
        return result
    }

    /// Renders the matrix as text, two module rows per line via half-blocks.
    func render(_ payload: String) -> String? {
        guard let matrix = matrix(for: payload) else { return nil }

        // Dark modules black, light modules white, regardless of theme.
        let dark = "\u{1B}[38;2;0;0;0m"
        let light = "\u{1B}[48;2;255;255;255m"
        let reset = "\u{1B}[0m"

        var out = ""
        var row = 0
        while row < matrix.count {
            let top = matrix[row]
            let bottom = row + 1 < matrix.count
                ? matrix[row + 1]
                : [Bool](repeating: false, count: matrix.count)

            out += light + dark
            for column in 0..<matrix.count {
                switch (top[column], bottom[column]) {
                case (true, true):   out += "\u{2588}"  // full block
                case (true, false):  out += "\u{2580}"  // upper half
                case (false, true):  out += "\u{2584}"  // lower half
                case (false, false): out += " "
                }
            }
            out += reset + "\n"
            row += 2
        }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalQRRendererTests`
Expected: PASS (6 tests).

If `testMatrixIsSquareAndIncludesQuietZone` reports a module count other than 39+4, the payload length changed the QR version. Update the expected number to the observed one and note it — the assertion exists to catch accidental payload bloat, not to pin a magic constant.

- [ ] **Step 5: Write the host-resolver test, then hand `choose` to the user**

Create `Tests/ClaudeRelayCLITests/HostAddressResolverTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayCLI

final class HostAddressResolverTests: XCTestCase {

    private let bonjour = HostCandidate(host: "silverwing.local", kind: .bonjour)
    private let lan = HostCandidate(host: "192.168.1.42", kind: .lan)
    private let loopback = HostCandidate(host: "127.0.0.1", kind: .loopback)
    private let cgnat = HostCandidate(host: "100.101.102.103", kind: .cgnat)

    func testPrefersBonjourOverLAN() {
        XCTAssertEqual(HostAddressResolver.choose(from: [lan, bonjour]), bonjour)
    }

    func testFallsBackToLANWhenNoBonjourName() {
        XCTAssertEqual(HostAddressResolver.choose(from: [loopback, lan]), lan)
    }

    func testFallsBackToLoopbackAsLastResort() {
        XCTAssertEqual(HostAddressResolver.choose(from: [loopback]), loopback)
    }

    func testNeverSilentlyChoosesCGNAT() {
        // ATS has no CIDR allowlist, so plaintext ws:// to Tailscale CGNAT is
        // blocked by the platform. It must not be selected over a usable option.
        XCTAssertEqual(HostAddressResolver.choose(from: [cgnat, lan]), lan)
        XCTAssertEqual(HostAddressResolver.choose(from: [cgnat, bonjour]), bonjour)
    }

    func testReturnsNilWhenNoCandidates() {
        XCTAssertNil(HostAddressResolver.choose(from: []))
    }

    func testCGNATRequiresTLS() {
        XCTAssertTrue(HostAddressResolver.requiresTLS(cgnat))
    }

    func testLocalCandidatesDoNotRequireTLS() {
        XCTAssertFalse(HostAddressResolver.requiresTLS(bonjour))
        XCTAssertFalse(HostAddressResolver.requiresTLS(lan))
        XCTAssertFalse(HostAddressResolver.requiresTLS(loopback))
    }
}
```

Create `Sources/ClaudeRelayCLI/HostAddressResolver.swift` with everything except the policy body:

```swift
import Foundation

/// How a candidate host address was obtained, which determines whether the
/// apps can reach it over plaintext `ws://`.
enum HostCandidateKind: Equatable {
    /// Bonjour name from `scutil --get LocalHostName`, e.g. `silverwing.local`.
    /// Survives DHCP lease changes, and `.local` is inside the apps'
    /// `NSAllowsLocalNetworking` ATS allowlist.
    case bonjour
    /// RFC1918 literal from `ipconfig getifaddr en0`. Always resolves, but goes
    /// stale when the lease changes.
    case lan
    /// `127.0.0.1` — only useful for a Mac pairing to itself.
    case loopback
    /// Tailscale CGNAT (`100.64/10`). ATS has no CIDR allowlist, so plaintext
    /// `ws://` to it is blocked by Apple at the platform layer; it needs `wss://`.
    case cgnat
}

struct HostCandidate: Equatable {
    let host: String
    let kind: HostCandidateKind
}

struct HostAddressResolver {

    /// True when the apps cannot reach this candidate over plaintext `ws://`.
    static func requiresTLS(_ candidate: HostCandidate) -> Bool {
        candidate.kind == .cgnat
    }

    /// Picks the address that goes into the pairing QR.
    ///
    /// Trade-off to weigh: `.bonjour` survives a DHCP lease change and is
    /// ATS-safe, but can fail to resolve on networks with mDNS filtering, where
    /// a `.lan` literal would have worked. `.cgnat` must never win over a
    /// usable local candidate because plaintext `ws://` to it cannot connect
    /// at all.
    ///
    /// TODO(user): implement the ordering policy.
    static func choose(from candidates: [HostCandidate]) -> HostCandidate? {
        fatalError("Implement the host-selection policy — see HostAddressResolverTests")
    }
}
```

**STOP HERE and ask the user to implement `choose`.** Show them the test file and the trade-off comment. Do not implement it for them, and do not proceed to Step 6 until they have.

- [ ] **Step 6: Run the resolver test to verify the user's implementation passes**

Run: `swift test --filter HostAddressResolverTests`
Expected: PASS (7 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeRelayCLI/TerminalQRRenderer.swift Sources/ClaudeRelayCLI/HostAddressResolver.swift Tests/ClaudeRelayCLITests/TerminalQRRendererTests.swift Tests/ClaudeRelayCLITests/HostAddressResolverTests.swift
git commit -m "feat(cli): terminal QR renderer + host address selection policy"
```

---

### Task 9: `claude-relay setup`

**Files:**
- Create: `Sources/ClaudeRelayCLI/Commands/SetupCommand.swift`
- Modify: `Sources/ClaudeRelayCLI/CLIRoot.swift` (register the subcommand)
- Test: `Tests/ClaudeRelayCLITests/SetupCommandTests.swift`

**Interfaces:**
- Consumes: `ServiceManagerDetector.detect()` (Task 7), `TerminalQRRenderer`, `HostAddressResolver`, `HostCandidate` (Task 8), `PairingURL` (Task 2), `AdminClient.post`, `PairingCode.formatted` (Task 1).
- Produces: `struct SetupCommand: AsyncParsableCommand`, plus a testable pure helper:
  `SetupPresenter.render(url: PairingURL, formattedCode: String, expiresAt: Date, now: Date, host: HostCandidate, includeQR: Bool) -> String`.

Keeping presentation in a pure `SetupPresenter` is what makes this task testable without booting a server.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeRelayCLI
@testable import ClaudeRelayKit

final class SetupCommandTests: XCTestCase {

    private let url = PairingURL(host: "silverwing.local", port: 9200, useTLS: false, code: "K7QP2M4X")
    private let host = HostCandidate(host: "silverwing.local", kind: .bonjour)
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func render(includeQR: Bool = true, secondsLeft: TimeInterval = 298) -> String {
        SetupPresenter.render(
            url: url,
            formattedCode: PairingCode.formatted("K7QP2M4X"),
            expiresAt: now.addingTimeInterval(secondsLeft),
            now: now,
            host: host,
            includeQR: includeQR
        )
    }

    func testOutputShowsTheHostAndWhyItWasChosen() {
        let output = render()
        XCTAssertTrue(output.contains("silverwing.local"), output)
        XCTAssertTrue(output.lowercased().contains("bonjour"), output)
    }

    func testOutputShowsTheGroupedCode() {
        XCTAssertTrue(render().contains("K7QP-2M4X"))
    }

    func testOutputShowsRemainingTimeAsMinutesAndSeconds() {
        XCTAssertTrue(render(secondsLeft: 298).contains("4:58"), render(secondsLeft: 298))
    }

    func testOutputNeverContainsAToken() {
        // Only a code is displayed. The token is minted later, over the socket.
        let output = render().lowercased()
        XCTAssertFalse(output.contains("token"), "setup must not display any token")
    }

    func testNoQRModeStillShowsCodeAndURL() {
        let output = render(includeQR: false)
        XCTAssertTrue(output.contains("K7QP-2M4X"))
        XCTAssertTrue(output.contains(url.urlString), output)
        XCTAssertFalse(output.contains("\u{2588}"), "no-qr mode must not draw blocks")
    }

    func testQRModeDrawsBlocks() {
        let output = render(includeQR: true)
        let hasBlocks = output.contains("\u{2588}") || output.contains("\u{2580}") || output.contains("\u{2584}")
        XCTAssertTrue(hasBlocks, "QR mode should draw half-block glyphs")
    }

    func testOutputMentionsTheOptionalHookCommand() {
        XCTAssertTrue(render().contains("claude-relay hook install"), render())
    }

    func testExpiredGrantSaysSo() {
        let output = render(secondsLeft: -1)
        XCTAssertTrue(output.lowercased().contains("expired"), output)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SetupCommandTests`
Expected: FAIL — "cannot find 'SetupPresenter' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import ArgumentParser
import Foundation
import ClaudeRelayKit

/// Pure presentation for `claude-relay setup`, split out so the output is
/// testable without booting a server or touching launchd.
struct SetupPresenter {

    static func render(
        url: PairingURL,
        formattedCode: String,
        expiresAt: Date,
        now: Date,
        host: HostCandidate,
        includeQR: Bool
    ) -> String {
        var out = ""

        let reason: String
        switch host.kind {
        case .bonjour:  reason = "Bonjour — survives DHCP, ATS-safe"
        case .lan:      reason = "LAN address — may change when the DHCP lease renews"
        case .loopback: reason = "loopback — only reachable from this Mac"
        case .cgnat:    reason = "Tailscale — requires TLS"
        }
        out += "✓ host: \(host.host)  (\(reason))\n\n"

        if includeQR, let qr = TerminalQRRenderer().render(url.urlString) {
            out += qr
            out += "\n"
        } else {
            out += "  \(url.urlString)\n\n"
        }

        out += "  scan in CodeRelay, or enter code:  \(formattedCode)\n"

        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 {
            out += "  this code has expired — run `claude-relay setup` again\n"
        } else {
            let minutes = Int(remaining) / 60
            let seconds = Int(remaining) % 60
            out += String(format: "  expires in %d:%02d\n", minutes, seconds)
        }

        out += "\nOptional: claude-relay hook install    (authoritative Claude Code state)\n"
        return out
    }
}

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Start the service and show a pairing QR code"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Override the host address put in the pairing code")
    var host: String?

    @Flag(name: .customLong("no-qr"), help: "Print the pairing URL and code without drawing a QR")
    var noQR = false

    @Option(name: .long, help: "Seconds the pairing code stays valid")
    var ttl: Int?

    @Option(name: .long, help: "Label for the token this pairing will mint")
    var label: String?

    func run() async throws {
        let client = AdminClient(port: globals.port)

        // 1. Ensure the service is up — via whichever manager owns it.
        if await !client.isServiceRunning() {
            try await startService()
            // Give the server a moment to bind before minting.
            try await Task.sleep(for: .seconds(1))
            guard await client.isServiceRunning() else {
                print("The service did not come up. Check: claude-relay logs show")
                throw ExitCode.failure
            }
        }

        // 2. Mint a pairing code.
        let response: PairCreateResponse = try await client.post(
            "/pair/create", body: PairCreateRequest(label: label))

        // 3. Resolve the host that goes in the QR.
        let candidate: HostCandidate
        if let host {
            candidate = HostCandidate(host: host, kind: .lan)
        } else {
            guard let chosen = HostAddressResolver.choose(from: HostAddressProbe.candidates()) else {
                print("Could not determine a host address. Pass --host explicitly.")
                throw ExitCode.failure
            }
            candidate = chosen
        }

        if HostAddressResolver.requiresTLS(candidate) && !response.tls {
            print("""
            The only reachable address (\(candidate.host)) needs TLS, but the server has none configured.
            Apple's ATS blocks plaintext ws:// to this address, so a pairing code would not connect.
            Configure TLS first:
              claude-relay config set tlsCert <path> tlsKey <path>
            """)
            throw ExitCode.failure
        }

        let url = PairingURL(host: candidate.host, port: response.wsPort,
                             useTLS: response.tls, code: response.code)

        if globals.json {
            print(OutputFormatter.formatJSON(SetupJSON(
                code: response.code, formattedCode: response.formattedCode,
                expiresAt: response.expiresAt, host: candidate.host,
                port: response.wsPort, tls: response.tls, url: url.urlString)))
            return
        }

        print(SetupPresenter.render(
            url: url,
            formattedCode: response.formattedCode,
            expiresAt: response.expiresAt,
            now: Date(),
            host: candidate,
            includeQR: !noQR
        ))
    }

    /// Starts the service using whichever manager owns it, so `setup` never
    /// installs a second competing launchd agent.
    private func startService() async throws {
        let detector = ServiceManagerDetector.detect()
        switch detector.owner {
        case .homebrew:
            print("Starting via Homebrew services…")
            try runShell(["/bin/sh", "-c", "brew services start clauderelay"])
        case .launchAgent:
            print("Starting the launchd agent…")
            var start = StartCommand()
            start.globals = globals
            try await start.run()
        case .both:
            print(detector.nudge(for: .start) ?? "Two service managers are installed.")
            throw ExitCode.failure
        case .none:
            print("Installing the launchd agent…")
            var load = LoadCommand()
            load.globals = globals
            try await load.run()
        }
    }
}

private struct PairCreateRequest: Encodable {
    let label: String?
}

struct PairCreateResponse: Decodable {
    let code: String
    let formattedCode: String
    let expiresAt: Date
    let wsPort: UInt16
    let tls: Bool
}

private struct SetupJSON: Encodable {
    let code: String
    let formattedCode: String
    let expiresAt: Date
    let host: String
    let port: UInt16
    let tls: Bool
    let url: String
}
```

Add `HostAddressProbe` to `HostAddressResolver.swift` — the impure half that shells out:

```swift
/// Reads the machine's actual addresses. Separate from `HostAddressResolver`
/// so the selection policy stays pure and testable.
struct HostAddressProbe {
    static func candidates() -> [HostCandidate] {
        var out: [HostCandidate] = []

        if let name = shellOutput(["/usr/sbin/scutil", "--get", "LocalHostName"]),
           !name.isEmpty {
            out.append(HostCandidate(host: "\(name.lowercased()).local", kind: .bonjour))
        }

        for interface in ["en0", "en1"] {
            if let ip = shellOutput(["/usr/sbin/ipconfig", "getifaddr", interface]), !ip.isEmpty {
                out.append(HostCandidate(host: ip, kind: kind(forIPv4: ip)))
            }
        }

        out.append(HostCandidate(host: "127.0.0.1", kind: .loopback))
        return out
    }

    /// Tailscale hands out `100.64/10`; treat that range as CGNAT.
    static func kind(forIPv4 ip: String) -> HostCandidateKind {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return .lan }
        if parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127 { return .cgnat }
        if parts[0] == 127 { return .loopback }
        return .lan
    }

    private static func shellOutput(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

Add a small shell helper to `SetupCommand.swift` (or reuse one if `ServiceCommands.swift` already exposes an equivalent):

```swift
func runShell(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())
    try process.run()
    process.waitUntilExit()
}
```

Register in `CLIRoot.swift`, first in the list so `--help` leads with it:

```swift
        subcommands: [
            SetupCommand.self,
            LoadCommand.self,
            // ... existing ...
        ]
```

> `AdminClient` must decode `expiresAt` as ISO8601. If its `JSONDecoder` does
> not already set `.dateDecodingStrategy = .iso8601`, set it — the admin API
> emits ISO8601 while the WebSocket path uses Doubles. Do not change the
> WebSocket coders.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SetupCommandTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Add a `HostAddressProbe` CGNAT-classification test**

Append to `HostAddressResolverTests.swift`:

```swift
    func testCGNATRangeIsClassifiedFromIPv4() {
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "100.101.102.103"), .cgnat)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "100.64.0.1"), .cgnat)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "100.127.255.254"), .cgnat)
        // 100.128.x is outside 100.64/10 and is a normal address.
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "100.128.0.1"), .lan)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "192.168.1.42"), .lan)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "127.0.0.1"), .loopback)
    }
```

Run: `swift test --filter HostAddressResolverTests`
Expected: PASS (8 tests).

- [ ] **Step 6: Verify end-to-end against the live server**

The service is already running on this machine, so `setup` should skip straight to minting.

Run: `swift run claude-relay setup --no-qr`
Expected: prints the chosen host, the `coderelay://pair?…` URL, a grouped code, and an expiry countdown. No token anywhere in the output.

Run: `swift run claude-relay setup`
Expected: the same, with a QR drawn above it. Scan it with a phone camera — it should resolve to the `coderelay://pair?…` URL (no app needed yet; Plan 1b adds the handler).

Run: `swift run claude-relay setup --json`
Expected: valid JSON containing `code`, `expiresAt`, `host`, `port`, `tls`, `url`.

Run: `swift run claude-relay health`
Expected: `OK` — the live server is untouched.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeRelayCLI/Commands/SetupCommand.swift Sources/ClaudeRelayCLI/HostAddressResolver.swift Sources/ClaudeRelayCLI/CLIRoot.swift Tests/ClaudeRelayCLITests/SetupCommandTests.swift Tests/ClaudeRelayCLITests/HostAddressResolverTests.swift
git commit -m "feat(cli): claude-relay setup — mint a pairing code and render a QR"
```

---

### Task 10: `claude-relay hook install|uninstall`

**Files:**
- Create: `Sources/ClaudeRelayCLI/Commands/HookCommands.swift`
- Modify: `Sources/ClaudeRelayCLI/CLIRoot.swift` (register `HookGroup`)
- Modify: `Scripts/hooks/README.md` (lead with the command)
- Test: `Tests/ClaudeRelayCLITests/HookSettingsMergeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct HookGroup: AsyncParsableCommand` with `install` / `uninstall`, plus the pure merge helper:
  - `HookSettingsMerger.merge(into settings: [String: Any], hookPath: String) -> (settings: [String: Any], addedEvents: [String])`
  - `HookSettingsMerger.remove(from settings: [String: Any], hookPath: String) -> (settings: [String: Any], removedEvents: [String])`
  - `HookSettingsMerger.events: [String]` — `["UserPromptSubmit", "PreToolUse", "Notification", "Stop"]`

The merge is pure and takes/returns a dictionary so idempotency and hook preservation are unit-testable without touching `~/.claude/settings.json`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeRelayCLI

final class HookSettingsMergeTests: XCTestCase {

    private let path = "~/.claude-relay/hooks/claude-relay-state-hook.sh"

    private func commands(_ settings: [String: Any], event: String) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any],
              let entries = hooks[event] as? [[String: Any]] else { return [] }
        return entries.flatMap { entry -> [String] in
            (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
        }
    }

    func testMergeAddsAllFourEventsToEmptySettings() {
        let (settings, added) = HookSettingsMerger.merge(into: [:], hookPath: path)
        XCTAssertEqual(Set(added), Set(HookSettingsMerger.events))
        for event in HookSettingsMerger.events {
            let cmds = commands(settings, event: event)
            XCTAssertEqual(cmds.count, 1, "\(event) should have one command")
            XCTAssertTrue(cmds[0].contains(path), cmds[0])
            XCTAssertTrue(cmds[0].hasSuffix(event), "the hook takes the event name as argv[1]: \(cmds[0])")
        }
    }

    func testMergeIsIdempotent() {
        let (once, _) = HookSettingsMerger.merge(into: [:], hookPath: path)
        let (twice, added) = HookSettingsMerger.merge(into: once, hookPath: path)
        XCTAssertTrue(added.isEmpty, "re-running should add nothing")
        for event in HookSettingsMerger.events {
            XCTAssertEqual(commands(twice, event: event).count, 1, "\(event) must not be duplicated")
        }
    }

    func testMergePreservesUnrelatedHooks() {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/my-own-hook"]]]]
            ],
            "theme": "dark"
        ]
        let (settings, added) = HookSettingsMerger.merge(into: existing, hookPath: path)
        XCTAssertEqual(settings["theme"] as? String, "dark", "unrelated keys must survive")
        let stopCommands = commands(settings, event: "Stop")
        XCTAssertTrue(stopCommands.contains("/usr/local/bin/my-own-hook"), "existing hook must survive")
        XCTAssertTrue(stopCommands.contains { $0.contains(path) }, "ours must be added alongside")
        XCTAssertTrue(added.contains("Stop"))
    }

    func testRemoveDropsOnlyOurEntries() {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/my-own-hook"]]]]
            ]
        ]
        let (installed, _) = HookSettingsMerger.merge(into: existing, hookPath: path)
        let (removed, events) = HookSettingsMerger.remove(from: installed, hookPath: path)
        XCTAssertTrue(events.contains("Stop"))
        let stopCommands = commands(removed, event: "Stop")
        XCTAssertEqual(stopCommands, ["/usr/local/bin/my-own-hook"], "only ours should go")
    }

    func testRemoveOnCleanSettingsIsANoOp() {
        let (settings, removed) = HookSettingsMerger.remove(from: [:], hookPath: path)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue((settings["hooks"] as? [String: Any] ?? [:]).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HookSettingsMergeTests`
Expected: FAIL — "cannot find 'HookSettingsMerger' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import ArgumentParser
import Foundation

/// Pure merge/removal of the CodeRelay state hook in a Claude Code settings
/// dictionary. Kept separate from file I/O so idempotency and
/// "don't clobber the user's own hooks" are unit-testable.
struct HookSettingsMerger {

    /// Claude Code lifecycle events the hook maps to relay states:
    /// UserPromptSubmit/PreToolUse → working, Notification → blocked, Stop → idle.
    static let events = ["UserPromptSubmit", "PreToolUse", "Notification", "Stop"]

    static func command(hookPath: String, event: String) -> String {
        "\(hookPath) \(event)"
    }

    static func merge(into settings: [String: Any], hookPath: String)
        -> (settings: [String: Any], addedEvents: [String]) {
        var out = settings
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        var added: [String] = []

        for event in events {
            let wanted = command(hookPath: hookPath, event: event)
            var entries = hooks[event] as? [[String: Any]] ?? []

            let alreadyPresent = entries.contains { entry in
                let inner = entry["hooks"] as? [[String: Any]] ?? []
                return inner.contains { ($0["command"] as? String)?.contains(hookPath) == true }
            }
            guard !alreadyPresent else { continue }

            entries.append(["hooks": [["type": "command", "command": wanted]]])
            hooks[event] = entries
            added.append(event)
        }

        out["hooks"] = hooks
        return (out, added)
    }

    static func remove(from settings: [String: Any], hookPath: String)
        -> (settings: [String: Any], removedEvents: [String]) {
        var out = settings
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        var removed: [String] = []

        for event in events {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            let before = entries.count

            entries = entries.compactMap { entry in
                guard var inner = entry["hooks"] as? [[String: Any]] else { return entry }
                inner.removeAll { ($0["command"] as? String)?.contains(hookPath) == true }
                if inner.isEmpty { return nil }
                var copy = entry
                copy["hooks"] = inner
                return copy
            }

            if entries.count != before { removed.append(event) }
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }

        out["hooks"] = hooks
        return (out, removed)
    }
}

struct HookGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Manage the Claude Code state hook",
        subcommands: [HookInstallCommand.self, HookUninstallCommand.self]
    )
}

struct HookInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the Claude Code state hook and register it in settings.json"
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: .long, help: "Show what would change without writing anything")
    var dryRun = false

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hooksDir = home.appendingPathComponent(".claude-relay/hooks")
        let destination = hooksDir.appendingPathComponent("claude-relay-state-hook.sh")
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        // Written into settings.json with ~ so the file stays portable.
        let displayPath = "~/.claude-relay/hooks/claude-relay-state-hook.sh"

        guard let source = HookInstallCommand.locateBundledScript() else {
            print("Could not find claude-relay-state-hook.sh. Expected it next to the CLI or in the repo's Scripts/hooks/.")
            throw ExitCode.failure
        }

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let (merged, added) = HookSettingsMerger.merge(into: settings, hookPath: displayPath)

        if dryRun {
            print("Would copy:  \(source.path)\n         to: \(destination.path)")
            print(added.isEmpty
                ? "settings.json already registers the hook for all events — no change."
                : "Would register events: \(added.joined(separator: ", "))")
            return
        }

        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

        if !added.isEmpty {
            // Back up before touching a file we don't own.
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                let backup = settingsURL.appendingPathExtension("coderelay-backup")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: settingsURL, to: backup)
                if !globals.quiet { print("Backed up settings.json → \(backup.lastPathComponent)") }
            }
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
        }

        if !globals.quiet {
            print("✓ hook installed at \(displayPath)")
            print(added.isEmpty
                ? "✓ settings.json already registered it — nothing to change"
                : "✓ registered events: \(added.joined(separator: ", "))")
            print("\nStart a session through CodeRelay to verify state is reported immediately.")
        }
    }

    /// Looks for the shipped script next to the CLI binary, in the Homebrew
    /// share directory, then in the repo (for a from-source run).
    static func locateBundledScript() -> URL? {
        let fm = FileManager.default
        let cliDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        let candidates = [
            cliDir.appendingPathComponent("claude-relay-state-hook.sh"),
            cliDir.appendingPathComponent("../share/clauderelay/claude-relay-state-hook.sh"),
            URL(fileURLWithPath: "/opt/homebrew/share/clauderelay/claude-relay-state-hook.sh"),
            URL(fileURLWithPath: "/usr/local/share/clauderelay/claude-relay-state-hook.sh"),
            URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent("Scripts/hooks/claude-relay-state-hook.sh")
        ]
        return candidates.first { fm.fileExists(atPath: $0.standardizedFileURL.path) }?
            .standardizedFileURL
    }
}

struct HookUninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the Claude Code state hook registration"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let displayPath = "~/.claude-relay/hooks/claude-relay-state-hook.sh"

        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if !globals.quiet { print("No settings.json found — nothing to remove.") }
            return
        }

        let (updated, removed) = HookSettingsMerger.remove(from: settings, hookPath: displayPath)
        guard !removed.isEmpty else {
            if !globals.quiet { print("The hook was not registered — nothing to remove.") }
            return
        }

        let out = try JSONSerialization.data(
            withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
        if !globals.quiet {
            print("✓ removed hook registration for: \(removed.joined(separator: ", "))")
            print("The script itself is still at \(displayPath) — delete it if you want it gone.")
        }
    }
}
```

Register in `CLIRoot.swift`: add `HookGroup.self` after `LogGroup.self`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HookSettingsMergeTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Verify the dry run touches nothing**

Run: `swift run claude-relay hook install --dry-run`
Expected: prints what it would copy and which events it would register.

Run: `git status --porcelain ~/.claude/settings.json 2>/dev/null; echo "exit=$?"`
Expected: no modification reported — `--dry-run` wrote nothing.

- [ ] **Step 6: Update `Scripts/hooks/README.md`**

Replace the manual `mkdir`/`cp`/`chmod` + JSON-merge instructions in the **Install** section with:

```markdown
## Install

```sh
claude-relay hook install
```

That copies the script to `~/.claude-relay/hooks/`, makes it executable, backs up
`~/.claude/settings.json`, and registers the four lifecycle events — adding only
what is missing, so it is safe to re-run and never clobbers hooks you already
have. Use `--dry-run` to preview, and `claude-relay hook uninstall` to reverse it.

<details>
<summary>Manual install (if you prefer to edit settings.json yourself)</summary>

[keep the existing manual steps here]
</details>
```

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeRelayCLI/Commands/HookCommands.swift Sources/ClaudeRelayCLI/CLIRoot.swift Tests/ClaudeRelayCLITests/HookSettingsMergeTests.swift Scripts/hooks/README.md
git commit -m "feat(cli): claude-relay hook install/uninstall with idempotent settings merge"
```

---

### Task 11: Docs + full-suite verification

**Files:**
- Modify: `README.md` (Quick Start leads with `setup`; document the service-manager nudge)
- Modify: `CLAUDE.md` (pairing + service-manager sections)

**Interfaces:**
- Consumes: everything above.
- Produces: no new code.

- [ ] **Step 1: Rewrite the README Quick Start**

Replace the current four numbered steps (lines ~64–98) with:

```markdown
## Quick Start

### 1. Install and pair

```bash
brew install miguelriotinto/claude-relay/clauderelay
claude-relay setup
```

`setup` starts the service (using whichever manager owns it — Homebrew or a
launchd agent), then prints a QR code. Scan it in the CodeRelay app and you are
connected: no IP address to look up, no token to type.

The QR carries a **single-use pairing code** that expires in five minutes, not
your auth token. The app exchanges it over the WebSocket for its own per-device
token, which shows up in `claude-relay token list` under the device's name and
can be revoked individually. If the camera is awkward, `setup` also prints a
short code you can type by hand.

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
```

Also add a `claude-relay setup` / `claude-relay hook install` line to the
**CLI Commands → Service Management** list (~line 102).

- [ ] **Step 2: Add a CLAUDE.md section**

Add after the "Configuration" section:

```markdown
## Device Pairing (F11)

`claude-relay setup` mints a **single-use pairing code** (8 chars Crockford
Base32 = 40 bits, 5-minute TTL) via `POST /pair/create` on the localhost-only
admin API, and renders it as a terminal QR encoding
`coderelay://pair?host=&port=&tls=&code=`.

The device redeems it **pre-auth** over the WebSocket: `pair_request` →
`pair_success{token,tokenId,label}` → then the normal `auth_request` with the
minted token, all on one socket inside the existing 10 s auth timer. Pairing
never sets `isAuthenticated`; the client authenticates with the token it just
received, so there is exactly one path to an authenticated connection.

- `PairingCodeStore` is **in-memory and injected with no default parameter** —
  it is constructed once in `main.swift` and shared by the admin route (mint) and
  every `RelayMessageHandler` (redeem). A defaulted parameter would give each
  connection an empty store and no code would ever redeem.
- A bad code is a `RateLimiter.recordFailure(ip:)`, identical to a bad token
  (10 attempts / 60 s as `main.swift` configures it), plus a per-connection cap
  of 3 mirroring `maxAuthAttempts`.
- The minted token is labeled `"<device> (paired)"` so it is revocable per device.
- `PairingURL` + `PairingCode` live in ClaudeRelayKit and are shared with all
  three clients — validation of hostile QR input happens in one tested place.

### Service manager awareness

Two launchd managers can own the server: `homebrew.mxcl.clauderelay` (from
`brew services`) and `com.claude.relay` (from `claude-relay load`). They must
never both exist — both would bind `wsPort`. `ServiceManagerDetector` resolves
the owner and every service command nudges with the correct command instead of
driving the wrong label; `load` refuses to create a second manager unless
`--force` is passed. Before this existed, `start`/`stop`/`restart`/`unload`
failed outright on a Homebrew install while `status`/`health` worked, because
only the latter two go through the admin HTTP API.
```

- [ ] **Step 3: Run every suite this plan touched**

Do **not** run a bare `swift test` — it hangs at `GitRootResolver` for
pre-existing reasons unrelated to this work.

```bash
swift test --filter PairingCodeTests
swift test --filter PairingURLTests
swift test --filter PairingMessageTests
swift test --filter PairingCodeStoreTests
swift test --filter PairCreateRouteTests
swift test --filter PairRequestHandlerTests
swift test --filter ServiceManagerDetectorTests
swift test --filter TerminalQRRendererTests
swift test --filter HostAddressResolverTests
swift test --filter SetupCommandTests
swift test --filter HookSettingsMergeTests
```

Expected: all PASS. Then the suites whose fixtures changed:

```bash
swift test --filter AdminRoutesEndpointTests
swift test --filter RelayMessageHandlerTests
swift test --filter WebSocketIntegrationTests
swift test --filter ClaudeRelayKitTests
swift test --filter ClaudeRelayCLITests
```

Expected: all PASS.

- [ ] **Step 4: Lint**

Run: `swiftlint --quiet 2>&1 | tail -20`
Expected: no new warnings from files this plan created. Fix any line over 140 chars.

- [ ] **Step 5: Confirm the live server survived**

Run: `swift run claude-relay health && swift run claude-relay status`
Expected: `OK` plus normal status including the manager line. This plan must never have stopped the running server.

- [ ] **Step 6: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: lead Quick Start with claude-relay setup; document pairing + service-manager awareness"
```

---

## Self-Review

**1. Spec coverage.** Every phase-1 spec section maps to a task:

| Spec section | Task |
| --- | --- |
| Pairing secret / code format | 1 |
| `PairingURL` deep link | 2 |
| Wire protocol (`pair_request`/`pair_success`) | 3 |
| `PairingCodeStore` (TTL, single-use, cap, shared instance) | 4 |
| Minting path (`POST /pair/create`, ISO8601) | 5 |
| The handshake, rate limiting, auditable token, 10 s timer reuse | 6 |
| Service-manager awareness + nudge table | 7 |
| `TerminalQRRenderer`, host-selection policy, CGNAT/TLS refusal | 8 |
| `claude-relay setup` + flags (`--host`, `--no-qr`, `--json`, `--ttl`) | 9 |
| `claude-relay hook install` (idempotent, backup, dry-run) | 10 |
| Docs (README, CLAUDE.md, hooks README) | 10, 11 |
| Trust boundary documented | 11 (CLAUDE.md) + README |

Deferred to **Plan 1b** by design: `PairingController`, the iOS/Android camera scanners, the macOS code-entry sheet, and the `pair` deep-link route. Deferred to **Plan 2**: `claude-relay provision`.

**2. Placeholders.** The only `fatalError`/TODO is `HostAddressResolver.choose`, which is the deliberate user-contribution point with its tests written and a hard stop before Step 6. No "TBD", no "add error handling", no "similar to Task N".

**3. Type consistency.** Verified across tasks: `PairingGrant` (`code`/`label`/`expiresAt`) is produced in Task 4 and consumed in 5 and 6. `PairingCode.length`/`formatted`/`normalize` from Task 1 are used in 2, 4, 5, 9. `PairingURL(host:port:useTLS:code:)` from Task 2 is used in 9. `HostCandidate`/`HostCandidateKind` from Task 8 are used in 9. `ServiceVerb`/`ServiceManagerDetector` from Task 7 are used in 9. `pairingStore:` is added to `AdminRoutes.handle` (5) and `RelayMessageHandler.init`/`WebSocketServer.init` (6), with the two existing test fixtures updated in the same tasks that break them (5 Step 4, 6 Step 4).
