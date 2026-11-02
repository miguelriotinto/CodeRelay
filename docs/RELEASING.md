# Releasing CodeRelay

Every shipped artifact is built by GitHub Actions. The dev Mac starts runs and
verifies them (`/coderelay-deploy`); it does not build what ships. Design:
`docs/superpowers/specs/2026-11-01-remote-release-pipeline-design.md`.

## What ships from where

| Deliverable | Built by | Trigger | Lands in |
|---|---|---|---|
| iOS app | `apple-release.yml` (runner `xcode-27`) | `gh workflow run apple-release.yml -f platform=ios` | TestFlight; tag `ios-build-<N>` |
| macOS app | `apple-release.yml` | `-f platform=macos` (or `both`) | TestFlight; tag `mac-build-<N>` |
| macOS server + CLI | `release.yml` job `bottle` (arm64, `xcode-27`) | `vX.Y.Z` tag | Homebrew bottle on the release; tap `miguelriotinto/homebrew-coderelay` + `Formula/` on `main` |
| Linux server + CLI | `release.yml` | `vX.Y.Z` tag | GitHub Release; AUR `coderelay-server-bin` |
| Linux client | `release.yml` | `vX.Y.Z` tag | GitHub Release; AUR `coderelay-bin` |
| Android client | `release.yml` | `vX.Y.Z` tag | GitHub Release (APK, project-key signed) |

Install the Mac server with `brew install miguelriotinto/coderelay/clauderelay`.

### Apple runs

- **Gate.** The dispatched commit must be on `main` and covered by a green
  `CI` run: the nearest first-parent ancestor with one, with only
  `CodeRelayAndroid/` or `Formula/` changed since (`Scripts/ci/ci_gate.py`).
- **Build number** = App Store Connect's highest for the app + 1
  (`Scripts/ci/asc.py next-build`); `CURRENT_PROJECT_VERSION` in
  `project.yml` is only a floor for local debug builds. Nothing is committed.
  The marketing version is `MARKETING_VERSION` in `project.yml`, changed by PR.
- **Dry run:** `-f dry_run=true` archives and checks the build number, then
  stops before upload, tag and What to Test.
- **Upload.** The archive is exported locally (`destination: export`) and the
  `.ipa`/`.pkg` uploaded with `xcrun altool --upload-app`. Not
  `destination: upload`: that asks for store configuration through an Xcode
  *account*, and with only an API key fails `Cannot verify client's JWT
  headers` / `App Store Connect access for "T9WF95GC9T" is required`, whatever
  the key. Proof of upload is `UPLOAD SUCCEEDED` in the run log.
- **Xcode** is the newest *release* Xcode 27 on the runner (RC and beta builds
  are skipped, symlinks resolved), currently 27.1.
- **What to Test** is set from the commit subjects since the previous
  `*-build-*` tag by a follow-up job that waits up to 90 min for Apple's
  processing. Its failure never fails or retracts the upload.

### Tag releases

The `release` job publishes the Linux tarballs and APK without waiting for
the bottle. `bottle` then uploads `clauderelay-X.Y.Z.<tag>.bottle.tar.gz`, and
only after that does `homebrew` write url, sha256 and the `bottle do` block
into the tap and into `main`'s `Formula/clauderelay.rb`
(`Scripts/ci/formula.py`). A bottle failure leaves the release intact and the
tap untouched: re-run the `bottle` job, then `homebrew`.

The server binary is ad-hoc signed (no Developer ID); Full Disk Access may
need re-granting after an upgrade.

## Secrets

Eight repository secrets (`gh secret list`). Rotate one with
`gh secret set <NAME>` (paste the value, or `< file`).

