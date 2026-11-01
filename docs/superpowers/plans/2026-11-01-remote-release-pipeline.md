# Remote Release Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every shipped CodeRelay artifact (iOS/macOS TestFlight builds, the macOS server bottle, Android APK, Linux client and server) is built and published by GitHub Actions; the dev Mac only starts runs and verifies them.

**Architecture:** A new dispatch-only workflow `apple-release.yml` archives and uploads the Apple apps on the `xcode-27` runner, gated on CI coverage, numbering builds from App Store Connect. `release.yml` (tag `vX.Y.Z`) loses the failing macOS tarball matrix and gains an arm64 Homebrew bottle job that runs after the GitHub Release is created; the tap job then writes the bottle into both formula copies. All non-trivial logic lives in small, unit-tested Python scripts under `Scripts/ci/`; the YAML only wires them together.

**Tech Stack:** GitHub Actions (`xcode-27`, `ubuntu-latest`), Python 3.9+ stdlib (`unittest`) plus `PyJWT[crypto]` for the App Store Connect JWT, `xcodebuild`, Homebrew (`brew install --build-bottle`, `brew bottle --json`), `gh`.

**Spec:** `docs/superpowers/specs/2026-11-01-remote-release-pipeline-design.md` — read it alongside this plan.

## Global Constraints

- Apple builds use Xcode 27 on runner label `xcode-27` only; no fallback to `macos-26` (iOS 27.1 SDK gates the iPhone Duo layout).
- Python scripts run on the dev Mac's `/usr/bin/python3` (3.9): no `match`, no `X | Y` type syntax at runtime — use `from __future__ import annotations` and `Optional`.
- Gate-ignored path prefixes are exactly `CodeRelayAndroid/` and `Formula/`.
- Bundle ids: iOS `com.claude.relay`, macOS `com.claude.relay.mac`; team `T9WF95GC9T`; schemes `CodeRelayApp`, `CodeRelayMac`.
- Build tags: `ios-build-<n>`, `mac-build-<n>` (lightweight, on the built commit).
- Concurrency group `apple-release-<platform>`, `cancel-in-progress: false`.
- "What to Test" job: `timeout-minutes: 90`; its failure never fails the upload job.
- Bottle: arm64 only, built on `xcode-27`, uploaded to the existing release; only the `homebrew` job depends on it.
- Secrets: the `.p8` is never echoed; written mode 600 and removed in an `always()` step.
- `ci.yml` is not modified by this project.
- The tap is `miguelriotinto/homebrew-coderelay`; the install command is `brew install miguelriotinto/coderelay/clauderelay`.

## Review Focus

1. **Gate on a merge commit or a long Android-only streak** — a dispatch at a merge commit whose first-parent chain reaches a green CI run within 50 commits must pass; beyond 50 it fails with a clear message rather than walking forever. (Task 1: `test_walk_limit`.)
2. **App Store Connect returns build numbers as strings, some non-numeric or with dots** (`"1.4.1"`-style legacy builds) — non-integers are ignored, never crash, never win the max. (Task 2: `test_highest_ignores_non_integer`.)
3. **First-ever build for a platform** (no builds in App Store Connect, no previous `*-build-*` tag) — next build = floor + 1 and the commit list covers all history, capped. (Task 2: `test_next_build_no_history`; Task 2: `test_what_to_test_truncates`.)
4. **Formula re-render is idempotent** — rendering the tap formula twice for the same tag (a re-run of the tap job) yields byte-identical output, and a formula that already has a `bottle do` block gets it replaced, not duplicated. (Task 3: `test_render_idempotent`, `test_render_replaces_existing_bottle`.)
5. **Bottle filename mismatch** — `brew bottle` writes `name--version.tag.bottle.tar.gz` but Homebrew downloads `name-version.tag.bottle.tar.gz`; the uploaded asset must use the single-dash name. (Task 5 Step 3 verification.)

---

### Task 1: CI coverage gate

**Files:**
- Create: `Scripts/ci/ci_gate.py`
- Test: `Scripts/ci/tests/test_ci_gate.py`

