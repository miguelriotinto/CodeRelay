# Clickable links in the terminal — design (all clients)

Status: proposed 2026-11-18. Clients: iOS, macOS, Android, Linux. Optional server change.

## Goal

A URL shown in a terminal session opens in the device's own browser when the
user activates it, on every client, with one shared safety policy.

## Where each client stands today (verified 2026-11-18)

| Client | Detection available | Activation today | Gap |
|---|---|---|---|
| iOS (SwiftTerm 1.15) | `Terminal.link(at:mode: .explicitAndImplicit)` — OSC 8 first, then URL-shaped text, incl. soft-wrapped rows | none: `IOSTerminalCoordinator.requestOpenLink` is an empty stub, and SwiftTerm's tap path only opens a link that is hover-highlighted (`linkHighlightMode = .hover`), which a finger never is; `.always` accepts OSC 8 only | tap handling + delegate + policy |
| macOS (SwiftTerm 1.15) | same matcher | works: ⌘-hover underlines, ⌘-click opens via SwiftTerm's default `requestOpenLink` → `NSWorkspace.open` | **opens any scheme** (`file:`, `coderelay://`, other apps' schemes) — needs the policy |
| Android (termlib 0.1.0) | `TerminalEmulatorFactory.create(…, autoDetectUrls)`, `Terminal(onHyperlinkClick = …)`, OSC 8 + auto-detected | none: we pass neither | while a program tracks the mouse (Claude Code), `WheelSwipeOverlay` owns every touch, so termlib never sees the tap |
| Linux (own emulator over libvterm) | row text is available (selection uses it); no URL detection, no OSC 8 tracking | none | detection + activation + open |

The relay passes OSC 8 through untouched (`TerminalQueryFilter` strips only OSC
whose last field is `?`). The PTY sets only `TERM=xterm-256color`, so most tools
decide not to emit OSC 8 — plain-text URLs are the main case.

## Shared policy: `TerminalLinkPolicy`

One pure function per language, identical rules, one shared set of test vectors
(`Tests/Fixtures/terminal-links.json`, read by the Swift and Kotlin tests the way
`PairingURL` validation is shared):

```
decide(candidate: String, source: explicit | implicit, visibleText: String?) -> open(url) | confirm(url) | reject
```

- Allow only `http`, `https`, `mailto` (scheme case-insensitive). Everything else
  is `reject` — in particular `coderelay:` (our own pair/session deep links must
  never fire from text a host printed), `file:`, `javascript:`, `data:`, app schemes.
- Implicit matches: trim trailing `.,;:!?'"` and an unbalanced closing `)]}`.
- Reject control characters, whitespace, and anything over 2 048 bytes.
- `confirm` (sheet/dialog showing the full URL with Open / Copy / Cancel) when the
  source is explicit and the visible text is not the URL, or the URL carries
  userinfo (`https://bank.com@evil.example`). Otherwise `open`.
- Swift: `CodeRelayKit/TerminalLinkPolicy.swift`. Kotlin: `core-protocol`
  (`relay.protocol.TerminalLinkPolicy`), compiled into Linux like the rest.

Kotlin also gets `TerminalUrlDetector` (pure: row text + column → URL span),
needed by Linux and by the Android mouse-tracking path; it follows soft-wrapped
rows the way SwiftTerm does.

## Activation per client

- **iOS — tap.** `RelayTerminalView` adds a link tap recognizer; SwiftTerm's own
  single tap `require(toFail:)`s it, and its `gestureRecognizerShouldBegin` returns
  true only when `terminal.link(at:)` finds a link under the touch (the same
  pattern as the wheel pan). So a tap on a link opens it in both mouse modes, and
  every other tap behaves exactly as today. Long-press menu gains Open Link /
  Copy Link. Open with `UIApplication.shared.open` (honours the default browser).
- **macOS — ⌘-click (unchanged gesture).** `TerminalCoordinator` implements
  `requestOpenLink` → policy → `NSWorkspace.shared.open`; `confirm` is an
  `NSAlert`. A bare click stays a click: it belongs to the program or selection.
- **Android — tap.** Pass `autoDetectUrls = true` and `onHyperlinkClick` → policy
  → `Intent.ACTION_VIEW` (custom tab optional later). While tracking is on,
  `WheelSwipeOverlay.onTap` first asks for a URL at the tapped cell (termlib's
  `TerminalScreenState.getHyperlinkUrlAt(row, col, …)` if reachable from our
  side, else `TerminalUrlDetector` over row text) and opens it instead of only
  raising the keyboard.
- **Linux — Ctrl+click.** Bare click goes to the program while it tracks the
  mouse and selects otherwise (xterm rule, already implemented), so links use
  Ctrl+click, as in GNOME Terminal and others. Ctrl-hover underlines. Detection
  by `TerminalUrlDetector`; OSC 8 tracked by the emulator's OSC hook (phase 2 if
  libvterm makes it awkward). Open with `xdg-open` as an argv array, off the AWT
  thread, like `notify-send`.

## Open questions, resolved in step 0

1. **Long URLs in Claude Code.** Claude Code wraps its own output with real
   newlines, which would cut an implicit match at the first line break. Verify in
   a PTY probe whether it emits OSC 8 for URLs, and whether `FORCE_HYPERLINK=1`
   (plus `TERM_PROGRAM`) in the session environment makes it do so.
2. **If yes**, the server sets those variables in `PTYSession` (one line next to
   `TERM`), so explicit links carry the full URL on every client. Every client
   already parses OSC 8 safely. This changes what *all* tools emit in a relay
   session, so it ships as its own PR with its own note.

Out of scope for v1: rewriting `localhost` URLs to the relay host; persistent
underline of implicit links on iOS/Android.

## Release

- Apple: iOS 1.5.0 and Mac 1.2.0 are in their first App Review now; do not
  disturb them. The feature goes in the next marketing versions (iOS 1.6.0,
  Mac 1.3.0, a normal PR), `apple-release.yml` → TestFlight, then new App Store
  versions are created and submitted once 1.5.0 / 1.2.0 are approved.
- Android + Linux (+ server if step 0 says so): the next `vX.Y.Z` tag through
  `release.yml` (version trio + Android `versionCode`/`versionName`).
- A server change needs a relay restart on the host, which ends running
  sessions — the user does it.
