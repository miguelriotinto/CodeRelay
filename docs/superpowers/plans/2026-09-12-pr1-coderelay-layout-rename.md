# PR 1 — CodeRelay mechanical layout rename — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every directory, Swift module, Xcode target/scheme, Gradle root project and in-code type that says `ClaudeRelay` says `CodeRelay`, with zero user-visible behaviour change.

**Architecture:** Five subsystem-scoped tasks (SPM package, Apple apps, Kotlin projects, CI/tooling, docs-and-gate), each ending in its own build-and-test proof and its own commit. Renames use `git mv` so history follows. Text substitution is `ClaudeRelay` → `CodeRelay` (exact case), so lowercase persisted keys (`com.clauderelay.*`) and hyphenated names (`claude-relay`) are untouched by construction; the two remaining literals that must survive are reverted explicitly.

**Tech Stack:** Swift Package Manager, XcodeGen 2.45 (`project.yml` → `CodeRelay.xcodeproj`), Gradle (Android via Homebrew OpenJDK 17; Linux client via CI), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-12-coderelay-rename-versioning-docs-design.md` — sections 3.1, 3.4 and 4.

## Global Constraints

- **Nothing user-visible changes in this PR.** CLI binary stays `claude-relay`, server binary stays `claude-relay-server`, `commandName: "claude-relay"` stays, config dir stays `~/.claude-relay`, launchd/systemd names stay, env vars stay, version stays `0.3.24`. All of that is PR 2.
- **Do not touch** (spec §2.5): `PRODUCT_BUNDLE_IDENTIFIER` values `com.claude.relay`, `com.claude.relay.mac`, `com.claude.relay.tests`, `com.claude.relay.mac.tests`; `CFBundleURLName` values; Android `applicationId`; any `"com.clauderelay.…"` string literal; `TokenStore.BEDROCK_KEY`; the literal `"ClaudeRelay"` path component in `SpeechModelStore.modelsDirectory`.
- **Rename deliberately**: `Logger(subsystem: "com.claude.relay.client")` → `"com.coderelay.client"`, `"com.claude.relay.speech"` → `"com.coderelay.speech"`; `Notification.Name("com.clauderelay.connectivityRestored")` → `"com.coderelay.connectivityRestored"`, `"com.clauderelay.mac.showServerList"` / `connectToServer` / `systemDidWake` → `com.coderelay.mac.…`; `DispatchQueue(label: "com.clauderelay.networkMonitor")` → `"com.coderelay.networkMonitor"`.
- **Leave untouched**: `CHANGELOG.md`, everything under `docs/superpowers/`, `Formula/`, `packaging/`, Kotlin package names (`relay.*`), `WM_CLASS`, `PRODUCT_NAME: "Code[Relay]"`, `Code_Relay_` test import.
- **Precondition:** the working tree has two uncommitted Android files (`ServersScreen.kt`, `SessionSidebar.kt`, the swipe-row `rememberUpdatedState` fix). Commit them first (`fix(android): read swipe-row callbacks through rememberUpdatedState`) so `git mv` of `ClaudeRelayAndroid/` moves a clean tree. Do not include them in any rename commit.
- **Branch:** `rename/coderelay-layout` off `main`.
- **Commit trailer** on every commit: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Local tool paths: `xcodegen` at `/opt/homebrew/bin/xcodegen`; Android JDK `JAVA_HOME=/opt/homebrew/opt/openjdk@17`, `ANDROID_HOME=$HOME/Library/Android/sdk`; no JDK 21 locally, so the Linux client is verified by the `linux.yml` workflow on the PR.

---

### Task 1: Rename the Swift package (Sources, Tests, Package.swift)

**Files:**
- Move: `Sources/ClaudeRelay{Kit,Server,CLI,Client,Speech}` → `Sources/CodeRelay{…}`
- Move: `Tests/ClaudeRelay{Kit,Server,CLI,Client,Speech}Tests` → `Tests/CodeRelay{…}Tests`
- Move: `Tests/CodeRelayServerTests/ClaudeRelayServerTests.swift` → `CodeRelayServerTests.swift`
- Move: `Sources/CodeRelayKit/ClaudeRelayKit.swift` → `CodeRelayKit.swift`
- Modify: `Package.swift`, every `.swift` under `Sources/` and `Tests/`, `Sources/CodeRelayServer/CLAUDE.md`, `Sources/CodeRelaySpeech/CLAUDE.md`

**Interfaces:**
- Produces: modules `CodeRelayKit`, `CodeRelayServer`, `CodeRelayCLI`, `CodeRelayClient`, `CodeRelaySpeech`; `public enum CodeRelayKit { static let version; protocolVersion; minProtocolVersion }`; CLI root `struct CodeRelay: AsyncParsableCommand` (its `commandName` is still `"claude-relay"`); SPM package `name: "CodeRelay"`; resource bundle `CodeRelay_CodeRelayServer.bundle`. Tasks 2–4 depend on these names.

- [ ] **Step 1: Commit the pending Android fix and branch**

```bash
cd /Users/miguelriotinto/Developer/CodeRelay
git add ClaudeRelayAndroid/feature-servers/src/main/kotlin/relay/feature/servers/ServersScreen.kt \
        ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/SessionSidebar.kt