| Secret | What | Rotate |
|---|---|---|
| `ASC_API_KEY_P8` | Contents of the App Store Connect API key "GitHub Actions" (`.p8`) | Users and Access → Integrations → revoke + generate a new key; update all three ASC secrets |
| `ASC_API_KEY_ID` | That key's ID | with the key |
| `ASC_API_ISSUER_ID` | The team's issuer ID | only if the team changes |
| `HOMEBREW_TAP_TOKEN` | Fine-grained PAT: repo `miguelriotinto/homebrew-coderelay`, Contents read/write, with an expiry | before it expires — the `homebrew` job fails loudly without it |
| `ANDROID_KEYSTORE_B64` | `base64` of the release keystore (`CodeRelayAndroid/RELEASE.md` §1) | **never** — a new key means every phone must uninstall first |
| `ANDROID_KEYSTORE_PASSWORD` | Store password | with the keystore |
| `ANDROID_KEY_ALIAS` | Key alias | with the keystore |
| `ANDROID_KEY_PASSWORD` | Key password | with the keystore |

The keystore and its passwords live in the password manager. `AUR_SSH_KEY` is
the private half of `~/.ssh/aur` (`coderelay-aur`); its public half must be on
the AUR account's *SSH Public Key* field, which owns both `coderelay-bin` and
`coderelay-server-bin`. Check it with
`ssh -i ~/.ssh/aur -o IdentitiesOnly=yes aur@aur.archlinux.org help`.
`AUR_USERNAME` is only the commit author. Without `AUR_SSH_KEY` the `aur` legs
skip and pass — that is why nothing reached the AUR through v0.3.39 —
so a green `aur` job is not proof; `https://aur.archlinux.org/packages/<name>` is.

The App Store Connect key "GitHub Actions" is a **Team Key** with **Admin**
access (first CI uploads: iOS 202 and macOS 116, 2026-11-01). Automatic
signing on a fresh runner creates its certificates and profiles through it.

## One-time cut-over (Mac server)

Leaving the HEAD install, after the first bottled release:

```bash
brew uninstall clauderelay && brew install miguelriotinto/coderelay/clauderelay
ls -l /opt/homebrew/bin/claude-relay-server   # → Cellar/clauderelay/X.Y.Z, not HEAD-<sha>
```

Then re-grant Full Disk Access. From then on the Mac server updates only on
`vX.Y.Z` tags. On the phone, uninstall the Android app once before installing
the first APK signed with the release key (saved servers and tokens are lost;
re-pair).

## Break glass — manual TestFlight upload

**By hand only, when GitHub Actions or the `xcode-27` runner is down. Never
from `/coderelay-deploy`.** A manual build bypasses the CI gate, so build only
a commit that already has a green `CI` run, with Xcode 27.1 or later (the
iPhone Duo layout is gated on the iOS 27.1 SDK), and pick the build number
yourself: App Store Connect's highest + 1
(`python3 Scripts/ci/asc.py next-build --bundle-id com.claude.relay --floor 1`
with the env below, PyJWT installed).

```bash
KEY=(-authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_H8WJXYB4M3.p8
     -authenticationKeyID H8WJXYB4M3
     -authenticationKeyIssuerID 69a6de76-f499-47e3-e053-5b8c7c11a4d1)
N=<build number>
xcodegen
xcodebuild archive -project CodeRelay.xcodeproj -scheme CodeRelayApp \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/CodeRelayApp.xcarchive \
  -skipMacroValidation -allowProvisioningUpdates "${KEY[@]}" \
  CURRENT_PROJECT_VERSION=$N
xcodebuild -exportArchive -archivePath build/CodeRelayApp.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates "${KEY[@]}"
grep "UPLOAD SUCCEEDED" "$(ls -dt "$TMPDIR"/CodeRelayApp_*.xcdistributionlogs | head -1)/ContentDelivery.log"
git tag ios-build-$N && git push origin ios-build-$N
```

macOS: scheme `CodeRelayMac`, destination `generic/platform=macOS`, logs
`$TMPDIR/CodeRelayMac_*.xcdistributionlogs`, tag `mac-build-$N`.

Why the two flags: `-skipMacroValidation` on the archive, or it fails with
`Macro "LLMMacrosImplementation" from package "LLM" … must be enabled` (a
macro approval only Xcode.app's trust store has); API-key auth on the export,
or it fails `Failed to Use Accounts` (the Xcode account session isn't usable
headlessly). `build/ExportOptions.plist` (gitignored) is `method`
`app-store-connect`, `destination` `upload`, `signingStyle` `automatic`,
`teamID` `T9WF95GC9T`.
