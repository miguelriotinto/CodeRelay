# Star Trek Session Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a sixth session-naming theme, "Star Trek", with ~76 mixed-canon character names spanning TOS through Lower Decks. Surfaces automatically in iOS and Mac Settings Pickers via existing `allCases` iteration.

**Architecture:** Single-file change. `SessionNamingTheme` is a `CaseIterable` enum in the shared `ClaudeRelayClient` SPM target; both apps' Settings views iterate `allCases` and persist the user's pick via `@AppStorage`. Adding a `case starTrek` plus a names array makes the theme appear in both UIs and round-trips through persistence with no migration. Tests extend the existing `SessionNamingTests` suite to lock the new raw value and assert the pool is appropriately sized.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-05-19-star-trek-session-theme-design.md`

---

## File Structure

- **Modify:** `Sources/ClaudeRelayClient/Helpers/SessionNaming.swift`
  - Append `case starTrek` to `SessionNamingTheme`.
  - Add `displayName` and `names` arms.
  - Add `static let starTrekNames` array.
- **Modify:** `Tests/ClaudeRelayClientTests/SessionNamingTests.swift`
  - Extend `testThemeRawValuesAreStable` with the new case.
  - Add `testStarTrekPoolHasReasonableSize`.

No other files. The Mac and iOS `AppSettings.swift` and `SettingsView.swift`
files remain untouched: they already iterate `SessionNamingTheme.allCases`,
and `@AppStorage` round-trips any raw value.

---

## Task 1: Add the `starTrek` enum case and name pool

**Files:**
- Modify: `Sources/ClaudeRelayClient/Helpers/SessionNaming.swift`

This task does the production-code change. We do it before the tests because
two of the existing tests (`testEveryThemeHasNames`, `testEveryThemeHasAtLeastTenNames`,
`testAllThemesIdMatchesRawValue`) iterate `SessionNamingTheme.allCases` and
will fail to compile/run cleanly if a referenced case has no `names` arm. We
add the case and the array together, then in Task 2 we extend the
raw-value-stability test (the test that's truly TDD-flavoured: it asserts
a contract about the new case that the production code must keep).

- [ ] **Step 1: Append the enum case**

In `Sources/ClaudeRelayClient/Helpers/SessionNaming.swift`, change the case list:

Before:
```swift
public enum SessionNamingTheme: String, CaseIterable, Identifiable, Sendable {
    // Implicit raw values (case-name strings) are identical to the previous
    // explicit literals, so existing `@AppStorage` values round-trip unchanged.
    case gameOfThrones
    case viking
    case starWars
    case dune
    case lordOfTheRings
```

After:
```swift
public enum SessionNamingTheme: String, CaseIterable, Identifiable, Sendable {
    // Implicit raw values (case-name strings) are identical to the previous
    // explicit literals, so existing `@AppStorage` values round-trip unchanged.
    case gameOfThrones
    case viking
    case starWars
    case dune
    case lordOfTheRings
    case starTrek
```

- [ ] **Step 2: Extend `displayName`**

Change the switch in `displayName`:

Before:
```swift
    public var displayName: String {
        switch self {
        case .gameOfThrones: return "Game of Thrones"
        case .viking:        return "Viking"
        case .starWars:      return "Star Wars"
        case .dune:          return "Dune"
        case .lordOfTheRings: return "Lord of the Rings"
        }
    }
```

After:
```swift
    public var displayName: String {
        switch self {
        case .gameOfThrones: return "Game of Thrones"
        case .viking:        return "Viking"
        case .starWars:      return "Star Wars"
        case .dune:          return "Dune"
        case .lordOfTheRings: return "Lord of the Rings"
        case .starTrek:      return "Star Trek"
        }
    }
```

- [ ] **Step 3: Extend `names`**

Change the switch in `names`:

Before:
```swift
    public var names: [String] {
        switch self {
        case .gameOfThrones:  return Self.gotNames
        case .viking:         return Self.vikingNames
        case .starWars:       return Self.starWarsNames
        case .dune:           return Self.duneNames
        case .lordOfTheRings: return Self.lotrNames
        }
    }
```

After:
```swift
    public var names: [String] {
        switch self {
        case .gameOfThrones:  return Self.gotNames
        case .viking:         return Self.vikingNames
        case .starWars:       return Self.starWarsNames
        case .dune:           return Self.duneNames
        case .lordOfTheRings: return Self.lotrNames
        case .starTrek:       return Self.starTrekNames
        }
    }
```

- [ ] **Step 4: Add the `starTrekNames` array**

Append a new `static let` directly after the existing `lotrNames` block,
before the closing `}` of the enum. Insert this complete block:

```swift
    public static let starTrekNames = [
        "Kirk", "Spock", "McCoy", "Uhura", "Scotty",
        "Sulu", "Chekov", "Chapel", "Rand", "Sarek",
        "Khan", "Pike", "T'Pring", "Number One",
        "Picard", "Riker", "Data", "Worf", "La Forge",
        "Crusher", "Troi", "Wesley", "Guinan", "Q",
        "Ro Laren", "Pulaski", "Tasha Yar", "Barclay", "Lwaxana",
        "Sisko", "Kira", "Odo", "Bashir", "Dax",
        "O'Brien", "Quark", "Garak", "Rom", "Nog",
        "Jake", "Dukat", "Weyoun", "Martok", "Damar",
        "Ezri", "Janeway", "Chakotay", "Tuvok", "Paris",
        "Torres", "Kim", "Neelix", "Kes", "Seven",
        "The Doctor", "Archer", "T'Pol", "Trip", "Reed",
        "Mayweather", "Hoshi", "Phlox", "Burnham", "Saru",
        "Tilly", "Lorca", "Georgiou", "Stamets", "Una",
        "La'an", "M'Benga", "Ortegas", "Mariner", "Boimler",
        "Tendi", "Rutherford"
    ]
```

This array contains exactly 76 names (TOS 14 + TNG 15 + DS9 16 + VOY 10 +
ENT 7 + Modern 14). The order is by series for human readability;
`pickDefaultName` calls `randomElement()` so order has no functional
effect.

- [ ] **Step 5: Build to verify the change compiles**

Run: `swift build`
Expected: clean build, no errors. (Warnings unrelated to this change are
acceptable — investigate only if a new warning points to the modified
file.)

- [ ] **Step 6: Run the existing test suite to confirm nothing regressed**

Run: `swift test --filter SessionNamingTests`
Expected: all 8 existing tests pass. The pool size, non-empty, and
id-equals-rawValue tests now also cover `starTrek` because they
iterate `allCases`.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeRelayClient/Helpers/SessionNaming.swift
git commit -m "$(cat <<'EOF'
feat(naming): add Star Trek session theme

76-name mixed-canon pool spanning TOS, TNG, DS9, VOY, ENT, DSC, PIC,
SNW, and Lower Decks. Theme surfaces automatically in iOS and Mac
Settings Pickers via existing allCases iteration. Raw value
"starTrek" matches the lowerCamelCase convention used by the other
multi-word cases.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Lock the new raw value and pool size in tests

**Files:**
- Modify: `Tests/ClaudeRelayClientTests/SessionNamingTests.swift`

The raw value is persisted by `@AppStorage` in both apps, so renaming the
case later would silently reset users' theme preference to the default.
This task pins the raw value in a test (matching the precedent set for
every other theme) and adds a separate test that the pool is large enough
to avoid the `"Session N"` fallback in normal use.

- [ ] **Step 1: Extend `testThemeRawValuesAreStable`**

In `Tests/ClaudeRelayClientTests/SessionNamingTests.swift`, change:

Before:
```swift
    func testThemeRawValuesAreStable() {
        // These raw values are persisted by @AppStorage on both iOS and Mac.
        // Renaming them requires a migration — this test prevents accidental rename.
        XCTAssertEqual(SessionNamingTheme.gameOfThrones.rawValue, "gameOfThrones")
        XCTAssertEqual(SessionNamingTheme.viking.rawValue, "viking")
        XCTAssertEqual(SessionNamingTheme.starWars.rawValue, "starWars")
        XCTAssertEqual(SessionNamingTheme.dune.rawValue, "dune")
        XCTAssertEqual(SessionNamingTheme.lordOfTheRings.rawValue, "lordOfTheRings")
    }
```

After:
```swift
    func testThemeRawValuesAreStable() {
        // These raw values are persisted by @AppStorage on both iOS and Mac.
        // Renaming them requires a migration — this test prevents accidental rename.
        XCTAssertEqual(SessionNamingTheme.gameOfThrones.rawValue, "gameOfThrones")
        XCTAssertEqual(SessionNamingTheme.viking.rawValue, "viking")
        XCTAssertEqual(SessionNamingTheme.starWars.rawValue, "starWars")
        XCTAssertEqual(SessionNamingTheme.dune.rawValue, "dune")
        XCTAssertEqual(SessionNamingTheme.lordOfTheRings.rawValue, "lordOfTheRings")
        XCTAssertEqual(SessionNamingTheme.starTrek.rawValue, "starTrek")
    }
```

- [ ] **Step 2: Add `testStarTrekPoolHasReasonableSize`**

Add this new test method to the `SessionNamingTests` class. Place it
inside the `// MARK: - Theme catalog` section, after
`testThemeRawValuesAreStable` and before `// MARK: - pickDefaultName`:

```swift
    func testStarTrekPoolHasReasonableSize() {
        // Star Trek is documented at ~76 names in the design spec.
        // Floor of 50 guards against accidental truncation that would
        // cause early "Session N" fallback while leaving room to prune
        // a few names without churning the test.
        XCTAssertGreaterThanOrEqual(
            SessionNamingTheme.starTrek.names.count, 50,
            "Star Trek pool unexpectedly small — \(SessionNamingTheme.starTrek.names.count) names"
        )
    }
```

- [ ] **Step 3: Run the new and updated tests**

Run: `swift test --filter SessionNamingTests`
Expected: 9 tests pass (8 original + 1 new). `testThemeRawValuesAreStable`
now also asserts the new case.

- [ ] **Step 4: Commit**

```bash
git add Tests/ClaudeRelayClientTests/SessionNamingTests.swift
git commit -m "$(cat <<'EOF'
test(naming): pin starTrek raw value and pool size

Adds the Star Trek raw-value assertion to the stability test
(matching the pattern used for every other theme) and a separate
test that guards against accidental truncation of the pool below
50 names — the floor below which "Session N" fallback would start
showing up in normal use.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Manual verification on both apps

**Files:** None modified. This is a verification task — do not skip it.
Catches regressions that no automated test would (e.g., the Picker
truncating the new label, or the new theme not appearing in Settings due
to a build-cache stale copy of `ClaudeRelayClient`).

- [ ] **Step 1: Verify on Mac**

1. In Xcode, open `ClaudeRelay.xcodeproj`.
2. Select the `ClaudeRelayMac` scheme.
3. Build & Run (⌘R).
4. Open Settings (⌘,) → scroll to **Session Naming** row.
5. Click the Picker. Confirm "Star Trek" appears as the last option
   below "Lord of the Rings".
6. Select "Star Trek". Close Settings.
7. Connect to a relay server and create a new session.
8. Confirm the auto-name is one of the Star Trek names (e.g., "Kirk",
   "Picard", "Burnham"…).
9. Quit and relaunch the app. Reopen Settings. Confirm Star Trek is
   still selected (persistence sanity check).

Expected: All steps pass. If the Picker omits the new theme, your
local SwiftPM cache for `ClaudeRelayClient` is stale — File → Packages
→ Reset Package Caches in Xcode and retry.

- [ ] **Step 2: Verify on iOS**

1. In Xcode, select the `ClaudeRelayApp` scheme and an iOS Simulator.
2. Build & Run (⌘R).
3. Open in-app Settings → **Session Naming**.
4. Confirm "Star Trek" appears in the Picker.
5. Select it. Create a new session. Confirm the auto-name is from
   the Star Trek pool.
6. Background the app, foreground it, reopen Settings, confirm Star
   Trek is still selected.

Expected: All steps pass.

- [ ] **Step 3: No commit**

This task produces no file changes. If verification turned up a bug,
go back to the relevant earlier task, fix, and re-verify. Do not paper
over a UI bug with a "fix-up" commit on top.

---

## Self-Review

**Spec coverage:** Each requirement in the spec maps to a task:
- Add `starTrek` enum case + `displayName` + `names` + array → Task 1
- Extend `testThemeRawValuesAreStable` → Task 2 Step 1
- Add `testStarTrekPoolHasReasonableSize` → Task 2 Step 2
- Manual verification (Mac and iOS Settings + new-session naming) → Task 3
- "No persistence migration; no other files change" — enforced by Task 1's
  scope (only `SessionNaming.swift` is staged in the commit) and validated
  by the existing test suite passing in Task 1 Step 6.

**Placeholder scan:** No TODOs, no "implement later", no "similar to
Task N", no missing code blocks. Every step that changes code shows the
exact code.

**Type consistency:** The case name `starTrek`, the static array
`starTrekNames`, the display string `"Star Trek"`, and the test method
`testStarTrekPoolHasReasonableSize` use consistent capitalisation
(`starTrek` lowerCamelCase as identifier, `Star Trek` two-word display
form, `StarTrek` PascalCase only in the test method name following the
existing `testEveryTheme...` convention).