**Interfaces:**
- Produces:
  - `IGNORED_PREFIXES: tuple[str, ...] = ("CodeRelayAndroid/", "Formula/")`
  - `find_green_ancestor(chain: list[str], green: set[str], limit: int = 50) -> Optional[str]` — `chain` is first-parent SHAs newest-first starting at the dispatched SHA; returns the first SHA in `chain[:limit]` that is in `green`.
  - `uncovered_path(changed: list[str], prefixes: tuple[str, ...] = IGNORED_PREFIXES) -> Optional[str]` — first changed path not under any prefix, else `None`.
  - CLI: `python3 Scripts/ci/ci_gate.py <sha>` — exits 0 and prints `covered by <ancestor>`; exits 1 with `not on main`, `no green CI run within 50 commits`, or `<path> changed since green <ancestor>`. Uses `git merge-base --is-ancestor <sha> origin/main`, `git rev-list --first-parent --max-count=50 <sha>`, `gh api "repos/$GITHUB_REPOSITORY/actions/workflows/ci.yml/runs?head_sha=<s>&status=success" --jq .total_count`, `git diff --name-only <ancestor> <sha>`.

- [ ] **Step 1: Write the failing tests**

```python
class GateTests(unittest.TestCase):
    def test_exact_sha_green(self):
        self.assertEqual(find_green_ancestor(["a", "b"], {"a"}), "a")
    def test_nearest_ancestor(self):
        self.assertEqual(find_green_ancestor(["a", "b", "c"], {"c", "b"}), "b")
    def test_walk_limit(self):
        chain = [str(i) for i in range(60)]
        self.assertIsNone(find_green_ancestor(chain, {"55"}, limit=50))
    def test_android_and_formula_only_is_covered(self):
        self.assertIsNone(uncovered_path(["CodeRelayAndroid/app/x.kt", "Formula/clauderelay.rb"]))
    def test_app_path_breaks_coverage(self):
        self.assertEqual(uncovered_path(["Formula/clauderelay.rb", "CodeRelayApp/Views/A.swift"]),
                         "CodeRelayApp/Views/A.swift")
    def test_prefix_is_a_directory_not_a_string_prefix(self):
        self.assertEqual(uncovered_path(["FormulaNotes.md"]), "FormulaNotes.md")
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m unittest discover -s Scripts/ci/tests -v`
Expected: FAIL / ImportError (`ci_gate` not found).

- [ ] **Step 3: Implement `find_green_ancestor`, `uncovered_path` and the CLI `main(argv: list[str]) -> int` in `Scripts/ci/ci_gate.py`**

Tests import via `sys.path.insert(0, <Scripts/ci>)`; keep the git/gh calls inside `main` only so the two functions stay pure.

- [ ] **Step 4: Run tests — PASS**, then a live smoke check: `GITHUB_REPOSITORY=miguelriotinto/CodeRelay python3 Scripts/ci/ci_gate.py $(git rev-parse origin/main)` prints `covered by <sha>` and exits 0.

- [ ] **Step 5: Commit** `Scripts/ci/ci_gate.py Scripts/ci/tests/test_ci_gate.py` — `feat(ci): CI-coverage gate for Apple releases`.

---

### Task 2: App Store Connect helper

**Files:**
- Create: `Scripts/ci/asc.py`
- Test: `Scripts/ci/tests/test_asc.py`

**Interfaces:**
- Produces:
  - `highest_build(versions: list[str]) -> Optional[int]` — max of the entries that are plain non-negative integers.
  - `next_build_number(highest: Optional[int], floor: int) -> int` — `max(highest or 0, floor) + 1`.
  - `WHAT_TO_TEST_LIMIT = 4000`
  - `what_to_test_text(subjects: list[str], limit: int = WHAT_TO_TEST_LIMIT) -> str` — `"- " + subject` per line, newest first; if over `limit`, cut whole lines and end with `"- … and N more"` within the limit; empty list → `"No changes since the previous build."`.
  - CLI (network; token = ES256 JWT, `iss`=issuer id, `kid`=key id, `aud`=`appstoreconnect-v1`, 15-min expiry, via PyJWT; env `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`):
    - `python3 Scripts/ci/asc.py next-build --bundle-id <id> --floor <n>` → prints the integer. App id from `GET /v1/apps?filter[bundleId]=<id>`; versions from `GET /v1/builds?filter[app]=<appId>&limit=200&sort=-uploadedDate&fields[builds]=version`.
    - `python3 Scripts/ci/asc.py what-to-test --bundle-id <id> --build <n> --notes-file <path> [--poll-seconds 60] [--timeout-seconds 5100]` → waits until that build's `processingState == "VALID"` (`GET /v1/builds?filter[app]=<appId>&filter[version]=<n>`), then creates or PATCHes its `betaBuildLocalizations` entry for locale `en-US` with `whatsNew`. Exit 1 with the API error body on failure.