git commit -m "fix(android): read swipe-row callbacks through rememberUpdatedState

rememberSwipeToDismissBoxState keeps the confirmValueChange lambda from the
row's first composition, so editing a server and reopening it showed the
pre-edit values captured by that lambda.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git checkout -b rename/coderelay-layout
git status --short   # expected: empty
```

- [ ] **Step 2: Record the baseline test count**

```bash
swift test 2>&1 | tail -3
```
Expected: last line `Executed N tests, with 0 failures` (note N; PR 1 must end with the same N).

- [ ] **Step 3: Move directories and the two name-bearing files**

```bash
for t in Kit Server CLI Client Speech; do
  git mv Sources/ClaudeRelay$t Sources/CodeRelay$t
  git mv Tests/ClaudeRelay${t}Tests Tests/CodeRelay${t}Tests
done
git mv Sources/CodeRelayKit/ClaudeRelayKit.swift Sources/CodeRelayKit/CodeRelayKit.swift
git mv Tests/CodeRelayServerTests/ClaudeRelayServerTests.swift Tests/CodeRelayServerTests/CodeRelayServerTests.swift
ls Sources Tests
```
Expected: `Sources`: CPTYShim CodeRelayCLI CodeRelayClient CodeRelayKit CodeRelayServer CodeRelaySpeech; `Tests`: the five `CodeRelay*Tests`.

- [ ] **Step 4: Substitute identifiers in Package.swift and all Swift sources**

```bash
sed -i '' 's/ClaudeRelay/CodeRelay/g' Package.swift
find Sources Tests -name '*.swift' -print0 | xargs -0 sed -i '' 's/ClaudeRelay/CodeRelay/g'
sed -i '' 's/ClaudeRelay/CodeRelay/g' Sources/CodeRelayServer/CLAUDE.md Sources/CodeRelaySpeech/CLAUDE.md
```

This turns `import ClaudeRelayKit` → `import CodeRelayKit`, `public enum ClaudeRelayKit` → `public enum CodeRelayKit`, `struct ClaudeRelay: AsyncParsableCommand` → `struct CodeRelay`, `final class ClaudeRelayServerTests` → `CodeRelayServerTests`, and the prose comments ("the ClaudeRelay server"). It also changed one string that must not change; fix it next.

- [ ] **Step 5: Restore the persisted speech-model path component**

Open `Sources/CodeRelaySpeech/SpeechModelStore.swift` around line 36–46 and make the `#else` branch read exactly:

```swift
        #else
        // "ClaudeRelay" is the on-disk directory name existing Macs already
        // have their downloaded models in. It is the product's former name and
        // is kept on purpose: renaming it would force a multi-GB re-download.
        return appSupport
            .appendingPathComponent("ClaudeRelay", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        #endif
```

Also restore the two doc-comment mentions of the path on lines ~8 and ~36 so they say `<AppSupport>/ClaudeRelay/Models/` (they describe the on-disk path, which has not changed).

- [ ] **Step 6: Rename logger subsystems, notification names and the queue label**

