---
name: coderelay_ship
description: Build, publish, and VERIFY ClaudeRelay artifacts — iOS/macOS to TestFlight, Android APK to GitHub Releases, server to Homebrew. Args: ios | android | mac | server | all (default all)
disable-model-invocation: true
---

# Ship ClaudeRelay

Execute in order. Never skip the VERIFY phase — the whole point of this skill is
that "published" claims are proven, not assumed. If any step fails, stop and
report; do not continue to the next platform.

Target platforms come from the arguments (`ios`, `android`, `mac`, `server`,
or `all`). Default: `all`, but first check which platforms actually changed
since their last release tag and confirm the skip list with the user.

## 1. Preflight

1. `git status` must be clean and branch must be `main` (or ask).
2. Tests pass: `swift test` (server/kit) and, if shipping Android,
   `cd ClaudeRelayAndroid && ./gradlew testDebugUnitTest`.
3. Diff each platform's paths against its last release tag to decide what
   needs shipping (`Sources/` + `Formula/` → server; `ClaudeRelayApp/`,
   `ClaudeRelayClient`, `ClaudeRelaySpeech`, `ClaudeRelayKit` → iOS/mac;
   `ClaudeRelayAndroid/` → android).

## 2. Version bumps (only platforms being shipped)

- **iOS/macOS**: bump build number in `project.yml`, regenerate with `xcodegen`.
- **Android**: bump `versionCode` and `versionName` (`0.3-mNN` milestone
  scheme) in `ClaudeRelayAndroid/app/build.gradle.kts`, including the
  "M-NN version." comment above them.
- **Server**: bump the version constant + `Formula/clauderelay.rb`.
- Commit: `chore(release): <summary of bumps>` with the standard trailer.

## 3. Build & publish

- **iOS**: `xcodebuild archive` (scheme ClaudeRelayApp) →
  `xcodebuild -exportArchive` with `build/ExportOptions.plist`
  (destination=upload → goes straight to App Store Connect).
- **macOS**: same flow with scheme ClaudeRelayMac.
- **Android**: `./gradlew :app:assembleRelease`, copy to
  `/tmp/CodeRelay-<versionName>.apk`,
  `gh release create android-v<versionName> <apk> --prerelease` with title
  `Android client test build — <versionName> (<one-line summary>)` and notes
  following the m20/m21 format (What's new, server-compat warning if protocol
  changed, Install section).
- **Server**: push to main, `brew upgrade clauderelay && brew services restart
  clauderelay` (never run the server binary directly or pkill).

## 4. VERIFY — mandatory

- **iOS/macOS**: grep `UPLOAD SUCCEEDED` in
  `$TMPDIR/<AppName>_*.xcdistributionlogs/ContentDelivery.log` (newest dir).
  Also confirm the archive's `CFBundleVersion` matches the bump.
- **Android**: download the APK **back from the release URL** with
  `gh release download`, then `aapt2 dump badging` must show the new
  `versionCode`/`versionName`. Byte size alone is NOT proof.
- **Server**: `swift run Codex-relay status` (or `Codex-relay status`) must
  report the new version; `curl -s http://127.0.0.1:9100/health` must be ok;
  `/opt/homebrew/bin/Codex-relay-server` symlink must point at the new Cellar
  path.

## 5. Report

One table: platform | version/build | verified-by (log line / badging output /
status output) | link (release URL, App Store Connect). List anything skipped
and why.