- [ ] **Step 1: Write the failing tests**

```python
def test_highest_ignores_non_integer(self):
    self.assertEqual(highest_build(["198", "1.4.1", "abc", "200", "199"]), 200)
def test_highest_empty(self):
    self.assertIsNone(highest_build([]))
def test_next_build_from_asc(self):
    self.assertEqual(next_build_number(201, 197), 202)
def test_next_build_floor_wins(self):
    self.assertEqual(next_build_number(150, 201), 202)
def test_next_build_no_history(self):
    self.assertEqual(next_build_number(None, 201), 202)
def test_what_to_test_empty(self):
    self.assertEqual(what_to_test_text([]), "No changes since the previous build.")
def test_what_to_test_lines(self):
    self.assertEqual(what_to_test_text(["fix: b", "feat: a"]), "- fix: b\n- feat: a")
def test_what_to_test_truncates(self):
    text = what_to_test_text([f"commit {i} " + "x" * 80 for i in range(200)], limit=1000)
    self.assertLessEqual(len(text), 1000)
    self.assertTrue(text.splitlines()[-1].startswith("- … and "))
```

- [ ] **Step 2: Run — FAIL** (`python3 -m unittest discover -s Scripts/ci/tests -v`).
- [ ] **Step 3: Implement the three pure functions and the two CLI subcommands in `Scripts/ci/asc.py`.** Import `jwt` lazily inside the CLI path so the tests need no third-party package.
- [ ] **Step 4: Run — PASS.** Live check with the local key (read-only call only): `ASC_KEY_ID=H8WJXYB4M3 ASC_ISSUER_ID=69a6de76-f499-47e3-e053-5b8c7c11a4d1 ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_H8WJXYB4M3.p8 python3 Scripts/ci/asc.py next-build --bundle-id com.claude.relay --floor 201` prints `202` (201 is the highest uploaded at plan time). Requires `pip3 install --user 'pyjwt[crypto]'`.
- [ ] **Step 5: Commit** — `feat(ci): App Store Connect build-number and What-to-Test helper`.

---

### Task 3: Formula renderer

**Files:**
- Create: `Scripts/ci/formula.py`
- Test: `Scripts/ci/tests/test_formula.py`

**Interfaces:**
- Produces:
  - `render(text: str, repo: str, tag: str, source_sha: str, bottle: Optional[Bottle]) -> str` where `Bottle = NamedTuple(tag: str, cellar: str, sha256: str)`. Sets the `url` to `https://github.com/<repo>/archive/refs/tags/<tag>.tar.gz`, the source `sha256` (the one directly after `url`), and — when `bottle` is given — a single block placed after `head …`:

```ruby
  bottle do
    root_url "https://github.com/<repo>/releases/download/<tag>"
    sha256 cellar: <cellar>, <bottle.tag>: "<sha256>"
  end
```

    `cellar` is written as Homebrew's JSON gives it (`:any_skip_relocation` / `:any` / a quoted path). `bottle=None` removes any existing block.
  - CLI: `python3 Scripts/ci/formula.py <formula-path> --repo R --tag T --source-sha S [--bottle-json <brew bottle --json file>]` rewrites the file in place.

- [ ] **Step 1: Write the failing tests** — fixture is the current `Formula/clauderelay.rb` read from the repo.