```bash
grep -rl 'com\.claude\.relay\.client' Sources | xargs sed -i '' 's/com\.claude\.relay\.client/com.coderelay.client/g'
grep -rl 'com\.claude\.relay\.speech' Sources | xargs sed -i '' 's/com\.claude\.relay\.speech/com.coderelay.speech/g'
sed -i '' 's/com\.clauderelay\.connectivityRestored/com.coderelay.connectivityRestored/; s/com\.clauderelay\.networkMonitor/com.coderelay.networkMonitor/' \
  Sources/CodeRelayClient/Helpers/NetworkMonitor.swift
```

- [ ] **Step 7: Assert the exceptions survived and nothing else remains**

```bash
grep -rn 'appendingPathComponent("ClaudeRelay"' Sources/CodeRelaySpeech/SpeechModelStore.swift   # expect 1 line
grep -rn '"com\.clauderelay\.' Sources | wc -l        # expect 5 (bedrock key, 2 savedConnections keys, keyPrefix, whisperDownloaded)
grep -rn 'ClaudeRelay' Sources Tests Package.swift | grep -v 'appendingPathComponent("ClaudeRelay"\|AppSupport>/ClaudeRelay/Models\|on-disk directory name'
```
Expected for the last command: no output.

- [ ] **Step 8: Build and test**

```bash
swift build 2>&1 | tail -2
swift test 2>&1 | tail -3
swift build -c release --product claude-relay-server 2>&1 | tail -1
ls .build/release | grep -i 'CodeRelay_CodeRelayServer'
```
Expected: build succeeds; `Executed N tests, with 0 failures` with the same N as Step 2; `ls` prints `CodeRelay_CodeRelayServer.bundle`.

If the `PTYSessionCwdTests` case fails, that is a known deterministic local failure on clean `main` as well (see `git stash && swift test --filter PTYSessionCwdTests` to confirm); every other test must pass.

- [ ] **Step 9: Commit**

