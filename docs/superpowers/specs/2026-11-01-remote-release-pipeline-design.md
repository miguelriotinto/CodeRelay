# Remote release pipeline — every shipped build on GitHub Actions

Approved in conversation on 2026-11-01. Decisions are numbered as they were
made; **[call]** marks a choice the assistant made that the user did not
explicitly decide (they reviewed the summary and did not object).

## Intent

Nothing that ships is built on the dev Mac any more. Today three deliverables
are: the iOS and macOS apps (archived and uploaded to TestFlight from the dev
Mac by `/coderelay-deploy`) and the macOS server (compiled from source by
`brew` from HEAD on the Mac). Android, the Linux client and the Linux server
are already built by `.github/workflows/release.yml` on a `vX.Y.Z` tag. After
this work, every shipped artifact comes out of GitHub Actions, and the local
role shrinks to starting runs and verifying them.

Why: builds made on one machine depend on that machine's toolchain and state
(this session alone hit a CoreSimulator/Xcode mismatch, a missing `xcodegen`,
and a CI/local Xcode split that let a type-checker timeout through), and
"published" should be provable from a CI run, not from a local log.

## Goals

- iOS and macOS TestFlight uploads run on GitHub Actions.
- The macOS server reaches the Mac as a CI-built Homebrew bottle.
- Every release artifact is reproducibly signed with keys held as repo
  secrets (Android included — today every CI APK has a different signer).
- `/coderelay-deploy` starts runs and verifies them; it never builds.

## Non-goals

- Running `CodeRelayAppTests` in CI (decision 4: app tests stay manual).
- Developer ID signing / notarization of the server binary (decision 8).
- An Intel or pre-27 macOS bottle (decision 7).
- Google Play publishing. The new Android key is Play-eligible, but nothing
  uploads to Play.
- Changing how server / Android versions are bumped (still a PR editing
  `Sources/CodeRelayKit/CodeRelayKit.swift`, `Formula/`, `app/build.gradle.kts`
  before tagging).

## Anti-goals (a failure even if it technically works)

- A CI failure that silently falls back to a local build (decision 12).
- An Apple build made with the iOS 26 SDK: the iPhone Duo layout is gated on
  linking the iOS 27.1 SDK (CLAUDE.md "Ship iOS with Xcode 27.1 or later").
- Two runs uploading the same build number.
- Secrets or the `.p8` written to logs or artifacts.

## Part A — Apple apps: new workflow

1. **Trigger (decision 1).** `workflow_dispatch` only, with one choice input
   `platform: ios | macos | both`. `v*` tags do not trigger it, and it does
   not run on push.
2. **Gate (decisions 4, 13).** Before archiving, the run refuses unless the
   dispatched commit is reachable from `origin/main` **and** it is covered by
   a green `CI` run: walk back from the dispatched SHA to the nearest ancestor
   with a completed, successful `ci.yml` run; accept only if every commit
   after that ancestor touches nothing but paths `ci.yml` ignores or does not
   build — `CodeRelayAndroid/**` and `Formula/**`. Otherwise fail, naming the
   commit and the path that broke coverage. Exact-SHA was rejected because
   many `main` commits never get a CI run: `ci.yml` skips Android-only pushes
   (`paths-ignore`), cancels superseded runs on `main`
   (`cancel-in-progress`), and the release workflow's own `Formula/` commit
   (pushed with `GITHUB_TOKEN`) triggers no workflow. `ci.yml` itself is not
   changed by this project.
3. **Build number (decision 2).** Per platform, query App Store Connect (API
   key auth) for the highest build number uploaded for that app
   (`com.claude.relay` / `com.claude.relay.mac`) and use highest + 1, passed as
   `CURRENT_PROJECT_VERSION=<n>` to `xcodebuild archive`. Nothing is committed.
   `project.yml`'s value is a floor for local debug builds only; if it is ever
   higher than App Store Connect's highest, use it instead. After a verified
   upload, push a lightweight tag `ios-build-<n>` / `mac-build-<n>` on the
   built commit.
4. **Marketing version (decision 3).** Read from `project.yml`
   (`MARKETING_VERSION`), changed by PR only. No workflow input overrides it.
5. **Toolchain.** Runner label `xcode-27`; select the newest
   `/Applications/Xcode_27.*.app`, fail if none (same step as `ci.yml`).
   `xcodebuild -downloadComponent MetalToolchain` (SwiftTerm's shader).
   `brew install xcodegen && xcodegen`, as `ci.yml` does. **[call]** If the
   `xcode-27` runner is unavailable the run fails; it never falls back to
   `macos-26`.
6. **Signing (decision 11).** Automatic signing (team `T9WF95GC9T`, as
   `project.yml` already sets) with `-allowProvisioningUpdates` and a new,
   CI-only App Store Connect API key named "GitHub Actions", narrowest role
   that can cloud-sign (expected Admin, or App Manager with certificate
   access — confirm on the first run and record the answer in the
   break-glass doc). The `.p8` is written to a temp file with mode 600 and
   deleted in an `always()` step. Archive with `-skipMacroValidation`; export
   with `build/ExportOptions.plist`'s content (`method: app-store-connect`,
   `destination: upload`, `signingStyle: automatic`) — that file is
   gitignored under `build/`, so the workflow writes it inline.
7. **Verify (decision 5).** Fail unless the newest
   `$TMPDIR/<scheme>_*.xcdistributionlogs/ContentDelivery.log` contains
   `UPLOAD SUCCEEDED`, and the archive's `CFBundleVersion` equals `<n>`.
8. **Run summary (decision 5).** `$GITHUB_STEP_SUMMARY`: platform, marketing
   version, build number, commit SHA, and the commit subjects since the
   previous `ios-build-*` / `mac-build-*` tag (all of history if none).
