# Server Prompt Optimizer — Plan 4 of 4: Linux Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the Linux client's half of the prompt-optimizer rollout: a `Ctrl+Shift+O` accelerator that triggers the shared magic-wand button, a keyring scrub that deletes the Bedrock API key older Linux builds stored, and the Linux docs brought in line.

**Architecture:** Plan 3 already put the wand on the Linux desktop for free — `CodeRelayLinux/` compiles the Android `feature-workspace` sources in place, so `WandButton` / `OptimizerOverlay` and the four optimizer StateFlows on `relay.session.SessionCoordinator` are live in the Linux window. What remains is Linux-only glue. (1) `AppShortcut` gains `OPTIMIZE_PROMPT` on `Ctrl+Shift+O`; `Main.kt`'s window-level `handleShortcut` dispatches it to `coordinator.optimizePrompt(shareScreen)` — the *same* entry point a wand tap uses, so `PromptOptimizerController` keeps owning the gate (idle, not recovering, an active session) and the unavailable-hint fast path, exactly as the macOS `.optimizePromptShortcut` calls `WandButton.trigger()`. (2) `linux-storage`'s `TokenStore` loses `saveBedrockToken` / `loadBedrockToken` and gains an idempotent `deleteBedrockToken()`; `AppEnvironment.create` runs it once per launch off the AWT thread, with no completion flag — the same rule Android's speech scrub follows. (3) `docs/linux-client-spec.md`, the Linux README, the root `CLAUDE.md` and one stale KDoc stop describing the accelerator and the scrub as pending.

**Tech Stack:** Kotlin, Gradle on JDK 21 (`/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home`), Compose Desktop, kotlinx-coroutines, JUnit 5. No shared (`CodeRelayAndroid/`) source is edited by this plan, so the Android build is untouched.