```bash
git add -A Sources Tests Package.swift
git commit -m "refactor: rename Swift package and modules ClaudeRelay* -> CodeRelay*

Directories, targets, products, the Kit enum, the CLI root type and the
server test class follow the product name. Logger subsystems and
notification names move to com.coderelay.*. The macOS speech-model
directory and every persisted com.clauderelay.* key are unchanged so no
device loses data. No user-visible change: binaries, commandName, config
paths and version are untouched (PR 2).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Rename the Apple app targets and regenerate the Xcode project

**Files:**
- Move: `ClaudeRelayApp/` → `CodeRelayApp/`, `ClaudeRelayMac/` → `CodeRelayMac/`, `ClaudeRelayAppTests/` → `CodeRelayAppTests/`, `ClaudeRelayMacTests/` → `CodeRelayMacTests/`
- Move: `CodeRelayApp/ClaudeRelayApp.swift` → `CodeRelayApp.swift`, `CodeRelayApp/ClaudeRelayApp.entitlements` → `CodeRelayApp.entitlements`, `CodeRelayMac/ClaudeRelayMacApp.swift` → `CodeRelayMacApp.swift`, `CodeRelayMac/ClaudeRelayMac.entitlements` → `CodeRelayMac.entitlements`
- Move: `ClaudeRelay.xcodeproj/` → `CodeRelay.xcodeproj/` (then regenerated)
- Modify: `project.yml`, every `.swift` under the four app dirs, `CodeRelayApp/README.md`, `CodeRelayMac/README.md`

**Interfaces:**
- Consumes: modules `CodeRelayClient`, `CodeRelaySpeech`, `CodeRelayKit` (Task 1).
- Produces: Xcode project `CodeRelay.xcodeproj`; schemes `CodeRelayApp`, `CodeRelayMac`, `CodeRelayAppTests`, `CodeRelayMacTests`; iOS app product `CodeRelayApp.app`; types `struct CodeRelayApp: App`, `struct CodeRelayMacApp: App`. Task 4 (CI, skills) depends on the scheme names.

- [ ] **Step 1: Move directories and name-bearing files**

```bash
git mv ClaudeRelayApp CodeRelayApp
git mv ClaudeRelayMac CodeRelayMac
git mv ClaudeRelayAppTests CodeRelayAppTests
git mv ClaudeRelayMacTests CodeRelayMacTests
git mv CodeRelayApp/ClaudeRelayApp.swift CodeRelayApp/CodeRelayApp.swift
git mv CodeRelayApp/ClaudeRelayApp.entitlements CodeRelayApp/CodeRelayApp.entitlements
git mv CodeRelayMac/ClaudeRelayMacApp.swift CodeRelayMac/CodeRelayMacApp.swift
git mv CodeRelayMac/ClaudeRelayMac.entitlements CodeRelayMac/CodeRelayMac.entitlements
git mv ClaudeRelay.xcodeproj CodeRelay.xcodeproj
```

- [ ] **Step 2: Substitute identifiers in project.yml and app sources**

```bash
sed -i '' 's/ClaudeRelay/CodeRelay/g' project.yml
find CodeRelayApp CodeRelayMac CodeRelayAppTests CodeRelayMacTests -name '*.swift' -print0 | xargs -0 sed -i '' 's/ClaudeRelay/CodeRelay/g'
sed -i '' 's/ClaudeRelay/CodeRelay/g' CodeRelayApp/README.md CodeRelayMac/README.md
```

Resulting `project.yml` must read (check with `grep -n`):
- line 1: `name: CodeRelay`
- `packages:` key `CodeRelayClient:` with `path: .`
- targets `CodeRelayApp`, `CodeRelayAppTests`, `CodeRelayMac`, `CodeRelayMacTests`
- `INFOPLIST_FILE: CodeRelayApp/Info.plist`, `CODE_SIGN_ENTITLEMENTS: CodeRelayApp/CodeRelayApp.entitlements`, same pattern for Mac
- `TEST_HOST: "$(BUILT_PRODUCTS_DIR)/CodeRelayApp.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/CodeRelayApp"` (iOS product name follows the target)
- Mac `TEST_HOST` still `…/Code[Relay].app/Contents/MacOS/Code[Relay]` (unchanged, `PRODUCT_NAME` is `Code[Relay]`)
- `PRODUCT_BUNDLE_IDENTIFIER` lines unchanged: `com.claude.relay`, `com.claude.relay.tests`, `com.claude.relay.mac`, `com.claude.relay.mac.tests`; `CFBundleURLName` unchanged.

```bash
grep -n 'PRODUCT_BUNDLE_IDENTIFIER\|CFBundleURLName' project.yml
```
Expected: six lines, all still `com.claude.relay…`.

- [ ] **Step 3: Rename the macOS notification names**

```bash
sed -i '' 's/com\.clauderelay\.mac\.showServerList/com.coderelay.mac.showServerList/; s/com\.clauderelay\.mac\.connectToServer/com.coderelay.mac.connectToServer/' \
  CodeRelayMac/Helpers/RecordingShortcutMonitor.swift
sed -i '' 's/com\.clauderelay\.mac\.systemDidWake/com.coderelay.mac.systemDidWake/' CodeRelayMac/Helpers/SleepWakeObserver.swift
```

- [ ] **Step 4: Assert persisted keys survived**

```bash
grep -rn '"com\.clauderelay\.' CodeRelayApp CodeRelayMac | wc -l
```
Expected: 23 (the iOS `savedConnections` key, the iOS `keyPrefix` `"com.clauderelay"`, the Mac `savedConnections` key, the Mac `keyPrefix` `"com.clauderelay.mac"`, and the 19 settings keys in `CodeRelayMac/Models/AppSettings.swift` including `legacyBedrockKey`). The three notification names renamed in Step 3 are the only `com.clauderelay` literals that should be gone. If the count is lower, a persisted key was renamed — `git diff` the file and revert that line.

```bash
grep -rn 'ClaudeRelay' project.yml CodeRelayApp CodeRelayMac CodeRelayAppTests CodeRelayMacTests
```
Expected: no output.

- [ ] **Step 5: Regenerate the Xcode project**

```bash
rm -rf CodeRelay.xcodeproj/project.pbxproj CodeRelay.xcodeproj/xcuserdata
xcodegen generate
git status --short CodeRelay.xcodeproj
grep -c 'ClaudeRelay' CodeRelay.xcodeproj/project.pbxproj
```
Expected: `project.pbxproj` and `project.xcworkspace/contents.xcworkspacedata` show as modified/renamed, `Package.resolved` unchanged (same pins), and the grep count is `0`.

- [ ] **Step 6: Build both apps the way CI does**

```bash
xcodebuild -project CodeRelay.xcodeproj -scheme CodeRelayApp \
  -destination 'generic/platform=iOS' -configuration Debug -skipMacroValidation \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