9. **"What to Test" (decision 5).** A separate `ubuntu-latest` job, after the
   upload job, polls App Store Connect until the build's processing state is
   valid, then sets its beta-build localization "What to Test" to the commit
   list from step 8 (truncated to App Store Connect's length limit).
   **[call]** `timeout-minutes: 90`; this job failing does not fail or retract
   the upload, and is reported in the summary.
10. **Concurrency [call].** `concurrency: apple-release-<platform>` with
    `cancel-in-progress: false`, so runs for the same platform queue and two
    runs can never read the same "highest build".
11. With `platform: both`, iOS and macOS are separate jobs (each its own
    build number, tag, and What-to-Test job); one failing does not stop the
    other.

## Part B — `release.yml` (tag `vX.Y.Z`)

1. **Homebrew bottle (decisions 6, 7).** Replace the best-effort `build`
   matrix (`macos-14` arm64 / `macos-15` x86_64, `continue-on-error`) with one
   job on `xcode-27` that builds an arm64 bottle of `Formula/clauderelay.rb`
   for the tag (the standard `brew install --build-bottle` + `brew bottle
   --json` flow) and uploads the bottle tarball to the GitHub release.
   **(decision 14)** The `release` job does not wait for it: the GitHub
   Release, APK and Linux tarballs publish as today. The bottle job runs
   after `release` and uploads to that existing release; only the `homebrew`
   tap job depends on the bottle job, so the tap is never bumped without a
   bottle. A bottle failure ends the run red with the release otherwise
   intact, and is recovered by re-running the bottle job (and then the tap
   job) alone. The bottle job is not `continue-on-error`.
2. **Tap update (decision 10).** The existing `homebrew` job, using a new
   fine-grained `HOMEBREW_TAP_TOKEN` (repo `miguelriotinto/homebrew-coderelay`,
   Contents read/write, with an expiry), writes `url`, `sha256` **and** the
   `bottle do` block (`root_url` pointing at the release download, arm64
   sha256) into the tap formula, and opens a commit to this repo's
   `Formula/clauderelay.rb` with the same content so the copies cannot drift.
   **(decision 15, 2026-11-01)** The tap copy is rendered from the *tagged*
   `Formula/clauderelay.rb` and `main`'s from `main`'s: `url`, `sha256` and the
   bottle block are always identical; the rest differs only when `Formula/`
   changed after the tag, so such a change is never reverted.
   The existing `sed` that assumes "no bottle block, so only one sha256" must
   be replaced — it would clobber the bottle checksum.
3. **Signing stays ad hoc (decision 8).** No Developer ID, no notarization.
   Full Disk Access may need re-granting after an upgrade, as today.
4. **[call]** The bare macOS server tarballs (`claude-relay-vX.Y.Z-macos-*`)
   are no longer produced; the release body's macOS row points at Homebrew
   only.
5. **Android signing (decision 9).** The four `ANDROID_KEYSTORE_*` secrets
   are set from a newly generated release keystore (RELEASE.md §1 procedure),
   stored in the user's password manager. The existing job already writes
   `keystore.properties` from them and asserts not-debug-signed; no workflow
   change beyond confirming that assertion runs.
6. Linux client, Linux server, AUR jobs: unchanged.

## Part C — local tooling and docs (decision 12)

- `/coderelay-deploy` (`.claude/skills/coderelay-deploy/SKILL.md`) is
  rewritten to: dispatch the Apple workflow (`gh workflow run … -f
  platform=…`) and watch it; or push the `vX.Y.Z` tag and watch
  `release.yml`; then verify from the run and the release (run conclusion,
  `UPLOAD SUCCEEDED` in the job log, the `*-build-N` tag; release assets incl.
  the bottle and APK, `aapt2 dump badging` on the downloaded APK). For the
  server it then runs `brew upgrade clauderelay && brew services restart
  clauderelay` and the existing status / `/health` / symlink checks. No
  `xcodebuild archive` anywhere in the skill, and no fallback to one.
- A **break-glass** section (new `docs/RELEASING.md` or similar) keeps the
  manual archive/export commands (with `-skipMacroValidation` and API-key
  flags) for when GitHub or the CI path is down — run by hand, never by the
  skill.
- CLAUDE.md "Release Process" and the TestFlight note updated to match;
  `/coderelay-health` checked for any assumption of local builds.

## One-time setup (user, before first run)

1. Generate the Android release keystore; set `ANDROID_KEYSTORE_B64`,
   `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
2. Create the App Store Connect API key "GitHub Actions"; set its `.p8`
   contents, key ID and issuer ID as three secrets (names left to the
   builder).
3. Create the fine-grained `HOMEBREW_TAP_TOKEN`.
4. After the first bottled release: `brew uninstall clauderelay && brew
   install miguelriotinto/coderelay/clauderelay` (leaves HEAD; from then on
   the Mac server updates only on tags), then re-grant Full Disk Access.
5. Uninstall the Android app once before installing the first APK signed
   with the new key (saved servers and tokens are lost; re-pair).

## Left to the builder

- Workflow file name(s) and job names; secret names for the App Store
  Connect key.
- How App Store Connect is queried (the REST API with a JWT from the `.p8`,
  or a tool such as the `asc` CLI if it is available on the runner).
- Whether the bottle job builds via `brew test-bot` or plain
  `brew install --build-bottle`/`brew bottle`.
- How the in-repo `Formula/` copy is updated (direct push to `main` from the
  release run, or a PR), provided it ends identical to the tap.
- Order of rollout and how to dry-run (e.g. a `workflow_dispatch` dry-run
  input that stops before upload / before pushing the tap).