**Spec:** `docs/superpowers/specs/2026-09-13-server-prompt-optimizer-design.md` — §7.1 (shared client behaviour: the wand's gate and hint), §7.4 (Linux), §8 (removal inventory), §10 (privacy), §12 (rollout: "Linux. Settings, accelerator, TokenStore, docs. Small.").

**Branch:** `feat/prompt-optimizer-linux`, stacked on `feat/prompt-optimizer-android` (DRAFT PR #59, HEAD `434597f`), which is stacked on `feat/prompt-optimizer-apple-clients` (PR #58) → `rename/coderelay-layout` (PR #57) → `main`.

## Global Constraints

Every task's requirements implicitly include this section.

- **Spec §7.4 (Linux), verbatim scope:** "Accelerator `Ctrl+Shift+O` triggers the wand, dispatched at the Window"; "`linux-storage/TokenStore` loses `saveBedrockToken`/`loadBedrockToken` and their tests"; "`docs/linux-client-spec.md` §1.1 and §9 are updated: on-device speech is no longer deferred, it is out of scope by design, and the optimizer is a server feature." The `Main.kt` `visibleSections` and Linux `AppSettings` items in §7.4 shipped in Plan 3 — do not touch them.
- **Linux accelerator rule (hard constraint, `docs/linux-client-spec.md` §5.1):** every accelerator is `Ctrl+Shift+<key>` or `Ctrl+Alt+<key>`. A bare `Ctrl+<key>` is terminal input and must resolve to `null`. `KeyMapping.isApplicationShortcut` only forwards Ctrl **plus** Shift or Alt, so a bare-Ctrl binding could not be delivered anyway. The new chord is `Ctrl+Shift+O` and nothing else; `Ctrl+O` and `Ctrl+Alt+O` stay `null`.
- **The accelerator is a tap, not a second code path (spec §7.1):** it must call `SessionCoordinator.optimizePrompt(shareScreen)` and nothing lower. `PromptOptimizerController.optimizePrompt` already (a) returns when `isWandEnabled` is false — cancelled/torn-down coordinator, `OPTIMIZING`, recovering, no active session — and (b) shows `wandHint` (`OptimizerStrings.UPDATE_RELAY_HINT` / `CONFIG_HINT`) instead of an RPC when the wand is unavailable. Do not re-implement any of that in `Main.kt`; do not add a new parameter to the shared `WorkspaceScreen`.
- **`shareScreen` comes from the existing setting:** `Main.kt` already has `val shareScreen by settings.shareScreenWithOptimizer.collectAsState()`; the accelerator passes that value, the same one the `WorkspaceScreen` call site passes.
- **Bedrock scrub (spec §8, §10):** runs on every launch, idempotent, no completion flag (Android rule). It runs off the AWT/Compose thread — `secret-tool` can block up to 30 s (`KEYRING_TIMEOUT_SECONDS`) on a locked keyring. It never throws: a missing `secret-tool`, a non-zero exit or a timeout is swallowed and the next launch retries. `TokenStore.BEDROCK_ACCOUNT = "bedrock"` and `SERVICE_NAME = "com.coderemote.relay"` are unchanged — the scrub must address the exact attributes older builds wrote.
- **Secrets never on argv:** `secret-tool clear service <SERVICE_NAME> account bedrock` carries no secret. Nothing in this plan writes a secret anywhere.
- **No plaintext fallback, no new persistence** in `linux-storage`.
- **Privacy (spec §10):** no `println` / logging of drafts, prompts, screen text or secrets in any new code.
- **Both builds green:** this plan edits only `CodeRelayLinux/**`, `docs/**`, `CLAUDE.md`. The Linux local gate on macOS is the JVM module set (the full `./gradlew test` needs Linux for `:linux-terminal:buildNativeTerminal`). Every gate run uses `--rerun-tasks` and echoes `EXIT=${pipestatus[1]}`; a run is green only with `BUILD SUCCESSFUL` **and** `EXIT=0`.
- **Process:** `git add` explicit paths only (never `-A` / `.`); every commit ends with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; no version bumps anywhere.

### Linux local gate (used by both tasks)

```bash
cd /Users/miguelriotinto/Developer/CodeRelay/CodeRelayLinux
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
./gradlew --no-daemon --rerun-tasks -x :linux-terminal:buildNativeTerminal \
  :linux-storage:test :feature-settings:test :feature-servers:test :feature-workspace:test \
  :app:compileKotlin :app:compileTestKotlin :app:test 2>&1 | tail -15; echo EXIT=${pipestatus[1]}
```

Expected: `BUILD SUCCESSFUL` and `EXIT=0`. `:app:test` depends on `:linux-terminal:buildNativeTerminal`, which refuses to run on macOS; excluding it with `-x` lets the pure-JVM app tests (`AppShortcutsChordTest` and friends) run here — verified on 2026-09-16, 8/8 passing. CI's `linux.yml` runs the same tasks without the exclusion on Ubuntu.

---

## File Structure

| File | Task | Responsibility |
|---|---|---|
| `CodeRelayLinux/app/src/main/kotlin/relay/app/AppShortcuts.kt` | 1 | Pure chord → command resolver. Gains `OPTIMIZE_PROMPT` on `Key.O` in the Ctrl+Shift branch. |
| `CodeRelayLinux/app/src/test/kotlin/relay/app/AppShortcutsChordTest.kt` | 1 | Chord tests. Gains the `Ctrl+Shift+O` row and the two negative rows. |
| `CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt` | 1, 2 | Task 1: `handleShortcut` dispatches `OPTIMIZE_PROMPT` to the coordinator. Task 2: `AppEnvironment.create` launches the Bedrock scrub. |
| `CodeRelayLinux/linux-storage/src/main/kotlin/relay/storage/TokenStore.kt` | 2 | Loses `saveBedrockToken` / `loadBedrockToken`; gains `deleteBedrockToken(): Boolean`; `clear` reports success. |
| `CodeRelayLinux/linux-storage/src/test/kotlin/relay/storage/TokenStoreTest.kt` | 2 | Three Bedrock save/load tests removed; two scrub tests added. |
| `CodeRelayLinux/app/src/main/kotlin/relay/app/ConnectionSession.kt` | 2 | One stale KDoc sentence ("minus the speech engines"). |
| `docs/linux-client-spec.md` | 1, 2 | §5.1 shortcut table (Task 1); §1.1 non-goals + §4 seam table (Task 2). |
| `CodeRelayLinux/README.md` | 1, 2 | Keyboard bullet (Task 1); the two "Bedrock" mentions (Task 2). |
| `CLAUDE.md` (repo root) | 1 | One sentence in "Prompt Optimizer (client side)" naming the Linux chord. |

---

### Task 1: `Ctrl+Shift+O` triggers the wand

**Files:**
- Modify: `CodeRelayLinux/app/src/main/kotlin/relay/app/AppShortcuts.kt` (enum body ~lines 25-40; `resolve(key, ctrl, shift, alt)` Ctrl+Shift `when` ~lines 66-90)
- Modify: `CodeRelayLinux/app/src/test/kotlin/relay/app/AppShortcutsChordTest.kt`
- Modify: `CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt` (`fun handleShortcut`, ~lines 337-371)
- Modify: `docs/linux-client-spec.md` §5.1 table (~lines 194-201)
- Modify: `CodeRelayLinux/README.md` "Keyboard" bullet (~lines 180-183)
- Modify: `CLAUDE.md` (repo root) "Prompt Optimizer (client side)" paragraph, the sentence beginning "The Android and Linux clients share the same shape in Kotlin" (~line 264)

**Interfaces:**
- Consumes (existing, do not change): `relay.session.SessionCoordinator.optimizePrompt(shareScreen: Boolean)` (`suspend`); `ConnectionSession.scope: CoroutineScope` and `.coordinator: SessionCoordinator` (the `active` local in `handleShortcut`); `val shareScreen by settings.shareScreenWithOptimizer.collectAsState()` already declared earlier in the same composable (~line 198).
- Produces: `relay.app.AppShortcut.OPTIMIZE_PROMPT`, resolved from `AppShortcut.resolve(Key.O, ctrl = true, shift = true, alt = false)`.

- [x] **Step 1: Write the failing chord tests**

Append these three tests inside `class AppShortcutsChordTest` in `CodeRelayLinux/app/src/test/kotlin/relay/app/AppShortcutsChordTest.kt`, before the closing brace. Also widen the class KDoc from `/** The chords added for settings, zoom, copy and paste. */` to `/** The chords added for settings, zoom, copy, paste and the prompt-optimizer wand. */`.

```kotlin
    @Test
    fun `ctrl shift O triggers the prompt optimizer wand`() {
        assertEquals(AppShortcut.OPTIMIZE_PROMPT, ctrlShift(Key.O))
    }

    /**
     * Bare Ctrl+O is terminal input (nano's write-out, readline's operate-and-
     * get-next); it must never resolve to an app command. See the class doc on
     * [AppShortcut] for the rule.
     */
    @Test
    fun `bare ctrl O still belongs to the terminal`() {
        assertNull(AppShortcut.resolve(Key.O, ctrl = true, shift = false, alt = false))
    }

    /** Ctrl+Alt is the session-switching family; O is not bound there. */
    @Test
    fun `ctrl alt O is not a shortcut`() {
        assertNull(AppShortcut.resolve(Key.O, ctrl = true, shift = false, alt = true))
    }
```

- [x] **Step 2: Run the chord test to verify it fails**

```bash
cd /Users/miguelriotinto/Developer/CodeRelay/CodeRelayLinux
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
./gradlew --no-daemon -x :linux-terminal:buildNativeTerminal :app:test --tests 'relay.app.AppShortcutsChordTest' 2>&1 | tail -15; echo EXIT=${pipestatus[1]}
```

Expected: compilation FAILS with `Unresolved reference: OPTIMIZE_PROMPT` (EXIT non-zero).

- [x] **Step 3: Add the enum constant and the chord**

In `CodeRelayLinux/app/src/main/kotlin/relay/app/AppShortcuts.kt`, add the constant after `PASTE,` (keep the trailing `;` that closes the constant list):

```kotlin
    /** Ctrl+Shift+C / Ctrl+Shift+V: the terminal-world copy and paste chords. */
    COPY,
    PASTE,
    /**
     * Ctrl+Shift+O: the prompt-optimizer wand (spec §7.4). Shifted like every
     * other accelerator — bare Ctrl+O is nano's write-out and readline's
     * operate-and-get-next, so it belongs to the terminal.
     */
    OPTIMIZE_PROMPT,
    ;
```

In `resolve(key: Key, ctrl: Boolean, shift: Boolean, alt: Boolean)`, add one row to the Ctrl+Shift `when`, after the `Key.V -> PASTE` row and before `else -> null`:

```kotlin
                    Key.C -> COPY
                    Key.V -> PASTE
                    Key.O -> OPTIMIZE_PROMPT
                    else -> null
```

- [x] **Step 4: Run the chord test to verify it passes**

Same command as Step 2. Expected: `BUILD SUCCESSFUL`, `EXIT=0`, all `AppShortcutsChordTest` tests PASSED.

- [x] **Step 5: Dispatch the chord in `Main.kt`**

`handleShortcut`'s `when (shortcut)` is exhaustive over `AppShortcut`, so after Step 3 `:app:compileKotlin` fails until the new case exists. Add the case after the `PASTE` row:

```kotlin
            AppShortcut.COPY -> if (active?.coordinator?.activeSessionId?.value != null) copyRequest++ else return false
            AppShortcut.PASTE -> if (active?.coordinator?.activeSessionId?.value != null) pasteRequest++ else return false
            // The wand's accelerator (spec §7.4) — the same entry point as a tap
            // on the WandButton, on purpose. PromptOptimizerController owns the
            // gate (idle, not recovering, an active session, not torn down) and
            // shows the "update / enable the relay" hint itself when the wand is
            // unavailable, so the chord and the tap cannot drift apart. Mirrors
            // the macOS WandButton receiving `.optimizePromptShortcut`.
            AppShortcut.OPTIMIZE_PROMPT -> active?.let { s ->
                s.scope.launch { s.coordinator.optimizePrompt(shareScreen) }
            } ?: return false
```

`shareScreen` is the `val shareScreen by settings.shareScreenWithOptimizer.collectAsState()` already declared near line 198 of the same composable; do not add a second one. `launch` is already imported.

- [x] **Step 6: Update the three docs**

`docs/linux-client-spec.md` §5.1 — add one row at the end of the shortcut table (after the `| Toggle sidebar | ⌘0 | `Ctrl+Shift+B` |` row, or after the last row if later rows exist):

```markdown
| Optimize prompt (wand) | configurable `recordingShortcut*` chord | `Ctrl+Shift+O` |
```

`CodeRelayLinux/README.md` — in the **Keyboard** bullet, change

```
  1–9, sidebar, settings, zoom (Ctrl+Shift+= / - / 0), copy, paste. Handled at
```

to

```
  1–9, sidebar, settings, zoom (Ctrl+Shift+= / - / 0), copy, paste, optimize
  prompt (Ctrl+Shift+O, the wand). Handled at
```

`CLAUDE.md` (repo root), "Prompt Optimizer (client side)" — after the sentence ending "`shareScreenWithOptimizer` DataStore/preference key." insert:

```
On Linux the wand's accelerator is `Ctrl+Shift+O`, dispatched at the `Window`
like every other chord and routed to `SessionCoordinator.optimizePrompt` —
the same call a tap makes, so the controller's gate and hint apply unchanged.
```

- [x] **Step 7: Run the Linux local gate**

Run the **Linux local gate** command from Global Constraints. Expected: `BUILD SUCCESSFUL`, `EXIT=0`.

- [x] **Step 8: Commit**

```bash
cd /Users/miguelriotinto/Developer/CodeRelay
git add CodeRelayLinux/app/src/main/kotlin/relay/app/AppShortcuts.kt \
        CodeRelayLinux/app/src/test/kotlin/relay/app/AppShortcutsChordTest.kt \
        CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt \
        docs/linux-client-spec.md CodeRelayLinux/README.md CLAUDE.md
git commit -m "feat(linux): Ctrl+Shift+O triggers the prompt-optimizer wand

Adds AppShortcut.OPTIMIZE_PROMPT on the Ctrl+Shift+O chord and dispatches it
from the window-level handleShortcut to SessionCoordinator.optimizePrompt —
the same entry point as a wand tap, so PromptOptimizerController keeps
owning the gate and the unavailable hint. Bare Ctrl+O and Ctrl+Alt+O stay
terminal input. Spec §7.4.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Linux `TokenStore` Bedrock scrub

**Files:**
- Modify: `CodeRelayLinux/linux-storage/src/main/kotlin/relay/storage/TokenStore.kt`
- Modify: `CodeRelayLinux/linux-storage/src/test/kotlin/relay/storage/TokenStoreTest.kt`
- Modify: `CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt` (`AppEnvironment.companion.create`, ~lines 773-795)
- Modify: `CodeRelayLinux/app/src/main/kotlin/relay/app/ConnectionSession.kt` (KDoc ~lines 32-36)
- Modify: `docs/linux-client-spec.md` §1.1 (~lines 22-28) and the §4 seam table row for `TokenStore` (~line 167)
- Modify: `CodeRelayLinux/README.md` (~line 56 dependency table; ~line 109 secrets paragraph)

**Interfaces:**
- Consumes: `TokenStore.CommandRunner` / `CommandResult` (existing seam); `TokenStore.SERVICE_NAME`, `TokenStore.BEDROCK_ACCOUNT` (existing constants, unchanged); `AppEnvironment.create`'s `scope` (`SupervisorJob() + Dispatchers.Default`) and `tokens` (already constructed there).
- Produces: `fun TokenStore.deleteBedrockToken(): Boolean` — true when `secret-tool clear` exited 0 (removed, or nothing to remove), false on non-zero exit / exception; never throws. `saveBedrockToken` and `loadBedrockToken` no longer exist.

- [x] **Step 1: Rewrite the Bedrock tests**

In `CodeRelayLinux/linux-storage/src/test/kotlin/relay/storage/TokenStoreTest.kt`:

Delete these three tests entirely (they call methods that are going away): `` `bedrock secret also stays out of argv` ``, `` `bedrock uses its own reserved account` ``, `` `saving an empty bedrock token clears it instead of storing empty` ``.

Keep `` `bedrock account is not a valid uuid` `` (its rationale — the scrub's `clear` must not be able to hit a connection token — still holds).

Add these tests right after `` `bedrock account is not a valid uuid` ``:

```kotlin
    /**
     * Builds before 2026-09 stored the AWS Bedrock key for the on-device prompt
     * enhancer under the reserved account. The optimizer is a relay feature now,
     * so the launch-time scrub must address exactly the attributes those builds
     * wrote — same service, literal `bedrock` account — and nothing else.
     */
    @Test
    fun `deleteBedrockToken clears the reserved account and nothing else`() {
        val runner = FakeRunner()
        val removed = TokenStore(runner).deleteBedrockToken()

        val call = runner.invocations.single()
        assertEquals(
            listOf("secret-tool", "clear", "service", TokenStore.SERVICE_NAME, "account", TokenStore.BEDROCK_ACCOUNT),
            call.command,
        )
        assertNull(call.stdin)
        assertTrue(removed)
    }

    /** No keyring, no secret-tool: the scrub is a no-op that the next launch retries. */
    @Test
    fun `deleteBedrockToken does not throw when secret-tool is missing`() {
        val runner = FakeRunner(throwOnRun = true)
        assertFalse(TokenStore(runner).deleteBedrockToken())
    }

    /** `secret-tool clear` exits 0 on a miss; a non-zero exit is a locked or broken keyring. */
    @Test
    fun `deleteBedrockToken reports a keyring failure as false`() {
        val runner = FakeRunner(exitCode = 1, stderr = "The name org.freedesktop.secrets was not provided")
        assertFalse(TokenStore(runner).deleteBedrockToken())
    }
```

Make sure `assertFalse` and `assertNull` are imported: the file's existing imports are `org.junit.jupiter.api.Assertions.*` singles — add `import org.junit.jupiter.api.Assertions.assertFalse` and `import org.junit.jupiter.api.Assertions.assertNull` if absent (keep the import list sorted).

- [x] **Step 2: Run the storage tests to verify they fail**

```bash
cd /Users/miguelriotinto/Developer/CodeRelay/CodeRelayLinux
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
./gradlew --no-daemon :linux-storage:test 2>&1 | tail -15; echo EXIT=${pipestatus[1]}
```

Expected: compilation FAILS with `Unresolved reference: deleteBedrockToken` (EXIT non-zero).

- [x] **Step 3: Replace save/load with the scrub in `TokenStore.kt`**

Replace the class KDoc's first paragraph and API sentence:

```kotlin
/**
 * Stores relay bearer tokens in the desktop keyring.
 *
 * Linux counterpart of the Android `TokenStore`, which uses
 * `EncryptedSharedPreferences`. The public API is identical — `saveToken` /
 * `loadToken` / `deleteToken` / `deleteBedrockToken` — so shared call sites
 * compile against either.
```

and the last KDoc paragraph:

```kotlin
 * Attribute schema matches Android's key layout so the two are conceptually the
 * same store: `service` is constant and `account` is the connection UUID. The
 * literal `bedrock` account is only ever *cleared* now — see [deleteBedrockToken].
 */
```

Delete `saveBedrockToken` and `loadBedrockToken` (both, with their KDoc). In their place:

```kotlin
    /**
     * Deletes the AWS Bedrock API key that builds before 2026-09 stored for the
     * on-device prompt enhancer. The optimizer is a relay feature now, so the
     * key has no reader; `AppEnvironment` calls this on every launch, off the
     * AWT thread, with no completion flag — `secret-tool clear` exits 0 on a
     * miss, so the steady state is one cheap no-op per launch.
     *
     * Never throws. Returns true when the keyring confirmed the entry is gone
     * (removed or absent) and false when it could not be reached, so a locked
     * keyring simply retries next launch.
     */
    fun deleteBedrockToken(): Boolean = clear(account = BEDROCK_ACCOUNT)
```

Change `clear` to report success (its only other caller, `deleteToken`, keeps ignoring the result):

```kotlin
    /** True when `secret-tool clear` exited 0 — which it does on a miss too. */
    private fun clear(account: String): Boolean =
        runCatching {
            runner.run(listOf(SECRET_TOOL, "clear", "service", SERVICE_NAME, "account", account), null).exitCode == 0
        }.getOrDefault(false)
```

Update the `BEDROCK_ACCOUNT` constant's KDoc:

```kotlin
        /** Account attribute older builds used for the Bedrock key; every other account is a connection UUID. */
        const val BEDROCK_ACCOUNT = "bedrock"
```

- [x] **Step 4: Run the storage tests to verify they pass**

Same command as Step 2. Expected: `BUILD SUCCESSFUL`, `EXIT=0`.

- [x] **Step 5: Run the scrub at launch**

In `CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt`, `AppEnvironment.companion.create`, directly after `val tokens = TokenStore()`:

```kotlin
            val tokens = TokenStore()
            // Builds before 2026-09 kept an AWS Bedrock key for the on-device
            // prompt enhancer under TokenStore.BEDROCK_ACCOUNT. The optimizer is
            // a relay feature now, so the secret is deleted on every launch —
            // idempotent, no completion flag, the same rule as Android's speech
            // scrub. Dispatchers.IO because secret-tool can block up to 30 s on
            // a locked keyring, and Default's pool is the coordinators' too.
            scope.launch(Dispatchers.IO) { tokens.deleteBedrockToken() }
```

`kotlinx.coroutines.launch` and `Dispatchers` are already imported in `Main.kt`.

- [x] **Step 6: Fix the stale KDoc and the docs**

`CodeRelayLinux/app/src/main/kotlin/relay/app/ConnectionSession.kt` — replace

```
 * Linux counterpart of the Android `ConnectionSession`, minus the speech
 * engines (out of parity scope). The two obligations the lower layers leave as
 * injected seams are satisfied here exactly as on Android:
```

with

```
 * Linux counterpart of the Android `ConnectionSession`. The two obligations the
 * lower layers leave as injected seams are satisfied here exactly as on Android:
```

`docs/linux-client-spec.md` §1.1 — replace the two bullets

```
- **On-device speech.** None. The Android speech stack was removed in 2026-09 in
  favour of the relay-side prompt optimizer (the wand in the shared
  `WorkspaceScreen`), so there is nothing to inherit. Voice input is the desktop's
  own dictation into the terminal.
- **Optimizer accelerator + Bedrock keyring scrub.** Deferred to Plan 4: the desktop
  has no Ctrl+Shift+O binding for the wand yet, and `TokenStore` still carries the
  now-unused Bedrock account.
```

with

```
- **On-device speech.** None, by design — not a deferral. The Android speech stack
  was removed in 2026-09 in favour of the relay-side prompt optimizer (the wand in
  the shared `WorkspaceScreen`, `Ctrl+Shift+O` on the desktop), so there is nothing
  to inherit. The optimizer is a server feature; the client only sends
  `optimize_prompt` / `replace_prompt`. Voice input is the desktop's own dictation
  into the terminal. The Bedrock key older Linux builds kept in the keyring is
  deleted on every launch (§4, `TokenStore.deleteBedrockToken`).
```

`docs/linux-client-spec.md` §4 seam table, the `TokenStore(Context)` row — replace

```
The Bedrock half (`BEDROCK_ACCOUNT`) is dead code pending the Plan 4 scrub.
```

with

```
The `BEDROCK_ACCOUNT` entry older builds wrote is scrubbed on every launch (`deleteBedrockToken`, off the AWT thread, no flag).
```

`docs/linux-client-spec.md` §9 "Inherited deferrals" — verify it lists only camera QR scanning (it does today). Do **not** add speech to it; §1.1 now states speech is out of scope by design, which is what spec §7.4 asks for.

`CodeRelayLinux/README.md` — line ~56: `| `secret-tool` | `libsecret` | Relay + Bedrock tokens in the keyring |` → `| `secret-tool` | `libsecret` | Relay tokens in the keyring |`. Line ~109: `Relay tokens and the Bedrock key go to the Secret Service via `secret-tool`,` → `Relay tokens go to the Secret Service via `secret-tool`,` (keep the rest of the sentence).

- [x] **Step 7: Run the Linux local gate**

Run the **Linux local gate** command from Global Constraints. Expected: `BUILD SUCCESSFUL`, `EXIT=0`. Also confirm nothing else referenced the removed methods:

```bash
cd /Users/miguelriotinto/Developer/CodeRelay
grep -rn 'saveBedrockToken\|loadBedrockToken' CodeRelayLinux docs CLAUDE.md | grep -v 'docs/superpowers/' ; echo GREP_EXIT=$?
```

Expected: no matches (`GREP_EXIT=1`).

- [x] **Step 8: Commit**

```bash
cd /Users/miguelriotinto/Developer/CodeRelay
git add CodeRelayLinux/linux-storage/src/main/kotlin/relay/storage/TokenStore.kt \
        CodeRelayLinux/linux-storage/src/test/kotlin/relay/storage/TokenStoreTest.kt \
        CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt \
        CodeRelayLinux/app/src/main/kotlin/relay/app/ConnectionSession.kt \
        docs/linux-client-spec.md CodeRelayLinux/README.md
git commit -m "feat(linux): scrub the Bedrock keyring entry at launch; drop the Bedrock save/load API

TokenStore loses saveBedrockToken/loadBedrockToken (no reader since Plan 3)
and gains an idempotent, non-throwing deleteBedrockToken(); AppEnvironment
runs it on every launch on Dispatchers.IO with no completion flag, the same
rule as Android's speech scrub. Linux spec §1.1/§4, README and a stale KDoc
no longer describe the accelerator or the scrub as pending. Spec §7.4, §8.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage (§7.4):** accelerator → Task 1; `TokenStore` loses save/load and their tests → Task 2; `docs/linux-client-spec.md` §1.1 / §9 wording → Task 2 Step 6; `visibleSections` and Linux `AppSettings` → already shipped in Plan 3 (Global Constraints says leave them). §8 removal inventory: the Bedrock keyring item is the only Linux row left → Task 2. §10 privacy: no logging added. §12 "Linux. Settings, accelerator, TokenStore, docs." → settings done in Plan 3; the other three are Tasks 1–2.
- **Placeholders:** none; every code step carries the code.
- **Type consistency:** `AppShortcut.OPTIMIZE_PROMPT` (Task 1 Steps 1, 3, 5); `TokenStore.deleteBedrockToken(): Boolean` (Task 2 Steps 1, 3, 5); `clear(account): Boolean` (Step 3) is private and its other caller `deleteToken` discards the result unchanged. `FakeRunner(exitCode, stdout, stderr, throwOnRun)` matches the existing fixture's parameters.