xcodebuild -project CodeRelay.xcodeproj -scheme CodeRelayMac \
  -configuration Debug -skipMacroValidation \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **` twice.

- [ ] **Step 7: Run both app test bundles**

```bash
xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E 'Executed|TEST (SUCCEEDED|FAILED)' | tail -3
xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayMac \
  -destination 'platform=macOS' -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E 'Executed|TEST (SUCCEEDED|FAILED)' | tail -3
```
Expected: `** TEST SUCCEEDED **` for both. (The Mac test bundle's `@testable import Code_Relay_` is unchanged because `PRODUCT_NAME` did not change.)

- [ ] **Step 8: Commit**

```bash
git add -A project.yml CodeRelay.xcodeproj CodeRelayApp CodeRelayMac CodeRelayAppTests CodeRelayMacTests
git commit -m "refactor: rename Apple app targets, schemes and Xcode project to CodeRelay

ClaudeRelay.xcodeproj -> CodeRelay.xcodeproj (regenerated by XcodeGen),
targets/schemes CodeRelayApp, CodeRelayMac and their test bundles, app
entry types and entitlements files. Bundle identifiers, URL scheme names,
PRODUCT_NAME and every persisted com.clauderelay.* key are unchanged.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Rename the Kotlin projects (Android and Linux)

**Files:**
- Move: `ClaudeRelayAndroid/` → `CodeRelayAndroid/`, `ClaudeRelayLinux/` → `CodeRelayLinux/`
- Modify: `CodeRelayAndroid/settings.gradle.kts:23`, `CodeRelayAndroid/app/src/main/AndroidManifest.xml:47,54`, `CodeRelayAndroid/app/src/main/res/values/themes.xml:5`, `CodeRelayAndroid/app/proguard-rules.pro:2`, `CodeRelayAndroid/app/src/main/res/xml/network_security_config.xml:3`, `CodeRelayAndroid/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml:4`, `CodeRelayAndroid/ml/{_common.py,validate_parity.py,README.md}`, `CodeRelayAndroid/RELEASE.md`, `CodeRelayLinux/settings.gradle.kts:24,28,33`, `CodeRelayLinux/build.gradle.kts:35`, `CodeRelayLinux/gradle/libs.versions.toml:3,12`, `CodeRelayLinux/README.md`, `.gitignore:22`, 78 Kotlin files (comments only), `tools/speech/convert_smart_turn.py`

**Interfaces:**
- Consumes: `Sources/CodeRelaySpeech/Resources`, `Tests/CodeRelaySpeechTests/Fixtures` (Task 1 paths, referenced by the ml scripts).
- Produces: Gradle roots `CodeRelayAndroid`, `CodeRelayLinux`; `extra["androidRoot"]` → `../CodeRelayAndroid`; theme `Theme.CodeRelayM1`. Task 4 (workflow path filters) depends on the directory names.

- [ ] **Step 1: Move directories**

```bash
git mv ClaudeRelayAndroid CodeRelayAndroid
git mv ClaudeRelayLinux CodeRelayLinux
```

- [ ] **Step 2: Substitute in every tracked text file under both trees, plus the three outside references**

```bash
git ls-files CodeRelayAndroid CodeRelayLinux -z \
  | grep -zvE '\.(png|jpg|jpeg|webp|ico|icns|jar|so|bin|keystore|json)$' \
  | xargs -0 grep -lZ 'ClaudeRelay' 2>/dev/null \
  | xargs -0 sed -i '' 's/ClaudeRelay/CodeRelay/g'
sed -i '' 's/ClaudeRelay/CodeRelay/g' .gitignore tools/speech/convert_smart_turn.py
```

