# CodeRelay rename, single product version, and documentation overhaul

**Date:** 2026-09-12
**Status:** Approved in conversation; awaiting spec review
**Scope:** Three sequenced pull requests, then one release tag `v1.5.0`

## 1. Problem

The project is called CodeRelay on GitHub, in the app display name
(`Code[Relay]`), in the URL scheme (`coderelay://`), in the AUR packages and in
the Linux client, but almost everything else still says ClaudeRelay or
`claude-relay`: the Swift modules, the Xcode project, the Gradle roots, the CLI
binary, the config directory, the launchd label, the systemd unit, the Homebrew
formula, the hook script, the environment variables and the README.

Versions are worse. Seven artifacts carry four unrelated numbers:

| Artifact | Version today | Where it lives |
|---|---|---|
| Server + CLI (macOS, Linux) | 0.3.24 | `Sources/ClaudeRelayKit/ClaudeRelayKit.swift`, formula, PKGBUILD |
| iOS app | 1.4.1 (build 183) | `project.yml` |
| macOS app | 1.1.1 (build 104) | `project.yml` |
| Android app | 0.3-m50 (versionCode 49) | `app/build.gradle.kts` |
| Linux client | the git tag | passed in by `release.yml` |

A user cannot tell whether "iOS 1.4.1" and "server 0.3.24" belong together.
The README still describes a single macOS server and does not mention the
Linux server or the Linux and Android clients.

## 2. Decisions already taken

These were decided with the user and are not reopened here.

1. **One product version everywhere.** The next release is `1.5.0` (the
   smallest version that is greater than every current one). One tag
   `vX.Y.Z` releases all seven artifacts. Store build counters (iOS and macOS
   build numbers, Android `versionCode`) keep counting and are shown in
   parentheses after the version. The Android `0.3-mNN` scheme and the
   `android-v0.3-mNN` pre-release tags are retired.
2. **Rename to CodeRelay everywhere**, including the CLI binary and the
   Homebrew formula.
3. **Hard rename, no compatibility shims.** No symlinks, no config-dir
   migration, no old formula kept as an alias.
4. **Rename scope is everything, including source layout**: Swift targets,
   directories, Xcode project and schemes, Gradle root projects.
5. **Two exceptions**, both approved:
   - Store identities stay: iOS `com.claude.relay`, macOS `com.claude.relay.mac`,
     Android `applicationId com.singular.coderelay`. Changing them would make
     TestFlight and Play treat the apps as new products.
   - On-device persistence keys stay: every `com.clauderelay.*` UserDefaults
     and Keychain key on iOS and macOS, and Android `TokenStore.BEDROCK_KEY`
     (`com.clauderelay.bedrock.bearerToken`). They are invisible to users and
     renaming them would erase saved servers, tokens and settings on every
     device. The same applies to the macOS speech-model directory
     `~/Library/Application Support/ClaudeRelay/Models/` (`SpeechModelStore`):
     renaming it would force every Mac to re-download gigabytes of models.
     Logger subsystems and `Notification.Name`s are renamed because nothing
     persists under them.
6. **Order of work**: layout rename first, then user-facing rename plus
   versioning, then docs. Rationale: the docs are written once against the
   final tree, and the layout PR is pure mechanics that is verified by "every
   artifact still builds and tests pass, nothing user-visible changed".

## 3. Naming table

The authoritative mapping. Every occurrence of a left-hand name is replaced by
the right-hand name unless it is listed in section 2.5.

### 3.1 Product and code

