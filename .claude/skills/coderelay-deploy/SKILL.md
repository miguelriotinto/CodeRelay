---
name: coderelay-deploy
description: Build, publish, and VERIFY CodeRelay artifacts — iOS/macOS to TestFlight, Android APK to GitHub Releases, server to Homebrew. Args: ios | android | mac | server | all (default all)
disable-model-invocation: true
---

# Ship CodeRelay

Every shipped build is made by GitHub Actions. This skill **starts runs and
verifies them**; it never builds anything that ships. Never run
`xcodebuild archive`/`-exportArchive`, `brew install --build-from-source` or
`gradlew assembleRelease` from here, and never fall back to them when a run
fails: stop, report the failing job and its log, and point at
`docs/RELEASING.md` (the break-glass section is run by hand only).

Execute in order. Never skip VERIFY — "published" is proven from the run and
the release, not assumed. If a step fails, stop and report; do not continue to
the next platform.

Target platforms come from the arguments (`ios`, `android`, `mac`, `server`,
or `all`). Default: `all`, but first check which platforms changed since their
last release tag and confirm the skip list with the user.

| Ships | Workflow | Started by |
|---|---|---|
| iOS app → TestFlight | `apple-release.yml` | `gh workflow run … -f platform=ios` |
| macOS app → TestFlight | `apple-release.yml` | `… -f platform=macos` (`both` for the two) |
| Android APK, Linux client, Linux server (tarballs + Arch packages), macOS server bottle, tap | `release.yml` | pushing a `vX.Y.Z` tag |

## 1. Preflight

1. `git status` clean, on `main`, and `git fetch && git status -sb` shows
   `main` level with `origin/main` (runs build what is on GitHub, not local
   commits).
2. Diff each platform's paths against its last release to decide what needs
   shipping: `ios-build-*` / `mac-build-*` tags for the apps
   (`CodeRelayApp/`, `CodeRelayMac/`, `Sources/CodeRelayClient`,
   `Sources/CodeRelayKit`, `project.yml`); the last `v*` tag for
   server/Android/Linux (`Sources/`, `Formula/`, `CodeRelayAndroid/`,
   `CodeRelayLinux/`).
3. Apple: nothing to bump — the workflow numbers the build from App Store
   Connect. A marketing-version change (`MARKETING_VERSION` in `project.yml`)
   is a normal PR, merged first.
4. Tag release: the version-bump PR is merged first — the version constant in
   `Sources/CodeRelayKit/CodeRelayKit.swift`, and for Android `versionCode` /
   `versionName` (`0.3-mNN` milestone scheme, plus the "M-NN version." comment)
   in `CodeRelayAndroid/app/build.gradle.kts`. Do not edit `Formula/` by hand:
   the release writes its url, sha256 and bottle.
5. The Apple gate refuses a commit with no green `CI` run covering it; if
   `main`'s CI is still running, wait for it (`gh run list --workflow ci.yml
   --branch main --limit 3`).

## 2. Apple apps (ios / mac)

```bash
gh workflow run apple-release.yml -f platform=<ios|macos|both>
sleep 5; RUN=$(gh run list --workflow apple-release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN" --exit-status
```

VERIFY (all must hold):
- The run ends `success` (`gh run view "$RUN" --json conclusion`).
- Each platform's build job log contains `UPLOAD SUCCEEDED`:
  `gh run view "$RUN" --log | grep -E "UPLOAD SUCCEEDED|archive CFBundleVersion"`.
- The tag exists: `git ls-remote --tags origin 'ios-build-*' 'mac-build-*' | tail`
  shows `ios-build-<N>` / `mac-build-<N>` at the dispatched commit, where
  `<N>` is the build number in the run summary.
- "What to Test" is a separate job that waits for Apple's processing (up to
  ~1 h). Report its state; its failure does not un-ship the build. A build
  not yet visible in TestFlight is not a failure.

## 3. Tag release (android / server, and Linux)

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
sleep 5; RUN=$(gh run list --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN" --exit-status
```

VERIFY:
- The run ends `success`, including the `bottle`, `homebrew` and
  `arch-packages` jobs.
- `gh release view vX.Y.Z --json assets --jq '.assets[].name'` lists
  `coderelay-vX.Y.Z-linux-x86_64.tar.gz`, `claude-relay-vX.Y.Z-linux-x86_64.tar.gz`,
  `coderelay-vX.Y.Z-android.apk`, `checksums.txt`,
  `coderelay-X.Y.Z.<tag>.bottle.tar.gz` (single dash before the version),
  `coderelay-bin-X.Y.Z-1-x86_64.pkg.tar.zst` and
  `coderelay-server-bin-X.Y.Z-1-x86_64.pkg.tar.zst` (no `v`), and
  `checksums.txt` has a line for each `.pkg.tar.zst`.
- `gh release view vX.Y.Z` prints the per-platform sections.
- Android: `gh release download vX.Y.Z -p '*.apk' -D /tmp/cr-apk` and
  `aapt2 dump badging` shows the expected `versionCode`/`versionName`; byte
  size is not proof. The run log's `apksigner verify --print-certs` must not
  show `CN=Android Debug`.
- The tap carries the bottle:
  `gh api repos/miguelriotinto/homebrew-coderelay/contents/Formula/coderelay.rb --jq .content | base64 -d | grep -A3 'bottle do'`
  shows `root_url …/releases/download/vX.Y.Z`; after `git pull`,
  `Formula/coderelay.rb` on `main` carries the same `url`, `sha256` and
  `bottle do` block (the rest can differ only if `Formula/` changed after the tag).

## 4. Mac server (after a tag release)

```bash
Scripts/mac-server-upgrade.sh    # starts a one-shot launchd job; log: ~/.claude-relay/upgrade/upgrade.log
```

**Never run `brew upgrade coderelay` / `brew services restart coderelay`
inline.** The upgrade stops the relay, and the relay kills every process in
its PTY sessions — so from a relay-hosted shell (`$CLAUDE_RELAY_SESSION_ID`
set) brew is killed after pouring the bottle and before linking and
restarting, leaving the server down with dangling `bin/` links (v0.3.42). The
script runs the upgrade from launchd, outside any PTY session, and always
relinks and restarts. If this session is relay-hosted it ends when the relay
restarts: tell the user first, and verify from the next session. Never run the
server binary directly or `pkill` it.

VERIFY:
- The log's last line is `end: OK`, and `brew upgrade` poured the bottle (no
  `swift build` in the log).
- `claude-relay status` reports the new version; `claude-relay health` is OK.
- `ls -l /opt/homebrew/bin/claude-relay-server` points at
  `Cellar/coderelay/X.Y.Z/…` — a `HEAD-<sha>` path means the Mac is still on
  a HEAD install (see `docs/RELEASING.md`, one-time cut-over).
- Full Disk Access may need re-granting after the upgrade (ad-hoc signed).

On a Linux host: `sudo pacman -U <release URL of coderelay-server-bin-X.Y.Z-1-x86_64.pkg.tar.zst>` once the `arch-packages` job has uploaded it.

## 5. Report

One table: platform | version/build | verified-by (run URL + log line / badging
output / status output) | link (release URL, App Store Connect). List anything
skipped and why.
