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
3. Version coherence: status version vs `Formula/coderelay.rb` vs the version
   constant in `Sources/` vs the latest `v*` release. The Homebrew Cellar
   symlink (`ls -l /opt/homebrew/bin/claude-relay-server`) should point at
   `Cellar/coderelay/<version>` (the CI-built bottle); a `HEAD-<sha>` path
   means "still on a HEAD install" — flag it (cut-over in `docs/RELEASING.md`).
4. The release has its bottle: `gh release view <latest v*> --json assets`
   lists `coderelay-*.bottle.tar.gz`, and its `release.yml` run's `bottle`
   and `homebrew` jobs succeeded.

### Android
1. Latest `android-v*` tag: `gh release list --limit 10`.
2. Its APK asset exists and `versionName` in the tag matches
   `versionName` in `CodeRelayAndroid/app/build.gradle.kts`. If gradle is
   ahead of the tag → flag "unreleased Android changes".

### iOS / macOS
Builds are made by `apple-release.yml` on GitHub Actions, never locally, so
local archives and `$TMPDIR` logs are not evidence.
1. Latest build tags: `git ls-remote --tags origin 'ios-build-*' 'mac-build-*'`
   → highest `ios-build-<N>` / `mac-build-<N>` and the commit each points at.
2. Last run verdicts: `gh run list --workflow apple-release.yml --limit 5
   --json conclusion,headSha,createdAt,url` → the newest run per platform
   succeeded, and its log has `UPLOAD SUCCEEDED`. A failed "What to Test" job
   is ⚠️, not a failed upload.
3. Processing state: if the `asc` CLI is available, check the TestFlight
   state of build `<N>`; otherwise note "processing state unknown — check App
   Store Connect".

### Working tree
`git status --porcelain` + commits since the last release tags → flag
"unshipped commits touching <platform> paths".

## Output

| Platform | Deployed/Published | Source of truth | Status |
|---|---|---|---|
| Server | vX.Y.Z (PID …) | Formula vX.Y.Z, code vX.Y.Z | ✅/⚠️ |
| Android | android-vX (APK vc NN) | gradle vc NN | ✅/⚠️ |
| iOS | ios-build-NNN, run ✓ | commits since tag | ✅/⚠️ |
| macOS | mac-build-NNN, run ✓ | commits since tag | ✅/⚠️ |

Follow with one line per ⚠️ explaining what's stale and the exact command or
skill (`/coderelay-deploy <platform>`) that would fix it.