| Today | New |
|---|---|
| `ClaudeRelay` (product, prose) | `CodeRelay` |
| `ClaudeRelay.xcodeproj`, `project.yml name:` | `CodeRelay.xcodeproj`, `name: CodeRelay` |
| Xcode targets and schemes `ClaudeRelayApp`, `ClaudeRelayMac`, `ClaudeRelayAppTests`, `ClaudeRelayMacTests` | `CodeRelayApp`, `CodeRelayMac`, `CodeRelayAppTests`, `CodeRelayMacTests` |
| Directories `ClaudeRelayApp/`, `ClaudeRelayMac/`, `ClaudeRelayAndroid/`, `ClaudeRelayLinux/` | `CodeRelayApp/`, `CodeRelayMac/`, `CodeRelayAndroid/`, `CodeRelayLinux/` |
| SPM targets and products `ClaudeRelayKit`, `ClaudeRelayServer`, `ClaudeRelayCLI`, `ClaudeRelayClient`, `ClaudeRelaySpeech` | `CodeRelayKit`, `CodeRelayServer`, `CodeRelayCLI`, `CodeRelayClient`, `CodeRelaySpeech` |
| `Sources/ClaudeRelay*/`, `Tests/ClaudeRelay*Tests/` | `Sources/CodeRelay*/`, `Tests/CodeRelay*Tests/` |
| SPM resource bundle `ClaudeRelay_ClaudeRelayServer.bundle` / `.resources` | `CodeRelay_CodeRelayServer.bundle` / `.resources` (derived by SPM from the package and target names; the formula, PKGBUILD and `release.yml` must follow) |
| `CPTYShim` | unchanged (never carried the name) |
| Gradle `rootProject.name` `ClaudeRelayAndroid`, `ClaudeRelayLinux` | `CodeRelayAndroid`, `CodeRelayLinux` |
| Kotlin package root `relay.*` | unchanged (already neutral) |
| Android theme `Theme.ClaudeRelayM1` | `Theme.CodeRelayM1` |
| Linux `WM_CLASS = "relay-app-CodeRelay"` | unchanged |
| Logger subsystems `com.claude.relay.client`, `com.claude.relay.speech` | `com.coderelay.client`, `com.coderelay.speech` |
| `Notification.Name("com.clauderelay.*")` | `com.coderelay.*` |
| Type and symbol names containing `ClaudeRelay` (e.g. `ClaudeRelayApp` struct, `ClaudeRelayKit.version`) | `CodeRelay*` |
| Swift `Package.swift` package name `ClaudeRelay` | `CodeRelay` |

### 3.2 Server, CLI and host installation