```python
B = Bottle("arm64_sequoia", ":any_skip_relocation", "a" * 64)
def test_render_url_and_sha(self):
    out = render(FIXTURE, "miguelriotinto/CodeRelay", "v0.3.39", "b" * 64, None)
    self.assertIn('url "https://github.com/miguelriotinto/CodeRelay/archive/refs/tags/v0.3.39.tar.gz"', out)
    self.assertIn(f'sha256 "{"b" * 64}"', out)
    self.assertIn('head "https://github.com/miguelriotinto/CodeRelay.git", branch: "main"', out)
def test_render_adds_bottle(self):
    out = render(FIXTURE, "miguelriotinto/CodeRelay", "v0.3.39", "b" * 64, B)
    self.assertIn('root_url "https://github.com/miguelriotinto/CodeRelay/releases/download/v0.3.39"', out)
    self.assertIn(f'sha256 cellar: :any_skip_relocation, arm64_sequoia: "{"a" * 64}"', out)
def test_render_replaces_existing_bottle(self):
    once = render(FIXTURE, "miguelriotinto/CodeRelay", "v0.3.39", "b" * 64, B)
    twice = render(once, "miguelriotinto/CodeRelay", "v0.3.40", "c" * 64, B._replace(sha256="d" * 64))
    self.assertEqual(twice.count("bottle do"), 1)
    self.assertNotIn("a" * 64, twice)
def test_render_idempotent(self):
    once = render(FIXTURE, "miguelriotinto/CodeRelay", "v0.3.39", "b" * 64, B)
    self.assertEqual(render(once, "miguelriotinto/CodeRelay", "v0.3.39", "b" * 64, B), once)
def test_install_block_untouched(self):
    out = render(FIXTURE, "miguelriotinto/CodeRelay", "v0.3.39", "b" * 64, B)
    self.assertEqual(out.split("def install")[1], FIXTURE.split("def install")[1])
```

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement `render` and the CLI in `Scripts/ci/formula.py`.** `--bottle-json` reads the single formula entry of `brew bottle --json` output: `bottle.tags.<tag>.sha256`, `bottle.tags.<tag>.cellar`.
- [ ] **Step 4: Run — PASS**, and `ruby -c` on a rendered copy prints `Syntax OK`.
- [ ] **Step 5: Commit** — `feat(ci): Homebrew formula renderer with bottle block`.

---

### Task 4: Apple release workflow

**Files:**
- Create: `.github/workflows/apple-release.yml`

**Interfaces:**
- Consumes: `Scripts/ci/ci_gate.py <sha>` (Task 1); `Scripts/ci/asc.py next-build|what-to-test` (Task 2).
- Produces: secrets `ASC_API_KEY_P8`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`; tags `ios-build-<n>` / `mac-build-<n>`.

Shape:
- `on: workflow_dispatch` with inputs `platform` (choice `ios|macos|both`, default `ios`) and `dry_run` (boolean, default `false` — archives and verifies `CFBundleVersion`, skips export/upload, tag and What-to-Test).
- `permissions: contents: write, actions: read`.
- Job `gate` (`ubuntu-latest`): checkout with `fetch-depth: 0`; `python3 -m unittest discover -s Scripts/ci/tests`; `python3 Scripts/ci/ci_gate.py ${{ github.sha }}` with `GH_TOKEN: ${{ github.token }}`.
- Jobs `ios` and `macos` (`needs: gate`, `if:` on the `platform` input, `runs-on: xcode-27`, `concurrency: { group: apple-release-ios|macos, cancel-in-progress: false }`), each:
  1. checkout (`fetch-depth: 0`); select newest `/Applications/Xcode_27.*.app` (copy the step from `ci.yml`'s `ios-build` job, failing if none); `xcodebuild -downloadComponent MetalToolchain`; `brew install xcodegen && xcodegen`.
  2. Write the `.p8` from `ASC_API_KEY_P8` to `$RUNNER_TEMP/AuthKey.p8` (`umask 077`); `pip3 install 'pyjwt[crypto]'`.
  3. `FLOOR` = `CURRENT_PROJECT_VERSION` of the iOS (`CodeRelayApp`) or macOS (`CodeRelayMac`) target in `project.yml`; `N=$(python3 Scripts/ci/asc.py next-build --bundle-id <id> --floor $FLOOR)`.
  4. `xcodebuild archive -scheme <scheme> -configuration Release -destination 'generic/platform=iOS'` (macOS: `'generic/platform=macOS'`) `-archivePath $RUNNER_TEMP/app.xcarchive -skipMacroValidation -allowProvisioningUpdates -authenticationKeyPath … -authenticationKeyID … -authenticationKeyIssuerID … CURRENT_PROJECT_VERSION=$N`; assert `PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion"` equals `$N`.
  5. Unless dry run: write `ExportOptions.plist` (`method` `app-store-connect`, `destination` `upload`, `signingStyle` `automatic`, `teamID` `T9WF95GC9T`), `xcodebuild -exportArchive` with the same three auth flags; fail unless the newest `$TMPDIR/<scheme>_*.xcdistributionlogs/ContentDelivery.log` contains `UPLOAD SUCCEEDED`.
  6. Unless dry run: `git tag ios-build-$N|mac-build-$N && git push origin <tag>`.
  7. Notes: previous tag = `git describe --tags --abbrev=0 --match '<prefix>-*' HEAD^` (or none); `git log --format=%s <prev>..HEAD` (all history if none) → `notes.txt`; write version, `N`, SHA and the list to `$GITHUB_STEP_SUMMARY`; upload `notes.txt` as artifact `<platform>-notes`; job output `build=$N`.
  8. `if: always()` — `rm -f $RUNNER_TEMP/AuthKey.p8`.