Then confirm the load-bearing lines read:

```bash
grep -n 'rootProject.name' CodeRelayAndroid/settings.gradle.kts CodeRelayLinux/settings.gradle.kts
grep -n 'androidRoot' CodeRelayLinux/build.gradle.kts
grep -n 'Theme\.' CodeRelayAndroid/app/src/main/AndroidManifest.xml CodeRelayAndroid/app/src/main/res/values/themes.xml
grep -n 'CodeRelay' .gitignore
```
Expected:
```
CodeRelayAndroid/settings.gradle.kts:23:rootProject.name = "CodeRelayAndroid"
CodeRelayLinux/settings.gradle.kts:24:rootProject.name = "CodeRelayLinux"
CodeRelayLinux/build.gradle.kts:35:extra["androidRoot"] = rootProject.projectDir.parentFile.resolve("CodeRelayAndroid")
…AndroidManifest.xml:47:        android:theme="@style/Theme.CodeRelayM1">
…AndroidManifest.xml:54:            android:theme="@style/Theme.CodeRelayM1"
…themes.xml:5:    <style name="Theme.CodeRelayM1" parent="android:Theme.Material.Light.NoActionBar" />
.gitignore:22:CodeRelayLinux/dist/
```

- [ ] **Step 3: Assert Android identity and persisted key survived**

```bash
grep -n 'applicationId' CodeRelayAndroid/app/build.gradle.kts          # expect com.singular.coderelay
grep -rn 'com.clauderelay.bedrock.bearerToken' CodeRelayAndroid           # expect 1 line in TokenStore
grep -rn 'ClaudeRelay' CodeRelayAndroid CodeRelayLinux .gitignore tools   # expect no output
```

- [ ] **Step 4: Build and test the Android project**

```bash
cd /Users/miguelriotinto/Developer/CodeRelay/CodeRelayAndroid
JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=$HOME/Library/Android/sdk \
  ./gradlew testDebugUnitTest assembleDebug --no-daemon 2>&1 | tail -5
cd ..
```
Expected: `BUILD SUCCESSFUL`. The theme rename is exercised by `assembleDebug` (manifest merge + resource link fail if `Theme.CodeRelayM1` did not resolve).

- [ ] **Step 5: Sanity-check the Linux project configuration without a JDK 21**

No JDK 21 is installed locally, so the full Linux build is verified by the `linux.yml` workflow on the PR (Task 4). Locally, confirm every shared module still resolves its source directory:

```bash
for d in core-protocol core-net core-session terminal feature-servers feature-workspace feature-settings; do
  test -d CodeRelayAndroid/$d/src/main/kotlin && echo "ok $d" || echo "MISSING $d"
done
```
Expected: seven `ok` lines.

- [ ] **Step 6: Commit**

```bash
git add -A CodeRelayAndroid CodeRelayLinux .gitignore tools/speech/convert_smart_turn.py
git commit -m "refactor: rename Kotlin projects ClaudeRelayAndroid/Linux -> CodeRelayAndroid/Linux

Gradle root projects, the Linux build's androidRoot, the Android theme
name and comments follow. applicationId, the Kotlin package root and the
Keychain-equivalent BEDROCK_KEY are unchanged.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Update CI workflows, skills and lint config

**Files:**
- Modify: `.github/workflows/ci.yml` (lines 6, 10, 130–131, 169–170), `.github/workflows/android.yml` (6, 11, 24), `.github/workflows/linux.yml` (7, 12–39, 52), `.github/workflows/release.yml` (87, 156, 162, 168, 200, 203, 256, 311, 404, 622, 689), `.swiftlint.yml:1`, `.claude/skills/coderelay-deploy/SKILL.md`, `.claude/skills/coderelay-health/SKILL.md`, `.agents/skills/coderelay-deploy/SKILL.md`, `.agents/skills/coderelay-health/SKILL.md`

**Interfaces:**
- Consumes: directory names (Task 3), scheme names `CodeRelayApp`/`CodeRelayMac` and project `CodeRelay.xcodeproj` (Task 2), bundle `CodeRelay_CodeRelayServer.{bundle,resources}` (Task 1).
- Produces: green `ci.yml`, `android.yml`, `linux.yml` on the PR.

- [ ] **Step 1: Substitute**

```bash
sed -i '' 's/ClaudeRelay/CodeRelay/g' .github/workflows/ci.yml .github/workflows/android.yml \
  .github/workflows/linux.yml .github/workflows/release.yml .swiftlint.yml \
  .claude/skills/coderelay-deploy/SKILL.md .claude/skills/coderelay-health/SKILL.md \
  .agents/skills/coderelay-deploy/SKILL.md .agents/skills/coderelay-health/SKILL.md
