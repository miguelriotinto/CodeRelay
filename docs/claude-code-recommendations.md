# Claude Code Proficiency Review & Recommendations

*Based on analysis of 20 sessions (Jun 10 – Jul 7, 2026) on the ClaudeRelay repo: 186 user messages, ~2,400 tool calls, plus the current `.claude/` configuration.*

> **Status (2026-08-01): completed — historical record.** Every recommendation in
> the checklists below has landed: the ship skill exists (since renamed
> `/cr-ship` → `/coderelay-deploy`), the graph hook matcher is scoped to
> `Edit|Write`, the permission allowlist and SwiftLint hook are configured, the
> release runbook is in CLAUDE.md, and the unused skills were deleted. The
> unchecked `- [ ]` boxes are the original proposal, not outstanding work.

---

## Your usage profile

| Metric | Value | Read |
|---|---|---|
| Sessions analyzed | 20 (204 MB of transcripts) | Several span multiple days |
| User messages | 186 | ~40% are release/verification commands or "continue"/"yes" |
| Top tools | Bash (1,326), Read (315), Edit (240), Agent (53) | Healthy delegation to subagents |
| Skills invoked | 26 total (systematic-debugging, brainstorming, writing-plans…) | Good process-skill adoption |
| Compactions observed | 8 (7 in a single 67 MB session) | Context exhaustion is your #1 friction |
| Interruptions | 18 | Mostly mid-icon-saga course corrections |

**What you already do well:** you give screenshots with bug reports, you answer clarifying questions decisively ("1", "A", "yes"), you use process skills for debugging and planning, you demand verification ("did you upload…?"), and your best bug reports (numbered repro steps, e.g. the two-session keyboard bug) led directly to one-shot fixes.

---

## Top 5 improvement areas (ranked by time you'd get back)

### 1. The release workflow is your biggest time sink → automate it

**Evidence:** ~28 of 186 messages (15%) are variations of "push to testflight / upload the apk / check homebrew," and **at least 8 more are follow-ups because a step was missed or unverified**: "you did not upload the rebuilt apk," "the apk is still 2 days old," "the releases page does not have the binary!", "did you push…?" (asked 4 separate times).