- Jobs `ios-what-to-test` / `macos-what-to-test` (`needs` the upload job, `if` not dry run and upload succeeded, `ubuntu-latest`, `timeout-minutes: 90`, `continue-on-error: true`): download the notes artifact, `python3 Scripts/ci/asc.py what-to-test --bundle-id <id> --build <n> --notes-file notes.txt` (the script formats via `what_to_test_text`).

- [ ] **Step 1: Write the workflow.**
- [ ] **Step 2: Lint** — `brew install actionlint && actionlint .github/workflows/apple-release.yml` → no output.
- [ ] **Step 3: Commit** — `feat(ci): Apple TestFlight release workflow`. (First real run is Task 7.)

---

### Task 5: Homebrew bottle in `release.yml`

**Files:**
- Modify: `.github/workflows/release.yml` — delete the `build` job (lines 55–121) and its use in `release.needs`; add `bottle`; rewrite `homebrew`; release notes macOS rows.

**Interfaces:**
- Consumes: `Scripts/ci/formula.py` (Task 3); `needs.release.outputs.source_sha256` (exists).
- Produces: release asset `clauderelay-<version>.<bottle-tag>.bottle.tar.gz` (single dash; `<version>` = tag without `v`).

- [ ] **Step 1: `release` job** — `needs: [resolve-version, build-linux, build-linux-server, build-android]`; drop the "macOS build above is best-effort" comment, the macOS tarball loop in the Downloads table, and the "macOS tarballs above" sentence; the Homebrew row reads `` `brew install miguelriotinto/coderelay/clauderelay` `` (the current `miguelriotinto/clauderelay/clauderelay` names a tap that does not exist).
- [ ] **Step 2: Add job `bottle`** (`needs: [resolve-version, release]`, `if: needs.release.result == 'success'`, `runs-on: xcode-27`, no `continue-on-error`): select Xcode 27 (same step as Task 4); `python3 -m unittest discover -s Scripts/ci/tests`; `brew tap-new --no-git local/ci`; copy `Formula/clauderelay.rb` into it and render with `formula.py --tag <tag> --source-sha <source_sha256>` (no bottle); `brew install --build-bottle local/ci/clauderelay`; `brew bottle --json --root-url=https://github.com/${{ github.repository }}/releases/download/<tag> local/ci/clauderelay`; rename the `--` file to the single-dash name; `gh release upload <tag> <file> --clobber`; upload the `*.json` as artifact `bottle-json`.
- [ ] **Step 3: Verify the naming rule** — `brew bottle` output filename contains `--` and the uploaded asset name does not; the job fails if `ls *.bottle.tar.gz` finds zero or more than one file.
- [ ] **Step 4: Rewrite `homebrew`** — `needs: [resolve-version, release, bottle]`, `if: needs.bottle.result == 'success'`; keep the token check; replace both `sed` steps with `python3 Scripts/ci/formula.py tap/Formula/clauderelay.rb --repo … --tag … --source-sha … --bottle-json bottle-json/*.json`; then render the same into this repo's `Formula/clauderelay.rb` on `main` (checkout `main`, render, commit `chore(formula): <tag> bottle` as `github-actions[bot]`, `git push origin main`; no-op if unchanged). The tap commit message stays `clauderelay <tag>`.
- [ ] **Step 5: Lint** — `actionlint .github/workflows/release.yml` → no output.
- [ ] **Step 6: Commit** — `feat(release): arm64 Homebrew bottle; drop the macOS tarball matrix`.

---

### Task 6: Deploy skill, health skill and docs