```

- [ ] **Step 2: Check the three lines where the substitution must produce a specific result**

```bash
sed -n 256p .github/workflows/release.yml
sed -n 622p .github/workflows/release.yml
grep -n 'xcodeproj\|-scheme' .github/workflows/ci.yml
```
Expected:
- line 256 contains `-name 'CodeRelay_CodeRelayServer.resources' -o -name 'CodeRelay_CodeRelayServer.bundle'` (this is what SPM now emits — Task 1 Step 8 proved it).
- line 622 reads `git commit -m "clauderelay ${TAG_NAME}" -m "Automated bump from CodeRelay release workflow."` — the **formula name `clauderelay` stays** here; only the prose changed. PR 2 renames the formula.
- `ci.yml`: `-project CodeRelay.xcodeproj`, `-scheme CodeRelayApp`, `-scheme CodeRelayMac`.

```bash
grep -rn 'ClaudeRelay' .github .swiftlint.yml .claude .agents
```
Expected: no output.

- [ ] **Step 3: Validate workflow YAML parses**

```bash
for f in .github/workflows/*.yml; do python3 -c "import yaml,sys; yaml.safe_load(open('$f'))" && echo "ok $f"; done
swiftlint lint --quiet 2>&1 | tail -1
```
Expected: four `ok` lines; swiftlint runs (warnings count unchanged from `main` — this task only edited its header comment).

- [ ] **Step 4: Commit**

```bash
git add .github .swiftlint.yml .claude .agents
git commit -m "ci: follow the CodeRelay directory, project and scheme names

Path filters, working directories, xcodebuild project/scheme and the
SPM resource-bundle name in release.yml; deploy/health skills updated
to the new scheme and directory names. The Homebrew formula name is
still clauderelay here (renamed in PR 2).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Update agent docs and the README for the new names, then run the repo-wide gate

**Files:**
- Modify: `CLAUDE.md`, `AGENTS.md`, `README.md` (names and paths only — the content rewrite is PR 3), `docs/linux-server-spec.md`, `docs/linux-client-spec.md`, `docs/android-parity-audit.md`, `docs/claude-code-recommendations.md`, `docs/herdr-feature-spec.md` (path references only)
- Leave: `CHANGELOG.md`, `docs/superpowers/**`, `Formula/`, `packaging/`

**Interfaces:**
- Consumes: every name from Tasks 1–4.
- Produces: the PR.

- [ ] **Step 1: Substitute in the agent docs, README and design docs**

```bash
sed -i '' 's/ClaudeRelay/CodeRelay/g' CLAUDE.md AGENTS.md README.md \
  docs/linux-server-spec.md docs/linux-client-spec.md docs/android-parity-audit.md \
  docs/claude-code-recommendations.md docs/herdr-feature-spec.md
```

- [ ] **Step 2: Fix the two places where a plain substitution is wrong**

In `README.md` line 1 the title becomes `# CodeRelay` — correct, keep. In `CLAUDE.md` the sentence in "iOS app" that says `Open CodeRelay.xcodeproj in Xcode` is now correct. Search both for install commands that mention the *formula* or *binary*, which must still say the old names in PR 1:

```bash
grep -n 'brew install\|claude-relay\|clauderelay' README.md CLAUDE.md | head -20
```
Expected: `brew install miguelriotinto/clauderelay/clauderelay`, `claude-relay load …` etc. are all still lowercase old names (untouched by the case-sensitive sed). Nothing to edit; this step is the check.

- [ ] **Step 3: Repo-wide gate**

```bash
grep -rIl 'ClaudeRelay' --exclude-dir=.git --exclude-dir=.build --exclude-dir=build \
  --exclude-dir=.gradle --exclude-dir=docs/superpowers . | grep -v '^./docs/superpowers/'
```
Expected output, exactly two files:
```
./CHANGELOG.md
./Sources/CodeRelaySpeech/SpeechModelStore.swift
```
(Historical changelog entries, and the deliberately kept on-disk model directory.)

```bash
grep -rn 'claude-relay-server\|"claude-relay"\|~/.claude-relay\|com\.claude\.relay"' Sources | wc -l
grep -n 'version = ' Sources/CodeRelayKit/CodeRelayKit.swift
```
Expected: the first count is non-zero (user-facing names intentionally untouched); the second prints `public static let version = "0.3.24"`.

- [ ] **Step 4: Full local verification, once more, from a clean build directory**

```bash
rm -rf .build
swift build 2>&1 | tail -1
swift test 2>&1 | tail -1
xcodegen generate >/dev/null && git status --short CodeRelay.xcodeproj    # expect: clean
```
Expected: build ok; `Executed N tests, with 0 failures`, N equal to Task 1 Step 2; regenerating the project produces no diff.

- [ ] **Step 5: Smoke-test the server binary from the branch against a scratch HOME**

```bash
export SCRATCH=$(mktemp -d)
HOME=$SCRATCH .build/debug/claude-relay-server --help 2>&1 | head -3 || true
HOME=$SCRATCH .build/debug/claude-relay --version
HOME=$SCRATCH .build/debug/claude-relay --help | head -3
```
Expected: `--version` prints `0.3.24`; `--help` shows `OVERVIEW: Manage the CodeRelay service` and `USAGE: claude-relay <subcommand>` — the binary and command names are unchanged, only the prose moved.

- [ ] **Step 6: Commit and open the PR**

```bash
git add CLAUDE.md AGENTS.md README.md docs/*.md
git commit -m "docs: use the CodeRelay module, directory and scheme names

Names and paths only; the content rewrite is a separate PR.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push -u origin rename/coderelay-layout
gh pr create --title "refactor: rename source layout ClaudeRelay -> CodeRelay" --body "$(cat <<'EOF'
## Summary
- `git mv` of every `ClaudeRelay*` directory, Swift target, test target, Xcode project/scheme and Gradle root to `CodeRelay*`
- In-code types renamed (`CodeRelayKit`, `CodeRelayApp`, `CodeRelayMacApp`, CLI root `CodeRelay`); logger subsystems and notification names moved to `com.coderelay.*`
- CI path filters, xcodebuild project/scheme, SPM resource-bundle name, deploy/health skills, agent docs follow

## Deliberately unchanged
- Binaries `claude-relay` / `claude-relay-server`, `commandName`, `~/.claude-relay`, launchd/systemd names, env vars, version `0.3.24` (PR 2)
- Bundle identifiers, `applicationId`, every persisted `com.clauderelay.*` key, the macOS `Application Support/ClaudeRelay/Models` directory (spec §2.5)
- Homebrew formula and `packaging/` (PR 2); `CHANGELOG.md` and `docs/superpowers/` history

Spec: `docs/superpowers/specs/2026-09-12-coderelay-rename-versioning-docs-design.md` §4.

## Verification
- `swift build && swift test` — same test count as `main`
- `xcodebuild` build + test for `CodeRelayApp` and `CodeRelayMac`
- `./gradlew testDebugUnitTest assembleDebug` in `CodeRelayAndroid`
- `linux.yml` on this PR is the gate for the Linux client (no JDK 21 locally)
- Repo-wide `grep ClaudeRelay` returns only `CHANGELOG.md` and the kept model-directory literal

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 7: Wait for CI and confirm all four workflows pass**

```bash
gh pr checks --watch
```
Expected: `CI` (swift + iOS + macOS jobs), `Android`, `Linux` all green. If `linux.yml` fails on a path, the culprit is almost always a leftover `ClaudeRelayAndroid` in a `srcDirs`/`androidRoot` resolution — re-run Task 3 Step 2's greps.

PR 1 is done when CI is green. Merging is the user's call.