**Fix:** a project skill — `/cr-ship` — that encodes the whole pipeline *including end-to-end verification* so the trust-but-verify follow-ups disappear. See [Automation #1](#automation-1-a-ship-skill) below.

### 2. Long-running sessions exhaust context → one task, one session

**Evidence:** 12+ bare "continue" messages, 8 compactions, sessions spanning 5+ days (Jun 14→19, Jun 16→20). Each compaction loses nuance; the terminal-redraw feature took 4 summarized handoffs to land.

**Fix:**
- Start a fresh session per task; `/clear` between unrelated asks in the same sitting.
- For big features, have Claude **write the plan to a file first** (`docs/superpowers/plans/` — you already do this sometimes), then execute from the plan in a fresh session. Plans survive compaction; conversation memory does not.
- Push heavy exploration into subagents (Explore agent / `Agent` tool) so raw file dumps never enter the main context. You already use `Agent` well — extend the habit to *reading* tasks, not just parallel work.

### 3. Visual iteration loops burn full release cycles → front-load acceptance criteria, verify locally

**Evidence:** the macOS icon saga: ~20 messages, 10+ TestFlight builds ("build 61 is still not correct"), each round-trip costing archive + upload + install. It ended only when you (a) provided the exact assets yourself (`./AppIcons`) and (b) gave a numbered acceptance spec ("1. review the attached image, 2. acknowledge the problem, 3. resolve").

**Lessons that generalize:**
- Give the **complete spec in message one**: "1024×1024 opaque PNG, black rounded tile inset ~10%, white logo 65–75% of tile" would have collapsed 20 messages into 2. When you find yourself typing "still not ok" a third time, stop and write the full spec or supply the asset.
- Demand **local verification before shipping**: "render the iconset at Finder sizes and show me a screenshot *before* archiving." Claude can composite/preview images locally — a 10-second check versus a 15-minute TestFlight round-trip.
- These lessons are now in memory (`macos-app-icon-needs-10pct-margin`), which is the right pattern — after any painful discovery, say "remember this" so it persists.

### 4. Recurring device bugs get lost between sessions → track them as GitHub issues

**Evidence:** the Huawei Fold bug (can't swipe the session pane in fold-open mode; fold transition kicks you to server view) was reported verbatim **three times** (Jun 10, and twice on Jul 1) and appears to have never been fixed — each report landed in a different session with no durable tracking.

**Fix:** when you report a device bug you don't want fixed *right now*, say "file this as a GitHub issue" (the `gh` CLI is already authenticated; there's also a `/to-issues` skill). Then any future session can start with "work through open issues." Issues are the durable queue; chat messages are not.

### 5. Trim the config: plugin bloat and an over-eager hook

**Evidence:**
- **~30 plugins enabled**, including the `everything-claude-code` mega-plugin that injects 200+ skills into every session's context (healthcare, DeFi, logistics, trading…). Your actual usage over a month: superpowers, commit-commands, code-review, claude-code-setup, app-connect-cli, claude-mem. Every unused skill description costs context on every message of every session — this directly worsens problem #2.
- **The `code-review-graph update` PostToolUse hook fires on every `Edit|Write|Bash`** with a 30 s timeout. Bash is your most-used tool (1,326 calls) — builds, greps, and `gh` calls all trigger graph updates pointlessly. Meanwhile the graph MCP tools were called only 4 times all month, so the cost/benefit is inverted.
- The 4 orphan skills in `.claude/skills/` (debug-issue, explore-codebase, refactor-safely, review-changes) were **never invoked once** — they duplicate what CLAUDE.md already mandates.

**Fix:** disable unused plugins (biggest single context win available); narrow the hook matcher to `Edit|Write`; delete or consolidate the orphan skills. Details in [Automation #4](#automation-4-config-hygiene).

---

## Automation opportunities

### Automation #1: a `/cr-ship` skill

The highest-value automation available to you. Create `.claude/skills/cr-ship/SKILL.md`:

```markdown
---
name: cr-ship
description: Build, publish, and VERIFY all ClaudeRelay artifacts — iOS/macOS to TestFlight, Android APK to GitHub Releases, server to Homebrew. Args: ios | android | mac | server | all (default all)
disable-model-invocation: true
---

## Ship checklist (execute in order, verify every step)

### Preflight
1. `git status` must be clean and on `main`; all tests pass (`swift test`, gradle unit tests).
2. Determine what changed since the last release tags — skip platforms with no changes (confirm with user).

### Version bumps (only for platforms being shipped)
- iOS/macOS: bump build number in project.yml, regenerate with xcodegen.
- Android: bump versionCode + versionName (0.3-mNN) in app/build.gradle.kts.
- Server: bump version, update Formula/clauderelay.rb.
- Commit the bumps with the standard `chore(release):` message.

### Build & publish
- iOS: xcodebuild archive → export with build/ExportOptions.plist (destination=upload).
- Android: `./gradlew :app:assembleRelease`, copy to /tmp/CodeRelay-<version>.apk,
  `gh release create android-v<version> <apk> --prerelease` using the m20/m21 notes format.
- Server: push, verify Homebrew formula points at new version,
  `brew upgrade clauderelay && brew services restart clauderelay`.

### VERIFY (never skip — this is the point of the skill)
- iOS: grep "UPLOAD SUCCEEDED" in $TMPDIR/ClaudeRelayApp_*.xcdistributionlogs/ContentDelivery.log.
- Android: download the APK back from the release URL, `aapt2 dump badging` must show the new versionCode. Byte size alone is not proof.
- Server: `claude-relay status` must report the new version; `curl 127.0.0.1:9100/health` must be ok.
- Report a table: platform | version | verified-by | link.
```

`disable-model-invocation: true` matters: publishing is a side effect you should always trigger explicitly. This one skill would have absorbed ~35 of your 186 messages.

### Automation #2: lint hooks for the code you actually write

SwiftLint is configured (`.swiftlint.yml`) but never runs automatically; Kotlin has nothing. Add to `.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          { "type": "command", "command": "f=\"$CLAUDE_FILE_PATHS\"; case \"$f\" in *.swift) swiftlint lint --quiet --path \"$f\" ;; esac", "timeout": 15 }
        ]
      }
    ]
  }
}
```

Lint feedback lands immediately in-session instead of surfacing later (or never).

### Automation #3: a `/cr-doctor` status skill

You asked "is the latest server running?" / "is everything published?" at least 6 times. A read-only skill that checks everything at once:

- Server: `claude-relay status` version vs `Formula/clauderelay.rb` vs latest git tag.
- Android: latest `android-v*` release tag + APK versionName vs `app/build.gradle.kts`.
- iOS: last archive's CFBundleVersion (build/ClaudeRelayApp.xcarchive/Info.plist) vs project.yml, plus the last ContentDelivery.log verdict.
- Output one table with ✅/⚠️ per platform.

Then "run /cr-doctor" replaces four follow-up questions. (An `asc`/App Store Connect API key would let it check TestFlight processing state too — you already use the `app-connect-cli` skill.)

### Automation #4: config hygiene

1. **Prune plugins** (biggest context win): keep `superpowers`, `commit-commands`, `code-review`, `pr-review-toolkit`, `swift-lsp`, `context7`, `claude-mem`, `claude-code-setup`; disable the rest — especially `everything-claude-code` (200+ skill descriptions injected per session) unless you use a specific piece of it, and the unused language LSPs (rust, typescript, pyright).
2. **Narrow the graph hook**: change matcher `Edit|Write|Bash` → `Edit|Write` in `.claude/settings.json` (project). Bash calls (1,326/month) don't change source files in ways worth reindexing on every grep/build; the SessionStart status hook already catches drift.
3. **Delete the four never-used `.claude/skills/*.md`** or fold anything valuable into CLAUDE.md (which already mandates graph-first exploration).
4. **Add a permission allowlist** so routine commands stop prompting — run `/fewer-permission-prompts`, or seed `.claude/settings.json` with your proven-safe recurring commands: `Bash(gh release:*)`, `Bash(./gradlew:*)`, `Bash(xcodebuild:*)`, `Bash(swift test:*)`, `Bash(adb:*)`, `Bash(plutil:*)`, `Bash(git status:*)`, `Bash(git log:*)`.

### Automation #5: put the release runbook in CLAUDE.md

Sessions repeatedly re-derived tribal knowledge that lives only in your head or old transcripts. Add a short "Release process" section to CLAUDE.md covering: the version-bump trio (project.yml build number / versionCode+versionName / formula), the m-milestone naming convention, the release-notes format, **"user installs APKs by downloading from GitHub Releases — the phone is not adb-connected"** (this was mis-assumed at least once), and the verification steps from Automation #1. CLAUDE.md is loaded every session; transcripts are not.

---

## Prompting playbook (drawn from your own history)

### What worked — keep doing these

| Your prompt (real) | Why it worked |
|---|---|
| "1. open the app… 2. create a new session, 3. start typing, all works. 4. …create a new session, 5. i cannot type…" | Numbered repro steps → root cause found in one pass |
| "i feel haptic feedback on the keyboard but in none of the app buttons" | A precise *differential* observation (X works, Y doesn't) is gold — it eliminated half the hypothesis space instantly |
| "1. review the attached image, 2. acknowledge the problem, 3. resolve the issue" | Forcing acknowledgment before action stops premature "fixed it" claims |
| "ultrathink /loop until you are sure you have a definitive answer" (fd-leak check) | Explicitly requesting depth + a completion criterion for a hard investigation |
| Screenshots on every visual bug | Always better than prose for UI issues |

### What cost you round-trips — and the upgraded version

**1. Bare release commands** → *"rebuild and upload the apk"* left "which tag? verify how?" implicit, producing the "still 2 days old" follow-ups.
**Upgrade:** "rebuild the APK with the fold fix, publish as android-v0.3-m22, and verify by downloading it back and checking versionCode" — or just `/cr-ship android` once the skill exists.

**2. Iterating visually through TestFlight** → ten "still not ok [image]" rounds.
**Upgrade:** full spec upfront + "verify locally and show me before shipping." If you can produce the asset yourself faster (as you eventually did), do it in round one.

**3. "continue" as a reflex** → after compaction, bare "continue" makes Claude re-infer priorities from a lossy summary.
**Upgrade:** one anchoring line: "continue — priority is merging PR #21; the APK upload can wait." Costs you 5 seconds, saves a wrong-priority detour.

**4. Reporting the same bug in new sessions** → the Fold bug, three times.
**Upgrade:** "file this as a GitHub issue with these repro steps" the first time; "check open issues" at session start.

**5. Vague acceptance for fixes** → *"fix"* worked fine for the haptics bug because diagnosis was already agreed — good instinct. But for fresh requests, one sentence of acceptance criteria ("done means: buttons buzz with system Touch feedback OFF") lets Claude self-verify instead of shipping and waiting for your device test.

### Habits worth adopting

- **Plan mode for multi-file features** (Shift+Tab): you used interactive clarification well on the tab-scroll feature; plan mode formalizes it — you approve the approach before any edits.
- **"remember this"** after any painful discovery (device quirks, Apple/Google gotchas). Your memory index already carries 8 hard-won lessons; the habit is what keeps it growing.
- **Ask for adversarial verification on risky changes**: "have a subagent try to refute that this fixes it" — you did this well with the swarm review request ("be diligent and adversarial… use swarm of agents").
- **Voice-typo tolerance is fine** — Claude parsed "puah the apk" and "kehbkard" without issue; don't waste time correcting typos unless a *number or identifier* is involved (those it can't guess: "expire 73", "push the o" both stalled).

---

## Quick-wins checklist

- [ ] Create the `/cr-ship` skill (Automation #1) — eliminates ~15% of your message volume
- [ ] Prune enabled plugins; disable `everything-claude-code` and unused LSPs
- [ ] Narrow the graph hook matcher to `Edit|Write`
- [ ] Add the release runbook + "phone installs via GitHub Releases" to CLAUDE.md
- [ ] `/fewer-permission-prompts` or seed the allowlist manually
- [ ] File the Huawei Fold bug as a GitHub issue (it's still unfixed after 3 reports)
- [ ] Add the SwiftLint PostToolUse hook
- [ ] Delete the 4 unused `.claude/skills/*.md`
- [ ] New habit: one task per session; anchor every "continue" with a one-line priority
- [ ] New habit: full spec + local verification before any visual-change ship