**Files:**
- Modify: `.claude/skills/coderelay-deploy/SKILL.md` (rewrite)
- Modify: `.claude/skills/coderelay-health/SKILL.md` (iOS/macOS and server sections)
- Create: `docs/RELEASING.md`
- Modify: `CLAUDE.md` ("Release Process", the "Ship iOS with Xcode 27.1" paragraph's "TestFlight archive is made locally" clause)

- [ ] **Step 1: Rewrite `coderelay-deploy`.** Same frontmatter. Sections: Preflight (clean `main`; for `server|android` the version-bump PR already merged — `Sources/CodeRelayKit/CodeRelayKit.swift` `version`, `CodeRelayAndroid/app/build.gradle.kts` `versionCode`/`versionName`); Apple (`gh workflow run apple-release.yml -f platform=<ios|macos|both>`, `gh run watch`, then verify: run `success`, job log contains `UPLOAD SUCCEEDED`, `git ls-remote --tags origin '<prefix>-build-*'` has the new tag, summary build number); Tag release (`git tag vX.Y.Z && git push origin vX.Y.Z`, watch `release.yml`; verify release assets include the client and server tarballs, the APK, `checksums.txt` and `clauderelay-*.bottle.tar.gz`; `gh release download` the APK and `aapt2 dump badging`; tap formula has a `bottle do` block for the tag); Mac server (`brew update && brew upgrade clauderelay && brew services restart clauderelay`, then `claude-relay status` version, `curl -s http://127.0.0.1:9100/health`, `/opt/homebrew/bin/claude-relay-server` → `Cellar/clauderelay/<version>`); Report table. State explicitly: never run `xcodebuild archive`; on a CI failure stop and report, pointing at `docs/RELEASING.md`.
- [ ] **Step 2: Health skill** — iOS/macOS: latest `ios-build-*`/`mac-build-*` tag and its run conclusion (`gh run list --workflow apple-release.yml`) instead of local archives/logs; Server: Cellar path is `<version>` (bottle), flag `HEAD-*` as "still on a HEAD install".
- [ ] **Step 3: `docs/RELEASING.md`** — one page: which workflow ships what (the spec's table), the seven secrets and how to rotate them, and a **Break glass** section with the manual archive/export commands (from the current skill's §3, including `-skipMacroValidation` and the API-key flags) marked "by hand only, when GitHub Actions or the runner is down; never from `/coderelay-deploy`". Record the App Store Connect key role that worked (filled in during Task 7).
- [ ] **Step 4: CLAUDE.md** — "Release Process" points at `docs/RELEASING.md`, says Apple builds come from `apple-release.yml` and the Mac server from the bottle; fix the Xcode paragraph's "TestFlight archive is made locally".
- [ ] **Step 5: Commit** — `docs(release): trigger-and-verify deploy skill, RELEASING.md`.

---

### Task 7: Secrets, first runs and cut-over (needs the user)

**Files:** none new; fills the key-role line in `docs/RELEASING.md`.

- [ ] **Step 1 (user):** generate the Android release keystore (`CodeRelayAndroid/RELEASE.md` §1), store it in the password manager, set the four `ANDROID_KEYSTORE_*` secrets; create App Store Connect key "GitHub Actions" and set `ASC_API_KEY_P8`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`; create the fine-grained `HOMEBREW_TAP_TOKEN` (repo `homebrew-coderelay`, Contents read/write, with expiry). Verify: `gh secret list` shows all eight new/required names.
- [ ] **Step 2:** `gh workflow run apple-release.yml -f platform=both -f dry_run=true` → run `success`; both jobs print the computed build numbers and the `CFBundleVersion` assertion passes. If signing fails on the key's role, raise the role and record the working role in `docs/RELEASING.md`.
- [ ] **Step 3:** real run `-f platform=ios` → `UPLOAD SUCCEEDED`, tag `ios-build-<n>` pushed, What-to-Test job sets the note (check in App Store Connect/TestFlight). Then `-f platform=macos`.
- [ ] **Step 4:** next server/Android release: version-bump PR, `vX.Y.Z` tag → release has the bottle asset, tap and `Formula/` both carry the `bottle do` block, APK badging shows release signing (`apksigner verify --print-certs` is not `CN=Android Debug`).
- [ ] **Step 5 (user, on the Mac):** `brew uninstall clauderelay && brew install miguelriotinto/coderelay/clauderelay` → `ls -l /opt/homebrew/bin/claude-relay-server` points at `Cellar/clauderelay/<version>` (no compile in the install output); re-grant Full Disk Access; `claude-relay status` and `/health` OK. On the phone: uninstall the Android app once, install the new APK, re-pair.
- [ ] **Step 6:** commit the recorded key role — `docs(release): record the App Store Connect CI key role`.
