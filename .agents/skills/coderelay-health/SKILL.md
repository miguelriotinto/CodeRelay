---
name: coderelay-health
description: Read-only health/version check across all CodeRelay deliverables — is the latest server running, is the latest APK on GitHub Releases, did the last TestFlight upload succeed. Use when the user asks "is everything published/running/up to date?"
---

# CodeRelay doctor

Read-only. Run all checks, then output ONE table. Never fix anything from this
skill — report and let the user decide.

## Checks

### Server
1. `claude-relay status` (or `swift run claude-relay status`) → running? version? uptime? sessions?
2. `curl -s http://127.0.0.1:9100/health` → ok?
3. Version coherence: status version vs `Formula/clauderelay.rb` vs the version
   constant in `Sources/`. The Homebrew Cellar symlink
   (`ls -l /opt/homebrew/bin/claude-relay-server`) encodes the built commit —
   compare to the latest release commit.

### Android
1. Latest `android-v*` tag: `gh release list --limit 10`.
2. Its APK asset exists and `versionName` in the tag matches
   `versionName` in `CodeRelayAndroid/app/build.gradle.kts`. If gradle is
   ahead of the tag → flag "unreleased Android changes".

### iOS / macOS
1. Archive build numbers: `plutil -p build/CodeRelayApp.xcarchive/Info.plist`
   (and CodeRelayMac) → `CFBundleVersion` vs `project.yml`.
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
skill (`/coderelay-deploy <platform>`) that would fix it.