| Today | New |
|---|---|
| CLI binary `claude-relay` | `coderelay` |
| Server binary `claude-relay-server` | `coderelay-server` |
| Config dir `~/.claude-relay/` (config.json, tokens.json, agents/, hooks/, bin/, push registrations) | `~/.coderelay/` |
| Hook script `claude-relay-state-hook.sh`, installed to `~/.claude-relay/hooks/` | `coderelay-state-hook.sh`, installed to `~/.coderelay/hooks/` |
| Hook search dirs `share/clauderelay/` (`/opt/homebrew`, `/usr/local`, `/usr`) | `share/coderelay/` |
| Env vars `CLAUDE_RELAY_ADMIN_PORT`, `CLAUDE_RELAY_SESSION_ID` | `CODERELAY_ADMIN_PORT`, `CODERELAY_SESSION_ID` |
| launchd label `com.claude.relay`, plist `~/Library/LaunchAgents/com.claude.relay.plist` | `com.coderelay.server`, `com.coderelay.server.plist` |
| Homebrew services label `homebrew.mxcl.clauderelay` | `homebrew.mxcl.coderelay` (follows the formula name automatically) |
| systemd unit `claude-relay.service` (file `packaging/claude-relay.service`) | `coderelay.service` |
| Homebrew log dir `/opt/homebrew/var/log/claude-relay/` | `/opt/homebrew/var/log/coderelay/` (set in the formula's `service` block) |
| launchd `StandardOutPath`/`StandardErrorPath` under `~/.claude-relay/` | follow the config dir rename |
| Homebrew formula `Formula/clauderelay.rb`, class `Clauderelay`, tap path `miguelriotinto/clauderelay/clauderelay` | `Formula/coderelay.rb`, class `Coderelay`, `brew install miguelriotinto/coderelay/coderelay`. The old formula file is **deleted** from the tap (no alias). |
| AUR `coderelay-server-bin`: `provides=('coderelay-server' 'claude-relay')`, `conflicts=('coderelay-server' 'clauderelay')` | `provides=('coderelay-server' 'coderelay')`, `conflicts=('coderelay-server' 'coderelay')` |
| pacman scriptlet `packaging/coderelay-server.install` text | updated commands and paths |
| Release tarballs `claude-relay-vX.Y.Z-macos-<arch>.tar.gz`, `claude-relay-vX.Y.Z-linux-x86_64.tar.gz` | `coderelay-server-vX.Y.Z-macos-<arch>.tar.gz`, `coderelay-server-vX.Y.Z-linux-x86_64.tar.gz` |
| Android APK `coderelay-vX.Y.Z-android.apk` | unchanged |

### 3.3 Linux desktop client — the one collision

`ClaudeRelayLinux/packaging/PKGBUILD` (`coderelay-bin`) installs the desktop
app launcher as `/usr/bin/coderelay` and declares `provides=(coderelay)`. That
is exactly the name the CLI takes in 3.2. A Linux machine running both the
server and the desktop client is a normal setup, so the two cannot share a
path.

**Decision:** the typed command wins. The CLI is `coderelay`. The Linux desktop
client's launcher becomes `coderelay-app`:

| Today | New |
|---|---|
| `/usr/bin/coderelay` → `/usr/lib/coderelay/bin/coderelay` | `/usr/bin/coderelay-app` → `/usr/lib/coderelay-app/bin/coderelay-app` |
| jpackage `packageName = "coderelay"` in `app/build.gradle.kts` | `coderelay-app` |
| `coderelay.desktop` `Exec=coderelay %u` / `Exec=coderelay --new-session` | `Exec=coderelay-app %u` / `Exec=coderelay-app --new-session`; the desktop file and icons keep the `coderelay` basename (they are the product, not the binary) |
| AUR `coderelay-bin` `provides=("$_pkgname")`, `conflicts=("$_pkgname")` | `provides=('coderelay-app')`, `conflicts=('coderelay-app')` |
| Client tarball `coderelay-vX.Y.Z-linux-x86_64.tar.gz` | `coderelay-app-vX.Y.Z-linux-x86_64.tar.gz` |

The AUR package name `coderelay-bin` and the pkgname `coderelay-server-bin`
are unchanged: they are already correct and renaming an AUR package means
deleting and re-submitting it.

### 3.4 Things that keep the old name

Only the two approved exceptions (section 2.5), plus:

- `CLAUDE.md`, `AGENTS.md`, and the skill directory names
  `.claude/skills/coderelay-*` (file names are tooling conventions, their
  contents are rewritten).
- `docs/superpowers/**` history: existing specs and plans are historical
  records and are left untouched.
- `CHANGELOG.md` entries for versions before 1.5.0 keep their original text;
  the 1.5.0 entry explains the rename.
- Git history: every move is a `git mv` so `git log --follow` works.

## 4. PR 1 — mechanical layout rename

**Goal:** the repository tree, module names, project names and schemes say
CodeRelay. No user-visible behaviour changes. No binary, path, label or
version changes; those are PR 2.

### 4.1 Changes

- `git mv` the four app directories, five `Sources/` targets, five `Tests/`
  targets and `ClaudeRelay.xcodeproj` (the project is regenerated by XcodeGen
  from `project.yml`; the checked-in `.xcodeproj` and its `Package.resolved`
  are regenerated, not hand-edited).
- `Package.swift`: package name, target names, product names, paths.
- `project.yml`: `name`, target names, `path:` entries, `dependencies:`
  package product names, entitlements path
  (`CodeRelayApp/CodeRelayApp.entitlements`), test target `TEST_HOST` /
  `BUNDLE_LOADER` derivations. Bundle identifiers are **not** touched.
- Every `import ClaudeRelay*` → `import CodeRelay*`; every `@testable import`.
- Swift symbols containing `ClaudeRelay` (`ClaudeRelayApp`, `ClaudeRelayMacApp`,
  `ClaudeRelayKit` enum, and any others found by `grep -rw`) → `CodeRelay*`.
- Logger subsystems and notification names per 3.1.
- Gradle: `settings.gradle.kts` `rootProject.name` in both Kotlin projects;
  `ClaudeRelayLinux/build.gradle.kts` `androidRoot` resolves `../CodeRelayAndroid`;
  `Theme.ClaudeRelayM1` in `AndroidManifest.xml` and `themes.xml`.
- CI workflows: path filters in `android.yml`, `linux.yml`, `ci.yml`;
  `working-directory:` values; `-project CodeRelay.xcodeproj -scheme CodeRelayApp|CodeRelayMac` in `ci.yml`; `release.yml` `working-directory` and artifact `path:` entries under the Kotlin projects; the resource-bundle `find` in `release.yml` (line 256 today) and the `bin.install` in the formula (PR 2 owns the formula rename, but the bundle name changes here, so the tap formula must be updated in the same release window — see 5.6).
- `.claude/skills/coderelay-deploy/SKILL.md` scheme names and log-dir names
  (`CodeRelayMac_*`).
- `CLAUDE.md` and `AGENTS.md` and per-target `CLAUDE.md` files: module and
  directory names only (content rewrite is PR 3).
- Comments and doc-comments mentioning the old module names.

### 4.2 Verification

- `swift build && swift test` (all five test targets, renamed).
- `xcodegen generate` produces a clean project; `xcodebuild -project CodeRelay.xcodeproj -scheme CodeRelayApp build` and the same for `CodeRelayMac`, both against a simulator / local destination, plus the app test schemes.
- `./gradlew :app:assembleDebug testDebugUnitTest` in `CodeRelayAndroid`; `./gradlew build` in `CodeRelayLinux`.
- The resource bundle that `swift build -c release` emits is named
  `CodeRelay_CodeRelayServer.bundle` (macOS) — assert with `ls .build/release`.
- `grep -rIl "ClaudeRelay" --exclude-dir=.git --exclude-dir=.build --exclude-dir=docs/superpowers .` returns only `CHANGELOG.md`.
- All four GitHub workflows green on the PR.
- Smoke: build and run the server from the branch against a scratch config
  dir (`CLAUDE_RELAY_ADMIN_PORT` still the old name in PR 1), pair the macOS
  app, open a session. Nothing on disk under `~/.claude-relay` changes format.

## 5. PR 2 — user-facing rename and version unification

**Goal:** every name a user types, sees or configures says CodeRelay, and
every artifact reports `1.5.0`.

### 5.1 CLI, server and config paths

- `Package.swift` executable product names `coderelay` and `coderelay-server`.
- `RelayConfig` base directory `~/.coderelay/`; every derived path (config,
  tokens, agents, hooks, bin, push registration store, log files) follows.
- `LaunchdService`: label `com.coderelay.server`, plist file name, binary
  fallback chain (`~/.coderelay/bin/coderelay-server`, sibling of the CLI,
  `/opt/homebrew/bin`, `/usr/local/bin`).
- `ServiceManagerDetector`: labels `homebrew.mxcl.coderelay` and
  `com.coderelay.server`; every "run this instead" hint prints `coderelay …`
  and `brew services … coderelay`.
- `SystemdService` / `SystemdUnitDetector` / `ServicePlatform`: `coderelay.service`.
- `HookCommands`: script name, destination, display path, search candidates
  (`share/coderelay`).
- `Scripts/hooks/claude-relay-state-hook.sh` → `Scripts/hooks/coderelay-state-hook.sh`
  (`git mv`); its README; the hook reads `CODERELAY_ADMIN_PORT` and
  `CODERELAY_SESSION_ID`.
- `PTYSession` and `AgentStateDetector` export `CODERELAY_SESSION_ID`;
  `AdminRoutes` / CLI read `CODERELAY_ADMIN_PORT`.
- CLI `--version`, `status`, `health`, `setup` output and every user-facing
  string that says `claude-relay`.
- The pairing QR payload (`clauderelay://` was already renamed to `coderelay://`)
  is unchanged.

### 5.2 Packaging

- `Formula/clauderelay.rb` → `Formula/coderelay.rb`, class `Coderelay`,
  `bin.install` of both binaries and the `CodeRelay_CodeRelayServer.bundle`,
  `pkgshare.install "Scripts/hooks/coderelay-state-hook.sh"`, `service do`
  block runs `coderelay-server` with logs under `var/log/coderelay`, `test do`
  runs `coderelay --version`.
- `packaging/PKGBUILD`: source tarball name, installed binary names, unit and
  hook file names, `provides`/`conflicts` per 3.2, `share/coderelay`.
- `packaging/claude-relay.service` → `packaging/coderelay.service`;
  `packaging/coderelay-server.install` text.
- `ClaudeRelayLinux/packaging/PKGBUILD` (now `CodeRelayLinux/packaging/PKGBUILD`),
  `coderelay.desktop`, jpackage `packageName` per 3.3.

### 5.3 Version: one number, four fields, one gate

The tag is the release identity. The in-repo fields must equal it, and CI
refuses to release when they do not.

| Field | New value for 1.5.0 | File |
|---|---|---|
| `CodeRelayKit.version` | `"1.5.0"` | `Sources/CodeRelayKit/CodeRelayKit.swift` |
| iOS `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `1.5.0` / `184` | `project.yml` |
| macOS `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `1.5.0` / `105` | `project.yml` |
| Android `versionName` / `versionCode` | `"1.5.0"` / `50` | `CodeRelayAndroid/app/build.gradle.kts` |
| Linux client | tag, as today (`-PappVersion`) | `release.yml` |
| Formula `url` tag, PKGBUILD `pkgver` (both) | bumped by the `homebrew` and `aur` jobs from the tag, as today | tap repo, `packaging/PKGBUILD`, `CodeRelayLinux/packaging/PKGBUILD` |

Rules:

- **Bump all four fields in the same commit**, message
  `chore(release): 1.5.0 (iOS build 184, macOS build 105, Android versionCode 50)`.
  Build counters increase by one per store upload, independently of the
  product version, exactly as today; the counters are shown as `1.5.0 (184)`.
- **`release.yml` `resolve-version`** gains a `verify-version` step that reads
  the four fields and fails the run with a one-line diff if any differs from
  the tag. This is the gate that makes "one version" true rather than aspirational.
- **Pre-releases**: `vX.Y.Z-rc.N` tags are accepted (the regex is already
  unanchored at the end); the `release` job marks them `prerelease: true`
  and the `homebrew` and `aur` jobs skip them. This replaces the
  `android-v0.3-mNN` series for "try this build on the phone" drops — one tag,
  all artifacts, same version fields (`versionName "1.5.0-rc.1"`). Not
  required for 1.5.0 itself; it is documented so nobody reinvents the
  milestone scheme.
- **`android.yml` and `linux.yml`** stay CI-only (no uploads).
- The `release.yml` comment "The Android versionName is its own milestone
  scheme" and the body template lines that print two Android numbers are
  replaced by the single version plus `versionCode` in parentheses.
- `CodeRelayAndroid/RELEASE.md` is rewritten for the unified scheme (or
  folded into `docs/releasing.md`, see PR 3).

### 5.4 Wire compatibility

The wire protocol and `protocolVersion` are unchanged. A 1.5.0 client talks to
a 0.3.24 server and vice versa. The rename changes nothing on the socket.

### 5.5 Release workflow (`release.yml`)

- Artifact names per 3.2 and 3.3; `checksums.txt` follows.
- Body template: `brew install miguelriotinto/coderelay/coderelay`,
  `coderelay setup`, `systemctl --user enable --now coderelay.service`,
  unified version line, Android line shows `1.5.0 (versionCode 50)`.
- `homebrew` job: checks out `miguelriotinto/homebrew-coderelay`, seds
  `Formula/coderelay.rb`, commit message `coderelay X.Y.Z`. Stale comment
  "homebrew-clauderelay" (line 547) fixed.
- `aur` job: extended with a second matrix entry so `coderelay-server-bin`
  is bumped alongside `coderelay-bin`. Today only the client package is
  automated; the server PKGBUILD in `packaging/` is bumped in-repo but never
  pushed to AUR by CI. Both entries pass the same SSH key secret.
- The best-effort macOS `build` job keeps `continue-on-error: true`; its
  tarball is renamed only.

### 5.6 Homebrew tap repository (`miguelriotinto/homebrew-coderelay`)

Done by hand once, in the same release window as merging PR 2 (the tap is a
separate repo; the release job only bumps the version inside the formula):

1. Add `Formula/coderelay.rb` with `url` pointing at `v1.5.0` (the job fills in
   the sha256 on first release; until then `brew install` of the new formula
   fails, which is acceptable for the minutes between merge and tag).
2. Delete `Formula/clauderelay.rb`.
3. Rewrite the tap `README.md`; set the repo description to
   "Homebrew tap for CodeRelay — remote terminal relay server and CLI".

### 5.7 Deploy and health skills

`.claude/skills/coderelay-deploy/SKILL.md` and `coderelay-health/SKILL.md`
(and the older copies under `.agents/skills/`, which are deleted as
duplicates):

- Version-bump step: one version, four fields, one commit (5.3).
- Scheme names `CodeRelayApp` / `CodeRelayMac`; log-dir prefix `CodeRelayMac_*`.
- Publish commands and verification use `coderelay`, `brew … coderelay`,
  `~/.coderelay`.
- Health table gains rows for the Linux server tarball, the Linux client
  tarball and both AUR packages, and asserts that every published artifact
  reports the same version.

### 5.8 Migration (hard cut) — what users must do

Written into the 1.5.0 CHANGELOG entry and release body. Nothing in code
softens it.

**macOS host, Homebrew install**

```
brew services stop clauderelay
brew uninstall clauderelay
brew untap miguelriotinto/clauderelay   # if tapped under the old name
brew install miguelriotinto/coderelay/coderelay
mv ~/.claude-relay ~/.coderelay          # keeps tokens, config, agents
coderelay hook install                   # rewrites ~/.claude/settings.json hook path
brew services start coderelay
```

**macOS host, `claude-relay load` install**

```
claude-relay unload
mv ~/.claude-relay ~/.coderelay
coderelay load --ws-port 9200
coderelay hook install
```

**Linux host (AUR)**

```
systemctl --user disable --now claude-relay.service
sudo pacman -Syu coderelay-server-bin   # replaces the old files in place
mv ~/.claude-relay ~/.coderelay
systemctl --user enable --now coderelay.service
coderelay hook install
```

**Claude Code hook.** `~/.claude/settings.json` on every host references
`~/.claude-relay/hooks/claude-relay-state-hook.sh`. Until `coderelay hook install`
is re-run, Claude Code logs a missing-hook error on every turn and the
sidebar state indicators degrade to output-based detection. The CHANGELOG says
this in bold.

**Devices.** Tokens are stored under keys that do not change (2.5), so iOS,
macOS, Android and Linux clients keep their saved servers. If the user does
not `mv` the config dir, the server starts with an empty token store and every
device must re-pair; the release notes state this.

**Android APK.** Locally built and CI-built APKs are signed with different
debug keys, so Android refuses to install one over the other. The release
notes tell the user to uninstall before installing 1.5.0. Creating a real
release keystore and the four `ANDROID_KEYSTORE_*` secrets is out of scope for
this spec and tracked separately.

### 5.9 Verification

- Everything in 4.2 again.
- `swift run coderelay --version` prints `1.5.0`; `curl 127.0.0.1:9100/health`
  reports `1.5.0`.
- Fresh-machine simulation: with `HOME` pointed at an empty temp dir,
  `coderelay load --ws-port 9201`, `coderelay status`, `coderelay setup`,
  `coderelay hook install`, `coderelay unload`. Assert `~/.coderelay/` is the
  only directory created, the plist is `com.coderelay.server.plist`, and
  `settings.json` points at `~/.coderelay/hooks/coderelay-state-hook.sh`.
- `grep -rIn "claude-relay\|claude_relay\|CLAUDE_RELAY\|clauderelay\|com\.claude\.relay" --exclude-dir=.git --exclude-dir=.build --exclude-dir=docs/superpowers .`
  returns only: bundle identifiers in `project.yml` and `Info.plist`,
  the persistence keys and model directory listed in 2.5, `CHANGELOG.md`
  history, and the migration commands in the CHANGELOG 1.5.0 entry.
- `brew install --build-from-source Formula/coderelay.rb` on this machine
  succeeds and `brew test coderelay` passes.
- `makepkg --printsrcinfo` for both PKGBUILDs parses; `namcap` clean.
- Deploy a `v1.5.0-rc.1` pre-release from the branch to prove the workflow
  end to end before tagging `v1.5.0`.

## 6. PR 3 — documentation and GitHub presence

**Goal:** a reader landing on the repo understands in one screen what
CodeRelay is, which two servers and four clients exist, how to install each,
and how versions work. Deep material moves out of the README into `docs/`.

### 6.1 Root `README.md` (target ≤ 200 lines)

1. **Title and one-paragraph pitch.** CodeRelay: run coding agents on a
   machine you own, drive them from any device. Badges: release, CI, license.
2. **Platform matrix.**

   | | macOS | Linux | iOS | Android |
   |---|---|---|---|---|
   | Server + CLI | Homebrew | AUR / tarball | — | — |
   | Client app | TestFlight / App Store | AUR / tarball | TestFlight / App Store | GitHub Releases APK |

   Each cell links to the install page. One line below: "All artifacts of a
   release share one version. Check it with `coderelay --version` and in each
   app's Settings."
3. **Quick start** (host: install, `coderelay setup`; device: scan the QR).
4. **Features**, grouped: sessions and agents, terminal, voice, notifications,
   clipboard, security. Six to eight bullets, no sub-sections.
5. **How it works**: one diagram (server, clients, WebSocket, admin API).
6. **Documentation index** linking to `docs/`.
7. **Contributing**, **Security**, **License** as one line each pointing at the
   files.

Removed from the README (moved, not deleted): CLI reference, config keys, TLS
setup, wire protocol, admin API, development guide, security details.

### 6.2 `docs/` pages

| Page | Content | Source today |
|---|---|---|
| `docs/install.md` | Per-platform sections: macOS server (Homebrew, `load`), Linux server (AUR, tarball, systemd), iOS, macOS app, Android (APK, uninstall-first note), Linux client (AUR, tarball). When TLS is required. | README Installation + Quick Start, `ClaudeRelayLinux/README.md`, `RELEASE.md` |
| `docs/cli.md` | Full `coderelay` command reference | README CLI Commands |
| `docs/configuration.md` | Every config key with defaults, TLS, push setup, app-side settings | README Configuration, CLAUDE.md config section (user-facing parts) |
| `docs/protocol.md` | Wire protocol, envelope, binary frames, scrollback replay, protocol version, admin API | README Wire Protocol + Admin API |
| `docs/security.md` | Threat model, tokens, pairing, TLS, rate limits, what is and is not logged | README Security |
| `docs/development.md` | Build and test per target, project layout (new names), XcodeGen, running a dev server, hooks for Claude Code | README Development |
| `docs/releasing.md` | Versioning policy (one version, build counters, rc tags), the release checklist, what CI does per tag, the two manual steps (tap, App Store) | `RELEASE.md`, deploy skill, `CHANGELOG.md` header |
| `docs/versions.md` | Short: where to read the version on each artifact, compatibility statement (protocol version, minimum server for each client feature) | new |

Existing `docs/*-spec.md` and `docs/android-parity-audit.md` move to
`docs/design/` so the top-level `docs/` is the user manual. Links updated.

Per-platform READMEs (`CodeRelayApp/README.md`, `CodeRelayMac/README.md`,
`CodeRelayLinux/README.md`, `CodeRelayAndroid/README.md` new) become short
developer-facing pages: how to build and run this target, and a link to
`docs/install.md` for users. `CodeRelayAndroid/RELEASE.md` is deleted; its
content lives in `docs/releasing.md`.

### 6.3 Repository hygiene files

- `CONTRIBUTING.md`: fork/branch/PR flow, `swift test` and Gradle tests must
  pass, commit message convention (`type(scope): …`, the `Co-Authored-By`
  trailer used in this repo), where design docs go, how to propose a feature.
- `SECURITY.md`: supported versions (latest 1.x), private disclosure via
  GitHub Security Advisories, what counts as in scope (server, CLI, apps),
  response expectation.
- `.github/ISSUE_TEMPLATE/bug_report.yml`: platform (server macOS / Linux,
  client iOS / macOS / Android / Linux), version from `coderelay --version`
  and app Settings, steps, logs pointer (`coderelay logs show`).
- `.github/ISSUE_TEMPLATE/feature_request.yml`.
- `.github/PULL_REQUEST_TEMPLATE.md`: what changed, how verified, docs
  updated, version fields untouched unless this is a release commit.
- `LICENSE` unchanged.

### 6.4 `CHANGELOG.md`

- New top entry `[1.5.0] - <release date>` with sections: **Renamed**
  (the naming table in prose, migration commands from 5.8), **Changed**
  (single version scheme, Android milestone scheme retired), **Fixed**
  (the Android fix already in the working tree: editing a server right after
  saving it showed the pre-save values).
- Header paragraph rewritten: one product version since 1.5.0; earlier
  entries list server versions, with app versions noted where they diverged.
  The sentence "macOS starts at 0.1.0" is removed.
- Old entries are not edited.

### 6.5 `CLAUDE.md` and `AGENTS.md`

Rewritten for the new names and paths, and trimmed of the material that now
lives in `docs/` (link to it instead). The architectural invariants stay in
`CLAUDE.md` because they are for agents, not users.

### 6.6 GitHub repository settings

Via `gh repo edit miguelriotinto/CodeRelay`:

- Description: "Run coding agents on your own machine, drive them from iOS,
  Android, macOS or Linux. Server for macOS and Linux."
- Homepage: the repo README (no separate site exists).
- Topics: `claude-code`, `terminal`, `remote-terminal`, `websocket`, `swift`,
  `swiftui`, `kotlin`, `jetpack-compose`, `ios`, `android`, `macos`, `linux`,
  `homebrew`, `aur`.

Local clone remote is updated from `…/clauderelay.git` to `…/CodeRelay.git`
(GitHub redirects today; the redirect is not guaranteed forever).

### 6.7 Verification

- Every relative link in `README.md`, `docs/**`, `CONTRIBUTING.md`,
  `SECURITY.md` resolves (`lychee --offline .` or a small script).
- Every command in `docs/install.md` and `docs/cli.md` is copy-pasted and run
  once on this machine (macOS server sections) and its output matches the
  doc.
- `grep -rn "ClaudeRelay\|claude-relay" README.md docs/*.md CONTRIBUTING.md SECURITY.md .github/` returns only the migration section.
- README renders at ≤ 200 lines; `wc -l`.

## 7. Sequencing and release

1. Merge PR 1. No release.
2. Merge PR 2. Add `Formula/coderelay.rb` to the tap and delete the old
   formula (5.6).
3. Merge PR 3.
4. Tag `v1.5.0-rc.1`, confirm every job passes and every artifact reports
   `1.5.0-rc.1`. Install the APK and the macOS app from that build.
5. Tag `v1.5.0`. `release.yml` publishes the Linux client and server
   tarballs, the APK, the best-effort macOS tarball, bumps the tap and both
   AUR packages. `/coderelay-deploy ios` and `/coderelay-deploy mac` upload
   builds 184 and 105.
6. `/coderelay-health` shows one version across all seven artifacts.
7. On this machine: run the Homebrew migration from 5.8, then `coderelay
   hook install`.

## 8. Out of scope

- Android release keystore and `ANDROID_KEYSTORE_*` secrets (tracked
  separately; the release notes carry the uninstall-first workaround).
- Any change to the wire protocol, bundle identifiers, or persistence keys.
- Renaming the AUR packages themselves.
- Compatibility shims of any kind.
- A documentation website.
