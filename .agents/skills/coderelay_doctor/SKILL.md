---
name: coderelay_doctor
description: Read-only health/version check across all ClaudeRelay deliverables — is the latest server running, is the latest APK on GitHub Releases, did the last TestFlight upload succeed. Use when the user asks "is everything published/running/up to date?"
---

# ClaudeRelay doctor

Read-only. Run all checks, then output ONE table. Never fix anything from this
skill — report and let the user decide.

## Checks

### Server
1. `Codex-relay status` (or `swift run Codex-relay status`) → running? version? uptime? sessions?
2. `curl -s http://127.0.0.1:9100/health` → ok?
3. Version coherence: status version vs `Formula/clauderelay.rb` vs the version
   constant in `Sources/`. The Homebrew Cellar symlink
   (`ls -l /opt/homebrew/bin/Codex-relay-server`) encodes the built commit —
   compare to the latest release commit.

### Android
1. Latest `android-v*` tag: `gh release list --limit 10`.
2. Its APK asset exists and `versionName` in the tag matches
   `versionName` in `ClaudeRelayAndroid/app/build.gradle.kts`. If gradle is
   ahead of the tag → flag "unreleased Android changes".

### iOS / macOS
1. Archive build numbers: `plutil -p build/ClaudeRelayApp.xcarchive/Info.plist`
   (and ClaudeRelayMac) → `CFBundleVersion` vs `project.yml`.
2. Last upload verdict: newest `$TMPDIR/<AppName>_*.xcdistributionlogs/ContentDelivery.log`,
   grep `UPLOAD SUCCEEDED` / error lines.
3. If the `asc` CLI is available, check TestFlight processing state of the
   latest build; otherwise note "processing state unknown — check App Store
   Connect".

### Working tree
`git status --porcelain` + commits since the last release tags → flag
"unshipped commits touching <platform> paths".

## Output

| Platform | Deployed/Published | Source of truth | Status |
|---|---|---|---|
| Server | vX.Y.Z (PID …) | Formula vX.Y.Z, code vX.Y.Z | ✅/⚠️ |
| Android | android-vX (APK vc NN) | gradle vc NN | ✅/⚠️ |
| iOS | build NNN uploaded ✓ | project.yml NNN | ✅/⚠️ |
| macOS | build NNN uploaded ✓ | project.yml NNN | ✅/⚠️ |

Follow with one line per ⚠️ explaining what's stale and the exact command or
skill (`/coderelay_ship <platform>`) that would fix it.
