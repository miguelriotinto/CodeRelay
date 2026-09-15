# Server Prompt Optimizer — Plan 3 of 4: Android Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the on-device speech stack from the Android client and put the server-side prompt optimizer behind one magic-wand button (with a 10 s Undo) in the shared Kotlin `WorkspaceScreen`, so Android — and, because the screens are shared, the Linux client — gains the wand in the mic's old slot.

**Architecture:** The Kotlin port mirrors the Swift shape shipped in Plan 2. `core-net`'s `SessionController` learns the two new RPCs (`optimize_prompt` / `replace_prompt`, 20 s waiter), keeps the server's `protocolVersion` and `capabilities` from `auth_success`, and moves `ProtocolVersions.CURRENT` to 2. A new `PromptOptimizerController` in `core-session` (the same collaborator pattern as `RecoveryController` / `ActivityCoordinator`) owns the wand state machine — availability, `IDLE`/`OPTIMIZING`, the 10 s one-shot Undo, the 4 s notice — and `SessionCoordinator` delegates to it. `feature-workspace` replaces `MicButton.kt` with `WandButton.kt`, rendered inside the shared `WorkspaceScreen` from coordinator state (the `micButton` slot parameter goes away). `feature-settings` drops the speech/Bedrock keys, adds `shareScreenWithOptimizer`, scrubs the old keys and the encrypted Bedrock token on every launch (idempotent, no flag), and puts the single toggle in its own **Prompt Optimizer** section. `:app` loses `SpeechSession`, the foreground service, the permission plumbing, `RECORD_AUDIO`, and the `:speech` module is deleted along with `ml/` and the ONNX toolchain.

**Tech Stack:** Kotlin, Gradle (JDK 17), Jetpack Compose / Material 3, Preferences DataStore, EncryptedSharedPreferences (`TokenStore`), kotlinx-coroutines (+ `kotlinx-coroutines-test`), JUnit 5. The Linux client (`CodeRelayLinux/`, Compose Desktop on JDK 21) compiles the same Kotlin sources in place, so every shared-screen change must keep both builds green.

**Spec:** `docs/superpowers/specs/2026-09-13-server-prompt-optimizer-design.md` — §6 (protocol), §7.1 (shared client behaviour), §7.3 (Android), §7.4 (Linux, for the compile-compatibility items only), §8 (removal inventory), §9 (error table), §10 (privacy), §12 (rollout).

**Branch:** `feat/prompt-optimizer-android`, stacked on `feat/prompt-optimizer-apple-clients` (PR #58), which is itself stacked on PR #57 (`rename/coderelay-layout`). The Kotlin protocol types this plan consumes (`ClientMessage.OptimizePrompt` / `ReplacePrompt`, `ServerMessage.OptimizePromptResult` / `ReplacePromptResult`, `AuthSuccess.capabilities`) already exist in `core-protocol` from Plan 1.

## Global Constraints

Every task's requirements implicitly include this section.

- **Wire (Plan 1, already in `core-protocol`):** `ClientMessage.OptimizePrompt(sessionId: UUID, shareScreen: Boolean)` → `"optimize_prompt"`; `ClientMessage.ReplacePrompt(sessionId: UUID, text: String)` → `"replace_prompt"`; `ServerMessage.OptimizePromptResult(status: String, original: String?, prompt: String?, message: String?)` → `"optimize_prompt_result"` with `status` ∈ `ok | passthrough | no_draft | failed | unconfigured`; `ServerMessage.ReplacePromptResult(status: String, message: String?)` → `"replace_prompt_result"`; `ServerMessage.AuthSuccess(protocolVersion: Int?, tokenId: String?, capabilities: List<String>?)`. The server advertises `capabilities = ["prompt_optimizer"]` only when the optimizer is enabled **and** its key was readable at startup.
- **Gating (spec §7.1, §9):** the wand is *available* only when `serverProtocolVersion >= 2` **and** `serverCapabilities` contains `"prompt_optimizer"`. Older server → `SERVER_TOO_OLD` (hint `OptimizerStrings.UPDATE_RELAY_HINT`); v2 without the capability → `UNCONFIGURED` (hint `OptimizerStrings.CONFIG_HINT`). The minimum is the literal `2`, **not** `ProtocolVersions.CURRENT` — the gate must not move when the client's own version does.
- **Enabled vs available:** the button is *disabled* (not tappable) only while `optimizerState == OPTIMIZING`, while `isRecovering` is true, or when there is no active session. When available is false but enabled is true, the wand is dimmed and a tap shows the hint toast.
- **Timing:** `optimize_prompt` and `replace_prompt` use a 20 s waiter (`SessionController.OPTIMIZER_TIMEOUT_MS = 20_000L`); every other RPC keeps `RESPONSE_TIMEOUT_MS = 10_000L`. Undo window 10 s (`PromptOptimizerController.UNDO_WINDOW_MS = 10_000L`). Notice toast 4 s (`NOTICE_WINDOW_MS = 4_000L`).
- **Undo survives failure:** the armed undo is cleared only on a *successful* `replace_prompt` (or expiry, or a fresh successful optimize replacing it). A failed optimize or a failed undo keeps the existing undo so the user can retry. (This is the PR #58 review finding A1-#1; the Kotlin port ships the fixed behaviour from the start.)
- **Copy is byte-exact and defined once**, in `OptimizerStrings` (Task 1). Never retype a string at a call site.

  | Constant | Value |
  |---|---|
  | `CONFIG_HINT` | `Enable on the relay: claude-relay config set promptOptimizerEnabled true` |
  | `UPDATE_RELAY_HINT` | `Update the relay to use the prompt optimizer` |
  | `NO_DRAFT` | `Type or dictate a prompt first` |
  | `PASSTHROUGH` | `Nothing to optimize` |
  | `COULD_NOT_REWRITE` | `Optimizer could not rewrite this prompt` |
  | `OPTIMIZED` | `Optimized` |
  | `UNDO` | `Undo` |
  | `WAND_LABEL` | `Optimize Prompt` |
  | `SHARE_SCREEN_TOGGLE` | `Share terminal screen with the optimizer` |
  | `SHARE_SCREEN_FOOTER` | `With this on, the relay also sends the last 40 lines of the terminal screen to the optimizer model. The draft and its working directory are always sent.` |

- **A `failed` reply's `message` is shown verbatim** when non-empty; an absent *or empty* message falls back to `COULD_NOT_REWRITE`. Transport errors (`SessionException` from timeout / desync / not connected) show the exception's message when non-empty, else `COULD_NOT_REWRITE`.
- **Privacy (spec §10):** never log the draft, the optimized prompt, the original, or screen text. No `Log.*` / `println` of any RPC payload in the new code.
- **Setting:** exactly one, `shareScreenWithOptimizer` (`booleanPreferencesKey("shareScreenWithOptimizer")`, default `true`), stored per device and sent as `shareScreen` on every `optimize_prompt`. Nothing else.
- **Versions:** do **not** touch `versionCode 49` / `versionName "0.3-m50"` in `CodeRelayAndroid/app/build.gradle.kts` (the release skill owns them).
- **Linux parity:** `CodeRelayLinux/` compiles `core-protocol`, `core-net`, `core-session`, `terminal`, `feature-*` from `CodeRelayAndroid/` via `srcDirs` with per-file exclusion lists in each `CodeRelayLinux/<module>/build.gradle.kts`. A shared file may only use APIs that exist on both sides (`rememberHaptics` does: `CodeRelayLinux/feature-workspace/.../Haptics.kt` is a no-op twin). Files that must stay Android-only go in the exclusion lists. `CodeRelayLinux/feature-settings/AppSettings.kt` is Linux's *own* `AppSettings` (the Android one is excluded), so any new property the shared `SettingsScreen` reads must be added there too. Task 4 rewrites Linux's `AppSettings` alongside Android's (dropping the speech keys there too); the Linux `TokenStore` Bedrock scrub and a `Ctrl+Shift+O` accelerator are Plan 4. Otherwise this plan only keeps Linux compiling and gives it the wand for free.
- **Git:** commit after every task with an explicit path list (`git add <paths>` — never `git add -A` / `git add .`; never `git stash` / `git checkout --`). End every commit message with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Deleting files: `git rm -r <path>` (explicit), never `git clean`.
- **Verification commands** (run from `CodeRelayAndroid/` with `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`): per-module `./gradlew :<module>:testDebugUnitTest` for Android library modules, `./gradlew :core-protocol:test :core-net:test :core-session:test` for the pure-JVM ones, and the CI trio `./gradlew test testDebugUnitTest :core-storage:compileDebugAndroidTestKotlin assembleDebug :app:assembleRelease` at the end. Linux: `cd CodeRelayLinux && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew test`. Always check the exit code, not just the tail of the log (zsh: `... 2>&1 | tail -20; echo EXIT=${pipestatus[1]}` — `$?` after a pipe is `tail`'s status, not Gradle's; require `EXIT=0` and `BUILD SUCCESSFUL`).
- **Device:** the Android phone is **not** adb-connected to this machine. Do not attempt `adb install`; the user installs the APK from a GitHub Release. Manual device verification is a documented follow-up, not a task step.

---

## File Map

| Path | Task | Change |
|---|---|---|
| `CodeRelayAndroid/core-net/src/main/kotlin/relay/net/PromptOptimizer.kt` | 1 | **Create** — `OptimizeOutcome`, `ReplaceOutcome`, `OptimizerStrings`, `PromptOptimizerProtocol` |
| `CodeRelayAndroid/core-net/src/main/kotlin/relay/net/SessionController.kt` | 1 | `CURRENT = 2`; `serverProtocolVersion` / `serverCapabilities`; timeout parameter; `optimizePrompt` / `replacePrompt`; `OPTIMIZER_TIMEOUT_MS` |
| `CodeRelayAndroid/core-net/src/test/kotlin/relay/net/SessionControllerTest.kt` | 1 | `FakeConnection` becomes `internal` |
| `CodeRelayAndroid/core-net/src/test/kotlin/relay/net/SessionControllerOptimizerTest.kt` | 1 | **Create** |
| `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/PromptOptimizerController.kt` | 2 | **Create** — wand state machine |
| `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/PromptOptimizerControllerTest.kt` | 2 | **Create** |
| `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/SessionCoordinator.kt` | 2 | Construct + expose the controller; refresh availability after auth; cancel on `tearDown` |
| `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/SessionCoordinatorTest.kt` | 2 | One test: availability derived after `connect()` |
| `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WandButton.kt` | 3 | **Create** — `WandButtonLogic` (pure), `WandButton`, `OptimizerOverlay` |
| `CodeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/WandButtonLogicTest.kt` | 3 | **Create** |
| `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/MicButton.kt` | 3 | **Delete** |
| `CodeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/MicButtonStateTest.kt` | 3 | **Delete** |
| `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WorkspaceScreen.kt` | 3 | Drop `micButton` param; add `shareScreen`; render `OptimizerOverlay` in the floating slot |
| `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WorkspaceViewModel.kt` | 3 | Remove `sendInput(text: String)` |
| `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/WorkspaceLogic.kt` | 3 | Remove `utteranceInputBytes` |
| `CodeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/ui/WorkspaceLogicTest.kt` | 3 | Remove the utterance tests |
| `CodeRelayAndroid/feature-workspace/build.gradle.kts` | 3 | Drop `implementation(project(":speech"))` |
| `CodeRelayLinux/feature-workspace/build.gradle.kts` | 3 | Drop the `MicButton.kt` / `MicButtonStateTest.kt` exclusions + comment |
| `CodeRelayAndroid/core-storage/src/main/kotlin/relay/storage/TokenStore.kt` | 4 | `saveBedrockToken` / `loadBedrockToken` → `deleteBedrockToken()` |
| `CodeRelayAndroid/core-storage/src/androidTest/kotlin/relay/storage/TokenStoreTest.kt` | 4 | Replace `bedrockEmptyDeletes` |
| `CodeRelayAndroid/feature-settings/src/main/kotlin/relay/feature/settings/AppSettings.kt` | 4 | Drop speech/Bedrock; add `shareScreenWithOptimizer`; `removeSpeechSettings()` migration |
| `CodeRelayAndroid/feature-settings/src/main/kotlin/relay/feature/settings/AppSettingsMigrations.kt` | 4 | Drop Bedrock decision types; add `REMOVED_SPEECH_KEYS` + `scrubSpeechKeys(MutablePreferences)` |
| `CodeRelayAndroid/feature-settings/src/test/kotlin/relay/feature/settings/AppSettingsMigrationsTest.kt` | 4 | Drop Bedrock tests; add removed-keys tests |
| `CodeRelayAndroid/feature-settings/src/test/kotlin/relay/feature/settings/BedrockDebounceFlowTest.kt` | 4 | **Delete** |
| `CodeRelayAndroid/feature-settings/src/main/kotlin/relay/feature/settings/SettingsScreen.kt` | 4 | Drop `SPEECH` + Bedrock UI; new `PROMPT_OPTIMIZER` section with the toggle; rename shortcut copy |
| `CodeRelayAndroid/feature-settings/build.gradle.kts` | 4 | Drop `api(project(":speech"))`; add `implementation(project(":core-net"))` |
| `CodeRelayLinux/feature-settings/src/main/kotlin/relay/feature/settings/AppSettings.kt` | 4 | **Rewrite** — drop speech/Bedrock + `tokenStore` param; add `shareScreenWithOptimizer` |
| `CodeRelayLinux/feature-settings/build.gradle.kts` | 4 | Add `implementation(project(":shared-net"))` |
| `CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt` | 4 | Drop `tokenStore =` from `AppSettings(...)`; add `SettingsSection.PROMPT_OPTIMIZER` to `visibleSections` |
| `CodeRelayAndroid/app/src/main/kotlin/relay/app/{SpeechSession,ContinuousListeningService,SpeechPermissions}.kt` | 5 | **Delete** |
| `CodeRelayAndroid/app/src/main/kotlin/relay/app/{CoordinatorFactory,MainActivity,RelayNavGraph,ConnectionViewModel}.kt` | 5 | Remove speech wiring; pass `shareScreen` |
| `CodeRelayAndroid/app/src/main/AndroidManifest.xml` | 5 | Drop mic permissions, foreground service, `<service>` |
| `CodeRelayAndroid/app/build.gradle.kts`, `app/proguard-rules.pro` | 5 | Drop `:speech` dep, ONNX rules/comments |
| `CodeRelayAndroid/speech/`, `CodeRelayAndroid/ml/`, `tools/speech/` | 6 | **Delete** |
| `CodeRelayAndroid/settings.gradle.kts`, `gradle/libs.versions.toml` | 6 | Drop `:speech`, ONNX entries |
| `CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt` | 7 | Pass `shareScreen` from Linux settings |
| `CodeRelayAndroid/RELEASE.md`, `docs/android-parity-audit.md`, `docs/linux-client-spec.md`, `README.md`, `CLAUDE.md` | 7 | Docs |

---

### Task 1: `core-net` — optimizer RPCs, capability fields, protocol v2

**Files:**
- Create: `CodeRelayAndroid/core-net/src/main/kotlin/relay/net/PromptOptimizer.kt`
- Modify: `CodeRelayAndroid/core-net/src/main/kotlin/relay/net/SessionController.kt` (`ProtocolVersions` at :18-20, fields at :58-110, `authenticate` at :176-224, `resetAuth` at :165-168, `sendAndWaitForResponse`/`awaitResponse` at :383-395, companion at :460)
- Modify: `CodeRelayAndroid/core-net/src/test/kotlin/relay/net/SessionControllerTest.kt:42` (`private class FakeConnection` → `internal class FakeConnection`)
- Test: `CodeRelayAndroid/core-net/src/test/kotlin/relay/net/SessionControllerOptimizerTest.kt` (create)

**Interfaces:**
- Consumes: `ClientMessage.OptimizePrompt`, `ClientMessage.ReplacePrompt`, `ServerMessage.OptimizePromptResult`, `ServerMessage.ReplacePromptResult`, `ServerMessage.AuthSuccess.capabilities` (all in `core-protocol`).
- Produces (Task 2 relies on these exact names):
  - `sealed interface OptimizeOutcome { data class Ok(val original: String?); object NoDraft; object Passthrough; object Unconfigured; data class Failed(val message: String) }`
  - `sealed interface ReplaceOutcome { object Ok; data class Failed(val message: String) }`
  - `object OptimizerStrings` (ten constants, Global Constraints table)
  - `object PromptOptimizerProtocol { const val MIN_PROTOCOL_VERSION = 2; const val CAPABILITY = "prompt_optimizer" }`
  - `SessionController.serverProtocolVersion: Int` (0 until `auth_success`; reset by `resetAuth()`), `SessionController.serverCapabilities: Set<String>` (empty until `auth_success`; reset by `resetAuth()`)
  - `suspend fun SessionController.optimizePrompt(sessionId: UUID, shareScreen: Boolean): OptimizeOutcome`
  - `suspend fun SessionController.replacePrompt(sessionId: UUID, text: String): ReplaceOutcome`
  - `SessionController.OPTIMIZER_TIMEOUT_MS = 20_000L`

- [ ] **Step 1: Create the outcome types and copy**

Write `CodeRelayAndroid/core-net/src/main/kotlin/relay/net/PromptOptimizer.kt`:

```kotlin
package relay.net

/**
 * Result of an `optimize_prompt` RPC, ported from `PromptOptimizer.swift`.
 * Unknown statuses from a newer relay collapse into [Failed] so they can never
 * crash an older client.
 */
sealed interface OptimizeOutcome {
    /**
     * The server rewrote the draft in place. [original] is what was on the
     * input line before; null only against a relay that omits it, in which
     * case Undo cannot be offered.
     */
    data class Ok(val original: String?) : OptimizeOutcome
    data object NoDraft : OptimizeOutcome
    data object Passthrough : OptimizeOutcome
    data object Unconfigured : OptimizeOutcome
    /** [message] is the server's text, or [OptimizerStrings.COULD_NOT_REWRITE] when it sent none. */
    data class Failed(val message: String) : OptimizeOutcome
}

/** Result of a `replace_prompt` (Undo) RPC. */
sealed interface ReplaceOutcome {
    data object Ok : ReplaceOutcome
    data class Failed(val message: String) : ReplaceOutcome
}

/**
 * Every user-facing optimizer string, byte-exact with `OptimizerStrings` in
 * `Sources/CodeRelayClient/PromptOptimizer.swift` (spec §7.1, §9, §10). Defined
 * once; call sites must reference these, never retype them.
 */
object OptimizerStrings {
    const val CONFIG_HINT = "Enable on the relay: claude-relay config set promptOptimizerEnabled true"
    const val UPDATE_RELAY_HINT = "Update the relay to use the prompt optimizer"
    const val NO_DRAFT = "Type or dictate a prompt first"
    const val PASSTHROUGH = "Nothing to optimize"
    const val COULD_NOT_REWRITE = "Optimizer could not rewrite this prompt"
    const val OPTIMIZED = "Optimized"
    const val UNDO = "Undo"
    const val WAND_LABEL = "Optimize Prompt"
    const val SHARE_SCREEN_TOGGLE = "Share terminal screen with the optimizer"
    const val SHARE_SCREEN_FOOTER =
        "With this on, the relay also sends the last 40 lines of the terminal screen to the optimizer model. " +
            "The draft and its working directory are always sent."
}

/** Wire-level facts the wand's availability gate is derived from (spec §6, §7.1). */
object PromptOptimizerProtocol {
    /**
     * The first protocol version whose `auth_success` carries `capabilities`.
     * Deliberately a literal and NOT [ProtocolVersions.CURRENT]: the gate must
     * not move when the client's own version does.
     */
    const val MIN_PROTOCOL_VERSION = 2

    /** The capability string the relay advertises when the optimizer is usable. */
    const val CAPABILITY = "prompt_optimizer"
}
```

- [ ] **Step 2: Make the test double reusable**

In `CodeRelayAndroid/core-net/src/test/kotlin/relay/net/SessionControllerTest.kt` line 42 change `private class FakeConnection(` to `internal class FakeConnection(`. Nothing else in that file changes.

- [ ] **Step 3: Write the failing tests**

Create `CodeRelayAndroid/core-net/src/test/kotlin/relay/net/SessionControllerOptimizerTest.kt`:

```kotlin
package relay.net

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ClientMessage
import relay.protocol.ServerMessage
import java.util.UUID

/**
 * The optimizer half of [SessionController]: capability capture from
 * `auth_success`, the two new RPCs, their status → outcome mapping, and the
 * 20 s waiter that only they use (spec §6, §7.1, §9).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionControllerOptimizerTest {

    private val sessionId: UUID = UUID.fromString("00000000-0000-0000-0000-00000000c0de")

    // MARK: - Protocol version + capabilities

    @Test
    fun `client advertises protocol version 2`() {
        assertEquals(2, ProtocolVersions.CURRENT)
        assertEquals(0, ProtocolVersions.MIN)
    }

    @Test
    fun `optimizer gate is a literal 2 not the client version`() {
        assertEquals(2, PromptOptimizerProtocol.MIN_PROTOCOL_VERSION)
        assertEquals("prompt_optimizer", PromptOptimizerProtocol.CAPABILITY)
    }

    @Test
    fun `auth success stores the server version and capabilities`() = runTest {
        val conn = FakeConnection(autoRespond = {
            ServerMessage.AuthSuccess(protocolVersion = 2, tokenId = "t", capabilities = listOf("prompt_optimizer"))
        })
        val controller = SessionController(conn)
        assertEquals(0, controller.serverProtocolVersion)
        assertEquals(emptySet<String>(), controller.serverCapabilities)

        controller.authenticate("tok")

        assertEquals(2, controller.serverProtocolVersion)
        assertEquals(setOf("prompt_optimizer"), controller.serverCapabilities)
    }

    @Test
    fun `auth success without capabilities yields an empty set`() = runTest {
        val conn = FakeConnection(autoRespond = { ServerMessage.AuthSuccess(protocolVersion = 1) })
        val controller = SessionController(conn)
        controller.authenticate("tok")
        assertEquals(1, controller.serverProtocolVersion)
        assertEquals(emptySet<String>(), controller.serverCapabilities)
    }

    @Test
    fun `resetAuth clears the server version and capabilities`() = runTest {
        val conn = FakeConnection(autoRespond = {
            ServerMessage.AuthSuccess(protocolVersion = 2, capabilities = listOf("prompt_optimizer"))
        })
        val controller = SessionController(conn)
        controller.authenticate("tok")
        controller.resetAuth()
        assertEquals(0, controller.serverProtocolVersion)
        assertEquals(emptySet<String>(), controller.serverCapabilities)
    }

    // MARK: - optimize_prompt

    @Test
    fun `optimizePrompt sends the session id and shareScreen flag`() = runTest {
        val conn = FakeConnection(autoRespond = {
            ServerMessage.OptimizePromptResult(status = "ok", original = "fix bug", prompt = "Fix the bug")
        })
        val controller = SessionController(conn)

        controller.optimizePrompt(sessionId, shareScreen = false)

        val sent = conn.sentMessages.single()
        assertTrue(sent is ClientMessage.OptimizePrompt)
        sent as ClientMessage.OptimizePrompt
        assertEquals(sessionId, sent.sessionId)
        assertEquals(false, sent.shareScreen)
    }

    @Test
    fun `optimizePrompt maps every status`() = runTest {
        val cases: List<Pair<ServerMessage, OptimizeOutcome>> = listOf(
            ServerMessage.OptimizePromptResult(status = "ok", original = "draft", prompt = "Draft") to OptimizeOutcome.Ok("draft"),
            ServerMessage.OptimizePromptResult(status = "ok") to OptimizeOutcome.Ok(null),
            ServerMessage.OptimizePromptResult(status = "no_draft") to OptimizeOutcome.NoDraft,
            ServerMessage.OptimizePromptResult(status = "passthrough") to OptimizeOutcome.Passthrough,
            ServerMessage.OptimizePromptResult(status = "unconfigured") to OptimizeOutcome.Unconfigured,
            ServerMessage.OptimizePromptResult(status = "failed", message = "Prompt too long to optimize") to
                OptimizeOutcome.Failed("Prompt too long to optimize"),
            ServerMessage.OptimizePromptResult(status = "failed") to OptimizeOutcome.Failed(OptimizerStrings.COULD_NOT_REWRITE),
            ServerMessage.OptimizePromptResult(status = "failed", message = "") to OptimizeOutcome.Failed(OptimizerStrings.COULD_NOT_REWRITE),
            ServerMessage.OptimizePromptResult(status = "something_new") to OptimizeOutcome.Failed(OptimizerStrings.COULD_NOT_REWRITE),
        )
        for ((reply, expected) in cases) {
            val controller = SessionController(FakeConnection(autoRespond = { reply }))
            assertEquals(expected, controller.optimizePrompt(sessionId, shareScreen = true), "reply=$reply")
        }
    }

    @Test
    fun `optimizePrompt surfaces an error reply as a SessionException`() = runTest {
        val controller = SessionController(FakeConnection(autoRespond = {
            ServerMessage.Error(code = 401, message = "Not authenticated")
        }))
        val ex = assertThrows(SessionException::class.java) {
            kotlinx.coroutines.runBlocking { controller.optimizePrompt(sessionId, shareScreen = true) }
        }
        assertTrue(ex.isNotAuthenticated)
    }

    @Test
    fun `optimizePrompt ignores a stray session_list_result and waits for its own reply`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)
        var outcome: OptimizeOutcome? = null
        val job = launch { outcome = controller.optimizePrompt(sessionId, shareScreen = true) }
        runCurrent()
        conn.deliver(ServerMessage.SessionList(emptyList()))
        runCurrent()
        assertNull(outcome)
        conn.deliver(ServerMessage.OptimizePromptResult(status = "passthrough"))
        runCurrent()
        assertEquals(OptimizeOutcome.Passthrough, outcome)
        job.join()
    }

    // MARK: - 20 s waiter

    @Test
    fun `optimizePrompt waits past the ordinary 10 s timeout`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)
        var outcome: OptimizeOutcome? = null
        val job = launch { outcome = controller.optimizePrompt(sessionId, shareScreen = true) }
        runCurrent()
        advanceTimeBy(SessionController.RESPONSE_TIMEOUT_MS + 1_000L)
        runCurrent()
        assertNull(outcome, "must still be waiting at 11 s")
        conn.deliver(ServerMessage.OptimizePromptResult(status = "no_draft"))
        runCurrent()
        assertEquals(OptimizeOutcome.NoDraft, outcome)
        job.join()
    }

    @Test
    fun `optimizePrompt times out at 20 s and poisons the socket`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)
        var error: Throwable? = null
        val job = launch {
            try { controller.optimizePrompt(sessionId, shareScreen = true) } catch (e: SessionException) { error = e }
        }
        runCurrent()
        advanceTimeBy(SessionController.OPTIMIZER_TIMEOUT_MS + 1L)
        runCurrent()
        assertNotNull(error)
        assertEquals("The operation timed out.", error!!.message)
        assertTrue(controller.isDesynchronized)
        job.join()
    }

    @Test
    fun `ordinary RPCs still time out at 10 s`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)
        var error: Throwable? = null
        val job = launch {
            try { controller.listSessions() } catch (e: SessionException) { error = e }
        }
        runCurrent()
        advanceTimeBy(SessionController.RESPONSE_TIMEOUT_MS + 1L)
        runCurrent()
        assertNotNull(error)
        job.join()
    }

    // MARK: - replace_prompt

    @Test
    fun `replacePrompt sends the original text back byte for byte`() = runTest {
        val conn = FakeConnection(autoRespond = { ServerMessage.ReplacePromptResult(status = "ok") })
        val controller = SessionController(conn)
        val original = "fix  the\tbug — café 🚀"

        val outcome = controller.replacePrompt(sessionId, original)

        assertEquals(ReplaceOutcome.Ok, outcome)
        val sent = conn.sentMessages.single() as ClientMessage.ReplacePrompt
        assertEquals(sessionId, sent.sessionId)
        assertEquals(original, sent.text)
    }

    @Test
    fun `replacePrompt maps failed with and without a message`() = runTest {
        assertEquals(
            ReplaceOutcome.Failed("Session not attached"),
            SessionController(FakeConnection(autoRespond = {
                ServerMessage.ReplacePromptResult(status = "failed", message = "Session not attached")
            })).replacePrompt(sessionId, "x"),
        )
        assertEquals(
            ReplaceOutcome.Failed(OptimizerStrings.COULD_NOT_REWRITE),
            SessionController(FakeConnection(autoRespond = { ServerMessage.ReplacePromptResult(status = "failed") }))
                .replacePrompt(sessionId, "x"),
        )
        assertEquals(
            ReplaceOutcome.Failed(OptimizerStrings.COULD_NOT_REWRITE),
            SessionController(FakeConnection(autoRespond = { ServerMessage.ReplacePromptResult(status = "weird") }))
                .replacePrompt(sessionId, "x"),
        )
    }

    // MARK: - Copy

    @Test
    fun `optimizer strings are byte-exact with the spec`() {
        assertEquals("Enable on the relay: claude-relay config set promptOptimizerEnabled true", OptimizerStrings.CONFIG_HINT)
        assertEquals("Update the relay to use the prompt optimizer", OptimizerStrings.UPDATE_RELAY_HINT)
        assertEquals("Type or dictate a prompt first", OptimizerStrings.NO_DRAFT)
        assertEquals("Nothing to optimize", OptimizerStrings.PASSTHROUGH)
        assertEquals("Optimizer could not rewrite this prompt", OptimizerStrings.COULD_NOT_REWRITE)
        assertEquals("Optimized", OptimizerStrings.OPTIMIZED)
        assertEquals("Undo", OptimizerStrings.UNDO)
        assertEquals("Optimize Prompt", OptimizerStrings.WAND_LABEL)
        assertEquals("Share terminal screen with the optimizer", OptimizerStrings.SHARE_SCREEN_TOGGLE)
        assertEquals(
            "With this on, the relay also sends the last 40 lines of the terminal screen to the optimizer model. " +
                "The draft and its working directory are always sent.",
            OptimizerStrings.SHARE_SCREEN_FOOTER,
        )
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run (from `CodeRelayAndroid/`): `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :core-net:test --tests 'relay.net.SessionControllerOptimizerTest' 2>&1 | tail -20; echo EXIT=${pipestatus[1]}`
Expected: compilation FAILS (`Unresolved reference: serverProtocolVersion`, `optimizePrompt`, `OPTIMIZER_TIMEOUT_MS`, …).

- [ ] **Step 5: Bump the protocol version**

In `SessionController.kt` lines 18-20 change `const val CURRENT = 1` to `const val CURRENT = 2`. Leave `MIN = 0`. Update the KDoc above it to add one sentence: `Version 2 adds ``capabilities`` to ``auth_success`` and the ``optimize_prompt`` / ``replace_prompt`` RPCs.`

- [ ] **Step 6: Add the server fields**

Directly after the `tokenId` property (after line 73 `private set`), add:

```kotlin
    /**
     * The protocol version the server reported in `auth_success` (0 before
     * authentication, and again after [resetAuth]). Together with
     * [serverCapabilities] this decides whether the prompt-optimizer wand is
     * available (spec §7.1) — see `PromptOptimizerController`.
     */
    var serverProtocolVersion: Int = 0
        private set

    /**
     * The optional capability list from `auth_success`, as a set (empty when the
     * server sent none, and again after [resetAuth]). Today's only member is
     * [PromptOptimizerProtocol.CAPABILITY].
     */
    var serverCapabilities: Set<String> = emptySet()
        private set
```

In `resetAuth()` (line 165-168) add two lines so it reads:

```kotlin
    fun resetAuth() {
        isAuthenticated = false
        sessionId = null
        serverProtocolVersion = 0
        serverCapabilities = emptySet()
    }
```

In `authenticate(token)`, inside the `is ServerMessage.AuthSuccess ->` branch, right after the line that sets `isAuthenticated = true`, add:

```kotlin
                serverProtocolVersion = serverVersion
                serverCapabilities = response.capabilities?.toSet() ?: emptySet()
```

(`serverVersion` is the existing local `response.protocolVersion ?: 0`.)

- [ ] **Step 7: Add the timeout parameter and the two RPCs**

Replace `sendAndWaitForResponse` / the head of `awaitResponse` (lines 383-392) with:

```kotlin
    private suspend fun sendAndWaitForResponse(
        message: ClientMessage,
        expected: Set<String>,
        timeoutMs: Long = RESPONSE_TIMEOUT_MS,
    ): ServerMessage = rpcLock.withLock { awaitResponse(message, expected, timeoutMs) }

    private suspend fun awaitResponse(
        message: ClientMessage,
        expected: Set<String>,
        timeoutMs: Long,
    ): ServerMessage {
```

and, further down in `awaitResponse`, change `withTimeoutOrNull(RESPONSE_TIMEOUT_MS)` to `withTimeoutOrNull(timeoutMs)`. Update the KDoc on `sendAndWaitForResponse` so "waits up to [RESPONSE_TIMEOUT_MS]" reads "waits up to [timeoutMs] (default [RESPONSE_TIMEOUT_MS]; the optimizer RPCs pass [OPTIMIZER_TIMEOUT_MS])".

After `detach()` (line 315) add a new section:

```kotlin
    // MARK: - Prompt optimizer (spec §6, §7.1)

    /**
     * Asks the relay to rewrite the draft at the agent's input line for the
     * attached [sessionId]. Waits [OPTIMIZER_TIMEOUT_MS] — the model call is the
     * slow part — while every other RPC keeps [RESPONSE_TIMEOUT_MS]. Never logs
     * any payload (spec §10).
     */
    suspend fun optimizePrompt(sessionId: UUID, shareScreen: Boolean): OptimizeOutcome {
        val response = sendAndWaitForResponse(
            ClientMessage.OptimizePrompt(sessionId, shareScreen),
            expected = setOf("optimize_prompt_result"),
            timeoutMs = OPTIMIZER_TIMEOUT_MS,
        )
        return when (response) {
            is ServerMessage.OptimizePromptResult -> when (response.status) {
                "ok" -> OptimizeOutcome.Ok(response.original)
                "no_draft" -> OptimizeOutcome.NoDraft
                "passthrough" -> OptimizeOutcome.Passthrough
                "unconfigured" -> OptimizeOutcome.Unconfigured
                else -> OptimizeOutcome.Failed(failureMessage(response.message))
            }
            is ServerMessage.Error -> throw unexpected(response.message)
            else -> throw unexpected(response)
        }
    }

    /** Undo: types [text] (the pre-optimize original) back over the input line. */
    suspend fun replacePrompt(sessionId: UUID, text: String): ReplaceOutcome {
        val response = sendAndWaitForResponse(
            ClientMessage.ReplacePrompt(sessionId, text),
            expected = setOf("replace_prompt_result"),
            timeoutMs = OPTIMIZER_TIMEOUT_MS,
        )
        return when (response) {
            is ServerMessage.ReplacePromptResult ->
                if (response.status == "ok") ReplaceOutcome.Ok
                else ReplaceOutcome.Failed(failureMessage(response.message))
            is ServerMessage.Error -> throw unexpected(response.message)
            else -> throw unexpected(response)
        }
    }

    /** The server's message when it sent a non-empty one, else the spec §9 fallback. */
    private fun failureMessage(message: String?): String =
        message?.takeIf { it.isNotEmpty() } ?: OptimizerStrings.COULD_NOT_REWRITE
```

In the companion object, directly under `const val RESPONSE_TIMEOUT_MS = 10_000L`, add:

```kotlin
        /**
         * Waiter for `optimize_prompt` / `replace_prompt` only: the relay's model
         * call takes seconds, so the ordinary 10 s would time out spuriously and
         * poison the socket (spec §7.1).
         */
        const val OPTIMIZER_TIMEOUT_MS = 20_000L
```

- [ ] **Step 8: Run the new tests and the whole core-net suite**

Run: `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :core-net:test 2>&1 | tail -20; echo EXIT=${pipestatus[1]}`
Expected: `BUILD SUCCESSFUL`, `EXIT=0`. If an existing `SessionControllerTest` asserts `protocolVersion == 1` on the sent `AuthRequest`, update that one assertion to `2` and note it in the commit body.

- [ ] **Step 9: Commit**

```bash
git add CodeRelayAndroid/core-net/src/main/kotlin/relay/net/PromptOptimizer.kt \
        CodeRelayAndroid/core-net/src/main/kotlin/relay/net/SessionController.kt \
        CodeRelayAndroid/core-net/src/test/kotlin/relay/net/SessionControllerTest.kt \
        CodeRelayAndroid/core-net/src/test/kotlin/relay/net/SessionControllerOptimizerTest.kt
git commit -m "feat(android): optimize_prompt/replace_prompt RPCs, server capabilities, protocol v2

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `core-session` — `PromptOptimizerController` and coordinator wiring

**Files:**
- Create: `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/PromptOptimizerController.kt`
- Test: `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/PromptOptimizerControllerTest.kt` (create)
- Modify: `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/SessionCoordinator.kt` (imports :1-22; published state around :264; `init` at :322-327; `tearDown()` at :1362-1376)
- Modify: `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/SessionCoordinatorTest.kt` (append one test)

**Interfaces:**
- Consumes (Task 1): `SessionController.optimizePrompt / replacePrompt / serverProtocolVersion / serverCapabilities / isAuthenticated`, `OptimizeOutcome`, `ReplaceOutcome`, `OptimizerStrings`, `PromptOptimizerProtocol`, `SessionException`; existing `AuthCoordinator.ensureAuthenticated()` / `withAuth { }`, `RecoveryController.isRecovering`.
- Produces (Task 3 relies on these exact names, all on `SessionCoordinator`):
  - `enum class OptimizerAvailability { UNKNOWN, SERVER_TOO_OLD, UNCONFIGURED, AVAILABLE }`
  - `enum class OptimizerState { IDLE, OPTIMIZING }`
  - `data class OptimizerUndo(val sessionId: UUID, val original: String)`
  - `val optimizerAvailability: StateFlow<OptimizerAvailability>`, `val optimizerState: StateFlow<OptimizerState>`, `val optimizerUndo: StateFlow<OptimizerUndo?>`, `val optimizerNotice: StateFlow<String?>`
  - `val isWandEnabled: Boolean` (computed), `val wandHint: String?` (computed)
  - `suspend fun optimizePrompt(shareScreen: Boolean)`, `suspend fun undoOptimize()`, `fun dismissOptimizerNotice()`
- Design rulings (record in the ledger if a reviewer disputes them):
  1. The state machine is its own class with lambda seams (like `RecoveryController`), so it is tested with plain lambdas and no coordinator harness.
  2. There is **no** eager collector on `activeSessionId` (an eager collector on the coordinator scope strands a coroutine under `runTest`, per the existing comment at `SessionCoordinator.kt:224`). Instead the undo is *keyed by session*: `undoOptimize()` refuses when `undo.sessionId != activeSessionId()`, and Task 3's chip renders only while that session is active. Switching away and back inside the 10 s window shows the chip again, which is correct — the original still belongs to that session.
  3. Undo is cleared **only** on `ReplaceOutcome.Ok`, on expiry, or when a new successful optimize replaces it (Global Constraints).
  4. `Ok(original = null)` shows the `OPTIMIZED` notice without an Undo (there is nothing to undo to) rather than nothing at all.
  5. A stale notice is dismissed when a new optimize starts, so a success chip never renders beside an old failure toast.

- [ ] **Step 1: Write the failing tests**

Create `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/PromptOptimizerControllerTest.kt`:

```kotlin
package relay.session

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.net.OptimizeOutcome
import relay.net.OptimizerStrings
import relay.net.ReplaceOutcome
import relay.net.SessionException
import java.util.UUID

/**
 * The wand state machine (spec §7.1, §9), ported from
 * `SharedSessionCoordinator+Optimizer.swift` with the PR #58 review fix: a
 * failed Undo keeps the original.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class PromptOptimizerControllerTest {

    private val sessionA: UUID = UUID.fromString("00000000-0000-0000-0000-00000000000a")
    private val sessionB: UUID = UUID.fromString("00000000-0000-0000-0000-00000000000b")

    /** Scriptable seams; every default is "authenticated, v2, capable, idle, session A active". */
    private class Harness(scope: TestScope) {
        var authenticated = true
        var serverVersion = 2
        var capabilities: Set<String> = setOf("prompt_optimizer")
        var activeSession: UUID? = UUID.fromString("00000000-0000-0000-0000-00000000000a")
        var recovering = false
        var ensureAuthCalls = 0
        var optimizeCalls = mutableListOf<Pair<UUID, Boolean>>()
        var replaceCalls = mutableListOf<Pair<UUID, String>>()
        var optimizeResult: suspend () -> OptimizeOutcome = { OptimizeOutcome.Ok("original") }
        var replaceResult: suspend () -> ReplaceOutcome = { ReplaceOutcome.Ok }

        val controller = PromptOptimizerController(
            scope = scope,
            ensureAuthenticated = { ensureAuthCalls++ },
            withAuth = { body -> body() },
            isAuthenticated = { authenticated },
            serverProtocolVersion = { serverVersion },
            serverCapabilities = { capabilities },
            activeSessionId = { activeSession },
            isRecovering = { recovering },
            optimize = { id, share -> optimizeCalls += id to share; optimizeResult() },
            replace = { id, text -> replaceCalls += id to text; replaceResult() },
        )
    }

    // MARK: - Availability

    @Test
    fun `availability is unknown until authenticated`() = runTest {
        val h = Harness(this)
        h.authenticated = false
        h.controller.refreshAvailability()
        assertEquals(OptimizerAvailability.UNKNOWN, h.controller.availability.value)
        assertNull(h.controller.wandHint)
    }

    @Test
    fun `server below protocol 2 is too old`() = runTest {
        val h = Harness(this)
        h.serverVersion = 1
        h.capabilities = setOf("prompt_optimizer") // a v1 server cannot send this, but the version check must win
        h.controller.refreshAvailability()
        assertEquals(OptimizerAvailability.SERVER_TOO_OLD, h.controller.availability.value)
        assertEquals(OptimizerStrings.UPDATE_RELAY_HINT, h.controller.wandHint)
    }

    @Test
    fun `protocol 2 without the capability is unconfigured`() = runTest {
        val h = Harness(this)
        h.capabilities = emptySet()
        h.controller.refreshAvailability()
        assertEquals(OptimizerAvailability.UNCONFIGURED, h.controller.availability.value)
        assertEquals(OptimizerStrings.CONFIG_HINT, h.controller.wandHint)
    }

    @Test
    fun `protocol 2 with the capability is available`() = runTest {
        val h = Harness(this)
        h.controller.refreshAvailability()
        assertEquals(OptimizerAvailability.AVAILABLE, h.controller.availability.value)
        assertNull(h.controller.wandHint)
        assertTrue(h.controller.isAvailable)
    }

    // MARK: - isWandEnabled

    @Test
    fun `wand is enabled only when idle, not recovering, with an active session`() = runTest {
        val h = Harness(this)
        assertTrue(h.controller.isWandEnabled)
        h.recovering = true
        assertFalse(h.controller.isWandEnabled)
        h.recovering = false
        h.activeSession = null
        assertFalse(h.controller.isWandEnabled)
    }

    @Test
    fun `wand is enabled while unavailable so a tap can show the hint`() = runTest {
        val h = Harness(this)
        h.capabilities = emptySet()
        h.controller.refreshAvailability()
        assertTrue(h.controller.isWandEnabled)
        assertFalse(h.controller.isAvailable)
    }

    // MARK: - optimizePrompt

    @Test
    fun `successful optimize arms undo for the active session and sends shareScreen`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = false)
        assertEquals(listOf(sessionA to false), h.optimizeCalls)
        assertEquals(1, h.ensureAuthCalls)
        assertEquals(OptimizerUndo(sessionA, "original"), h.controller.undo.value)
        assertNull(h.controller.notice.value)
        assertEquals(OptimizerState.IDLE, h.controller.state.value)
    }

    @Test
    fun `state is optimizing while the RPC is in flight and idle after`() = runTest {
        val h = Harness(this)
        val gate = CompletableDeferred<OptimizeOutcome>()
        h.optimizeResult = { gate.await() }
        val job = launch { h.controller.optimizePrompt(shareScreen = true) }
        runCurrent()
        assertEquals(OptimizerState.OPTIMIZING, h.controller.state.value)
        assertFalse(h.controller.isWandEnabled)
        gate.complete(OptimizeOutcome.Passthrough)
        job.join()
        assertEquals(OptimizerState.IDLE, h.controller.state.value)
    }

    @Test
    fun `a second tap while optimizing is ignored`() = runTest {
        val h = Harness(this)
        val gate = CompletableDeferred<OptimizeOutcome>()
        h.optimizeResult = { gate.await() }
        val job = launch { h.controller.optimizePrompt(shareScreen = true) }
        runCurrent()
        h.controller.optimizePrompt(shareScreen = true)
        assertEquals(1, h.optimizeCalls.size)
        gate.complete(OptimizeOutcome.Passthrough)
        job.join()
    }

    @Test
    fun `undo expires after 10 seconds`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        advanceTimeBy(PromptOptimizerController.UNDO_WINDOW_MS - 1L)
        runCurrent()
        assertEquals(OptimizerUndo(sessionA, "original"), h.controller.undo.value)
        advanceTimeBy(2L)
        runCurrent()
        assertNull(h.controller.undo.value)
    }

    @Test
    fun `ok without an original shows Optimized and arms no undo`() = runTest {
        val h = Harness(this)
        h.optimizeResult = { OptimizeOutcome.Ok(null) }
        h.controller.optimizePrompt(shareScreen = true)
        assertNull(h.controller.undo.value)
        assertEquals(OptimizerStrings.OPTIMIZED, h.controller.notice.value)
    }

    @Test
    fun `switching sessions mid-optimize does not arm undo for the new session`() = runTest {
        val h = Harness(this)
        val gate = CompletableDeferred<OptimizeOutcome>()
        h.optimizeResult = { gate.await() }
        val job = launch { h.controller.optimizePrompt(shareScreen = true) }
        runCurrent()
        h.activeSession = sessionB
        gate.complete(OptimizeOutcome.Ok("original"))
        job.join()
        assertNull(h.controller.undo.value)
    }

    @Test
    fun `no draft, passthrough and failed show their toasts and clear after 4 seconds`() = runTest {
        val cases = listOf(
            OptimizeOutcome.NoDraft to OptimizerStrings.NO_DRAFT,
            OptimizeOutcome.Passthrough to OptimizerStrings.PASSTHROUGH,
            OptimizeOutcome.Failed("Prompt too long to optimize") to "Prompt too long to optimize",
        )
        for ((outcome, expected) in cases) {
            val h = Harness(this)
            h.optimizeResult = { outcome }
            h.controller.optimizePrompt(shareScreen = true)
            assertEquals(expected, h.controller.notice.value, "outcome=$outcome")
            assertNull(h.controller.undo.value)
            advanceTimeBy(PromptOptimizerController.NOTICE_WINDOW_MS + 1L)
            runCurrent()
            assertNull(h.controller.notice.value)
        }
    }

    @Test
    fun `unconfigured reply downgrades availability and shows the config hint`() = runTest {
        val h = Harness(this)
        h.controller.refreshAvailability()
        assertEquals(OptimizerAvailability.AVAILABLE, h.controller.availability.value)
        h.optimizeResult = { OptimizeOutcome.Unconfigured }
        h.controller.optimizePrompt(shareScreen = true)
        assertEquals(OptimizerAvailability.UNCONFIGURED, h.controller.availability.value)
        assertEquals(OptimizerStrings.CONFIG_HINT, h.controller.notice.value)
    }

    @Test
    fun `tapping while unavailable shows the hint without an RPC`() = runTest {
        val h = Harness(this)
        h.serverVersion = 1
        h.controller.refreshAvailability()
        h.controller.optimizePrompt(shareScreen = true)
        assertEquals(OptimizerStrings.UPDATE_RELAY_HINT, h.controller.notice.value)
        assertTrue(h.optimizeCalls.isEmpty())
        assertEquals(0, h.ensureAuthCalls)
    }

    @Test
    fun `availability is re-derived after auth so a fresh server flips the hint`() = runTest {
        val h = Harness(this)
        // Cached UNKNOWN (never refreshed) → the fast path has no hint, so we go through auth …
        h.capabilities = emptySet()
        h.controller.optimizePrompt(shareScreen = true)
        // … and the post-auth refresh sees v2-without-capability.
        assertEquals(OptimizerAvailability.UNCONFIGURED, h.controller.availability.value)
        assertEquals(OptimizerStrings.CONFIG_HINT, h.controller.notice.value)
        assertTrue(h.optimizeCalls.isEmpty())
    }

    @Test
    fun `failed retry keeps the existing undo`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        val armed = h.controller.undo.value
        h.optimizeResult = { OptimizeOutcome.Failed("Optimizer unavailable, try again") }
        h.controller.optimizePrompt(shareScreen = true)
        assertEquals(armed, h.controller.undo.value)
        assertEquals("Optimizer unavailable, try again", h.controller.notice.value)
    }

    @Test
    fun `a new optimize dismisses a stale notice`() = runTest {
        val h = Harness(this)
        h.optimizeResult = { OptimizeOutcome.Failed("Optimizer unavailable, try again") }
        h.controller.optimizePrompt(shareScreen = true)
        assertEquals("Optimizer unavailable, try again", h.controller.notice.value)
        h.optimizeResult = { OptimizeOutcome.Ok("original") }
        h.controller.optimizePrompt(shareScreen = true)
        assertNull(h.controller.notice.value)
        assertEquals(OptimizerUndo(sessionA, "original"), h.controller.undo.value)
    }

    @Test
    fun `transport failure shows the exception message or the fallback`() = runTest {
        val h = Harness(this)
        h.optimizeResult = { throw SessionException("The operation timed out.") }
        h.controller.optimizePrompt(shareScreen = true)
        assertEquals("The operation timed out.", h.controller.notice.value)
        assertEquals(OptimizerState.IDLE, h.controller.state.value)

        val h2 = Harness(this)
        h2.optimizeResult = { throw SessionException("") }
        h2.controller.optimizePrompt(shareScreen = true)
        assertEquals(OptimizerStrings.COULD_NOT_REWRITE, h2.controller.notice.value)
    }

    @Test
    fun `optimize is a no-op while recovering or without a session`() = runTest {
        val h = Harness(this)
        h.recovering = true
        h.controller.optimizePrompt(shareScreen = true)
        h.recovering = false
        h.activeSession = null
        h.controller.optimizePrompt(shareScreen = true)
        assertTrue(h.optimizeCalls.isEmpty())
        assertNull(h.controller.notice.value)
    }

    // MARK: - undoOptimize

    @Test
    fun `undo sends the original once and clears the chip on success`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        h.controller.undoOptimize()
        assertEquals(listOf(sessionA to "original"), h.replaceCalls)
        assertNull(h.controller.undo.value)
        assertNull(h.controller.notice.value)
        h.controller.undoOptimize()
        assertEquals(1, h.replaceCalls.size, "undo is one-shot")
    }

    @Test
    fun `failed undo keeps the chip and shows the server message`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        h.replaceResult = { ReplaceOutcome.Failed("Session not attached") }
        h.controller.undoOptimize()
        assertEquals(OptimizerUndo(sessionA, "original"), h.controller.undo.value)
        assertEquals("Session not attached", h.controller.notice.value)
        // The original 10 s window still expires on schedule — not extended by the failure.
        advanceTimeBy(PromptOptimizerController.UNDO_WINDOW_MS + 1L)
        runCurrent()
        assertNull(h.controller.undo.value)
    }

    @Test
    fun `undo transport failure keeps the chip`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        h.replaceResult = { throw SessionException("The operation timed out.") }
        h.controller.undoOptimize()
        assertEquals(OptimizerUndo(sessionA, "original"), h.controller.undo.value)
        assertEquals("The operation timed out.", h.controller.notice.value)
        assertEquals(OptimizerState.IDLE, h.controller.state.value)
    }

    @Test
    fun `undo refuses when another session is active or while recovering`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        h.activeSession = sessionB
        h.controller.undoOptimize()
        assertTrue(h.replaceCalls.isEmpty())
        h.activeSession = sessionA
        h.recovering = true
        h.controller.undoOptimize()
        assertTrue(h.replaceCalls.isEmpty())
        assertEquals(OptimizerUndo(sessionA, "original"), h.controller.undo.value)
    }

    @Test
    fun `undo with nothing armed is a no-op`() = runTest {
        val h = Harness(this)
        h.controller.undoOptimize()
        assertTrue(h.replaceCalls.isEmpty())
    }

    // MARK: - Notices + cancel

    @Test
    fun `dismissOptimizerNotice clears immediately`() = runTest {
        val h = Harness(this)
        h.optimizeResult = { OptimizeOutcome.NoDraft }
        h.controller.optimizePrompt(shareScreen = true)
        h.controller.dismissNotice()
        assertNull(h.controller.notice.value)
    }

    @Test
    fun `cancel clears undo and notice and stops the timers`() = runTest {
        val h = Harness(this)
        h.controller.optimizePrompt(shareScreen = true)
        h.controller.cancel()
        assertNull(h.controller.undo.value)
        assertNull(h.controller.notice.value)
        advanceTimeBy(PromptOptimizerController.UNDO_WINDOW_MS + 1L)
        runCurrent() // must not throw or resurrect anything
        assertNull(h.controller.undo.value)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :core-session:test --tests 'relay.session.PromptOptimizerControllerTest' 2>&1 | tail -20; echo EXIT=${pipestatus[1]}`
Expected: compilation FAILS (`Unresolved reference: PromptOptimizerController`).

- [ ] **Step 3: Implement the controller**

Create `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/PromptOptimizerController.kt`:

```kotlin
package relay.session

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import relay.net.OptimizeOutcome
import relay.net.OptimizerStrings
import relay.net.PromptOptimizerProtocol
import relay.net.ReplaceOutcome
import java.util.UUID

/** What the relay told us about the optimizer at auth time (spec §7.1, §9). */
enum class OptimizerAvailability {
    /** Not authenticated yet — nothing known. */
    UNKNOWN,
    /** `auth_success.protocolVersion` < 2: the relay predates the feature. */
    SERVER_TOO_OLD,
    /** Protocol ≥ 2 but no `prompt_optimizer` capability: not enabled / no key on the relay. */
    UNCONFIGURED,
    AVAILABLE,
}

enum class OptimizerState { IDLE, OPTIMIZING }

/** The pre-optimize draft, kept for 10 s so Undo can type it back (spec §7.1). */
data class OptimizerUndo(val sessionId: UUID, val original: String)

/**
 * The magic-wand state machine, ported from
 * `SharedSessionCoordinator+Optimizer.swift`. Owned by [SessionCoordinator] the
 * way [RecoveryController] and [ActivityCoordinator] are: every dependency is a
 * lambda, so the transitions are unit-tested with no socket, no controller and
 * no coordinator harness.
 *
 * Rules (Global Constraints of the Plan 3 document):
 *  - *Available* = protocol ≥ [PromptOptimizerProtocol.MIN_PROTOCOL_VERSION]
 *    **and** the [PromptOptimizerProtocol.CAPABILITY] capability. Unavailable is
 *    still *tappable*: the tap shows the hint instead of an RPC.
 *  - *Enabled* = [OptimizerState.IDLE] ∧ ¬recovering ∧ an active session.
 *  - Undo is one-shot, keyed by session, lives [UNDO_WINDOW_MS], and is cleared
 *    **only** by a successful `replace_prompt`, by expiry, or by a later
 *    successful optimize. A failed optimize or a failed undo keeps it, so the
 *    user's original is never discarded on an error (PR #58 finding A1-#1).
 *  - Nothing here logs: the draft, the prompt and the original are user text
 *    (spec §10).
 */
class PromptOptimizerController(
    private val scope: CoroutineScope,
    private val ensureAuthenticated: suspend () -> Unit,
    private val withAuth: suspend (suspend () -> Unit) -> Unit,
    private val isAuthenticated: () -> Boolean,
    private val serverProtocolVersion: () -> Int,
    private val serverCapabilities: () -> Set<String>,
    private val activeSessionId: () -> UUID?,
    private val isRecovering: () -> Boolean,
    private val optimize: suspend (sessionId: UUID, shareScreen: Boolean) -> OptimizeOutcome,
    private val replace: suspend (sessionId: UUID, text: String) -> ReplaceOutcome,
) {
    private val _availability = MutableStateFlow(OptimizerAvailability.UNKNOWN)
    val availability: StateFlow<OptimizerAvailability> = _availability.asStateFlow()

    private val _state = MutableStateFlow(OptimizerState.IDLE)
    val state: StateFlow<OptimizerState> = _state.asStateFlow()

    private val _undo = MutableStateFlow<OptimizerUndo?>(null)
    val undo: StateFlow<OptimizerUndo?> = _undo.asStateFlow()

    private val _notice = MutableStateFlow<String?>(null)
    /** The 4 s toast text, or null. */
    val notice: StateFlow<String?> = _notice.asStateFlow()

    private var undoExpiry: Job? = null
    private var noticeExpiry: Job? = null

    /** Tappable: not mid-RPC, not recovering, and there is a session to optimize. */
    val isWandEnabled: Boolean
        get() = _state.value == OptimizerState.IDLE && !isRecovering() && activeSessionId() != null

    val isAvailable: Boolean
        get() = _availability.value == OptimizerAvailability.AVAILABLE

    /** The toast for an unavailable wand, or null when available / unknown. */
    val wandHint: String?
        get() = when (_availability.value) {
            OptimizerAvailability.SERVER_TOO_OLD -> OptimizerStrings.UPDATE_RELAY_HINT
            OptimizerAvailability.UNCONFIGURED -> OptimizerStrings.CONFIG_HINT
            OptimizerAvailability.UNKNOWN, OptimizerAvailability.AVAILABLE -> null
        }

    /** Re-derives [availability] from the controller's `auth_success` facts. Call after every authenticate. */
    fun refreshAvailability() {
        _availability.value = when {
            !isAuthenticated() -> OptimizerAvailability.UNKNOWN
            serverProtocolVersion() < PromptOptimizerProtocol.MIN_PROTOCOL_VERSION -> OptimizerAvailability.SERVER_TOO_OLD
            PromptOptimizerProtocol.CAPABILITY in serverCapabilities() -> OptimizerAvailability.AVAILABLE
            else -> OptimizerAvailability.UNCONFIGURED
        }
    }

    /**
     * The wand tap. Fast-paths the hint when the cached availability already says
     * no; otherwise authenticates, re-derives availability (a reconnect may have
     * landed on a different relay), and runs the RPC.
     */
    suspend fun optimizePrompt(shareScreen: Boolean) {
        if (!isWandEnabled) return
        val sessionId = activeSessionId() ?: return
        wandHint?.let { showNotice(it); return }

        dismissNotice()
        _state.value = OptimizerState.OPTIMIZING
        try {
            ensureAuthenticated()
            refreshAvailability()
            wandHint?.let { showNotice(it); return }

            var outcome: OptimizeOutcome? = null
            withAuth { outcome = optimize(sessionId, shareScreen) }
            when (val result = outcome) {
                is OptimizeOutcome.Ok -> {
                    val original = result.original
                    if (original != null && activeSessionId() == sessionId) {
                        armUndo(OptimizerUndo(sessionId, original))
                    } else if (original == null) {
                        showNotice(OptimizerStrings.OPTIMIZED)
                    }
                }
                OptimizeOutcome.NoDraft -> showNotice(OptimizerStrings.NO_DRAFT)
                OptimizeOutcome.Passthrough -> showNotice(OptimizerStrings.PASSTHROUGH)
                OptimizeOutcome.Unconfigured -> {
                    _availability.value = OptimizerAvailability.UNCONFIGURED
                    showNotice(OptimizerStrings.CONFIG_HINT)
                }
                is OptimizeOutcome.Failed -> showNotice(result.message)
                null -> showNotice(OptimizerStrings.COULD_NOT_REWRITE)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            showNotice(messageFor(e))
        } finally {
            _state.value = OptimizerState.IDLE
        }
    }

    /** Undo: one-shot `replace_prompt(original)`; the chip survives a failure so the user can retry. */
    suspend fun undoOptimize() {
        if (!isWandEnabled) return
        val armed = _undo.value ?: return
        if (armed.sessionId != activeSessionId()) return

        _state.value = OptimizerState.OPTIMIZING
        try {
            var outcome: ReplaceOutcome? = null
            withAuth { outcome = replace(armed.sessionId, armed.original) }
            when (val result = outcome) {
                ReplaceOutcome.Ok -> clearUndo()
                is ReplaceOutcome.Failed -> showNotice(result.message)
                null -> showNotice(OptimizerStrings.COULD_NOT_REWRITE)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            showNotice(messageFor(e))
        } finally {
            _state.value = OptimizerState.IDLE
        }
    }

    fun dismissNotice() {
        noticeExpiry?.cancel()
        noticeExpiry = null
        _notice.value = null
    }

    /** Teardown: drop the chip and the toast and stop their timers. */
    fun cancel() {
        clearUndo()
        dismissNotice()
    }

    private fun showNotice(text: String) {
        noticeExpiry?.cancel()
        _notice.value = text
        noticeExpiry = scope.launch {
            delay(NOTICE_WINDOW_MS)
            _notice.value = null
        }
    }

    private fun armUndo(undo: OptimizerUndo) {
        undoExpiry?.cancel()
        _undo.value = undo
        undoExpiry = scope.launch {
            delay(UNDO_WINDOW_MS)
            _undo.value = null
        }
    }

    private fun clearUndo() {
        undoExpiry?.cancel()
        undoExpiry = null
        _undo.value = null
    }

    private fun messageFor(e: Exception): String =
        e.message?.takeIf { it.isNotEmpty() } ?: OptimizerStrings.COULD_NOT_REWRITE

    companion object {
        /** How long the "Optimized · Undo" chip stays (spec §7.1). */
        const val UNDO_WINDOW_MS = 10_000L
        /** How long a toast stays (spec §7.1). */
        const val NOTICE_WINDOW_MS = 4_000L
    }
}
```

- [ ] **Step 4: Run the controller tests**

Run: `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :core-session:test --tests 'relay.session.PromptOptimizerControllerTest' 2>&1 | tail -20; echo EXIT=${pipestatus[1]}`
Expected: `BUILD SUCCESSFUL`, `EXIT=0`, 26 tests.

- [ ] **Step 5: Write the failing coordinator test**

Append to `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/SessionCoordinatorTest.kt` (inside the class, before its closing brace; the file already imports `StandardTestDispatcher`, `advanceUntilIdle`, `runTest`, `CallLog`, `FakeConnectionSurface`, `FakeCoordinatorConnection`, `FakeOwnershipStore`, `SessionController`, `ConnectionConfig`, `ClientMessage`, `ServerMessage`):

```kotlin
    // -------------------------------------------------------------------------
    // PROMPT OPTIMIZER: availability is derived from auth_success after connect,
    // and tearDown drops the undo/notice state.
    // -------------------------------------------------------------------------

    @Test
    fun `connect derives optimizer availability from auth_success`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val store = FakeOwnershipStore(log)
        surface.responder = { message ->
            if (message is ClientMessage.AuthRequest) {
                ServerMessage.AuthSuccess(protocolVersion = 2, tokenId = "tok", capabilities = listOf("prompt_optimizer"))
            } else {
                surface.defaultResponseFor(message)
            }
        }
        val coord = SessionCoordinator(
            scope = this,
            connection = conn,
            sessionController = SessionController(surface),
            token = "tok",
            ownershipStore = store,
            config = config,
        )
        assertEquals(OptimizerAvailability.UNKNOWN, coord.optimizerAvailability.value)

        coord.connect()
        advanceUntilIdle()

        assertEquals(OptimizerAvailability.AVAILABLE, coord.optimizerAvailability.value)
        assertEquals(OptimizerState.IDLE, coord.optimizerState.value)
        assertNull(coord.optimizerUndo.value)
        assertNull(coord.optimizerNotice.value)
        coord.tearDown()
    }

    @Test
    fun `an old server marks the optimizer too old`() = runTest {
        val log = CallLog()
        val surface = FakeConnectionSurface(log)
        val conn = FakeCoordinatorConnection(log)
        val store = FakeOwnershipStore(log)
        // The default responder answers auth_success with protocolVersion = 1.
        val coord = SessionCoordinator(
            scope = this,
            connection = conn,
            sessionController = SessionController(surface),
            token = "tok",
            ownershipStore = store,
            config = config,
        )
        coord.connect()
        advanceUntilIdle()
        assertEquals(OptimizerAvailability.SERVER_TOO_OLD, coord.optimizerAvailability.value)
        assertEquals(OptimizerStrings.UPDATE_RELAY_HINT, coord.wandHint)
        coord.tearDown()
    }
```

Add `import relay.net.OptimizerStrings` to that test file's imports. In `CoordinatorTestDoubles.kt`, `FakeConnectionSurface.defaultResponse` is `private`; rename it to `internal fun defaultResponseFor(message: ClientMessage): ServerMessage?` and update its one internal call site (`var responder ... = { defaultResponse(it) }` → `{ defaultResponseFor(it) }`).

If the test's default-dispatcher construction (`scope = this` without `dispatcher`) differs from how the neighbouring tests build a coordinator, copy the neighbouring pattern exactly (the `createNewSession wires after the create RPC and claims` test at the top of the file is the reference) — the assertions are what matter.

- [ ] **Step 6: Run to verify the coordinator tests fail**

Run: `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :core-session:test --tests 'relay.session.SessionCoordinatorTest' 2>&1 | tail -20; echo EXIT=${pipestatus[1]}`
Expected: compilation FAILS (`Unresolved reference: optimizerAvailability`).

- [ ] **Step 7: Wire the controller into `SessionCoordinator`**

In `SessionCoordinator.kt`:

1. Add to the class body, next to the other collaborator declarations (`private val recoveryController: RecoveryController`, `private val authCoordinator: AuthCoordinator`, …) — find where `authCoordinator` is declared (it is assigned in `init`), and add after it:

```kotlin
    /** The magic-wand state machine (spec §7.1). Built in `init`, after [authCoordinator]. */
    private val promptOptimizer: PromptOptimizerController
```

2. In `init` (line 322), directly after the `authCoordinator = AuthCoordinator(...)` assignment and before `activityCoordinator = ...`, add:

```kotlin
        promptOptimizer = PromptOptimizerController(
            scope = scope,
            ensureAuthenticated = { authCoordinator.ensureAuthenticated() },
            withAuth = { body -> authCoordinator.withAuth { body() } },
            isAuthenticated = { sessionController.isAuthenticated },
            serverProtocolVersion = { sessionController.serverProtocolVersion },
            serverCapabilities = { sessionController.serverCapabilities },
            activeSessionId = { _activeSessionId.value },
            isRecovering = { recoveryController.isRecovering.value },
            optimize = { id, share -> sessionController.optimizePrompt(id, share) },
            replace = { id, text -> sessionController.replacePrompt(id, text) },
        )
```

   `recoveryController` is assigned later in the same `init`; the lambda only *reads* it at call time, so this is safe — but if the compiler rejects the forward reference (`lateinit`/`val` initialisation order), move the `promptOptimizer = ...` block to the **end** of `init`, after `recoveryController` is assigned.

3. Change the `authenticate` lambda passed to `AuthCoordinator` (line 324) from
   `authenticate = { sessionController.authenticate(token) },` to

```kotlin
            authenticate = {
                sessionController.authenticate(token)
                // Every path to an authenticated socket goes through here (handshake,
                // recovery re-auth, withAuth retry), so the wand's availability is
                // always derived from the socket it will actually use.
                promptOptimizer.refreshAvailability()
            },
```

   Because `promptOptimizer` is referenced inside a lambda that only runs later, its declaration order relative to `authCoordinator` does not matter at runtime; if Kotlin's definite-initialisation analysis complains, declare `promptOptimizer` as `private lateinit var` instead of `private val`.

4. In the published-state region, after the `// MARK: - Recovery state (delegated to RecoveryController)` block (after line 268), add:

```kotlin
    // MARK: - Prompt optimizer (delegated to PromptOptimizerController, spec §7.1)

    val optimizerAvailability: StateFlow<OptimizerAvailability> get() = promptOptimizer.availability
    val optimizerState: StateFlow<OptimizerState> get() = promptOptimizer.state
    val optimizerUndo: StateFlow<OptimizerUndo?> get() = promptOptimizer.undo
    val optimizerNotice: StateFlow<String?> get() = promptOptimizer.notice
    /** Tappable now: idle, not recovering, a session is active. */
    val isWandEnabled: Boolean get() = promptOptimizer.isWandEnabled
    /** The relay advertises `prompt_optimizer` on protocol ≥ 2. */
    val isOptimizerAvailable: Boolean get() = promptOptimizer.isAvailable
    /** Hint toast for an unavailable wand, else null. */
    val wandHint: String? get() = promptOptimizer.wandHint

    /** The wand tap (spec §7.1). [shareScreen] is the device's `shareScreenWithOptimizer` setting. */
    suspend fun optimizePrompt(shareScreen: Boolean) = promptOptimizer.optimizePrompt(shareScreen)

    /** The Undo chip tap: one-shot `replace_prompt` of the pre-optimize original. */
    suspend fun undoOptimize() = promptOptimizer.undoOptimize()

    fun dismissOptimizerNotice() = promptOptimizer.dismissNotice()
```

5. In `tearDown()` (line 1362), after `authCoordinator.cancelInFlight()`, add `promptOptimizer.cancel()`.

- [ ] **Step 8: Run the whole core-session suite**

Run: `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :core-session:test 2>&1 | tail -20; echo EXIT=${pipestatus[1]}`
Expected: `BUILD SUCCESSFUL`, `EXIT=0`.

- [ ] **Step 9: Commit**

```bash
git add CodeRelayAndroid/core-session/src/main/kotlin/relay/session/PromptOptimizerController.kt \
        CodeRelayAndroid/core-session/src/test/kotlin/relay/session/PromptOptimizerControllerTest.kt \
        CodeRelayAndroid/core-session/src/main/kotlin/relay/session/SessionCoordinator.kt \
        CodeRelayAndroid/core-session/src/test/kotlin/relay/session/SessionCoordinatorTest.kt \
        CodeRelayAndroid/core-session/src/test/kotlin/relay/session/CoordinatorTestDoubles.kt
git commit -m "feat(android): PromptOptimizerController — wand availability, optimize, 10 s one-shot Undo

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `feature-workspace` — `WandButton` + `OptimizerOverlay` replace the mic slot

**Files:**
- Create: `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WandButton.kt`
- Create: `CodeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/WandButtonLogicTest.kt`
- Delete: `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/MicButton.kt`
- Delete: `CodeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/MicButtonStateTest.kt`
- Modify: `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WorkspaceScreen.kt` (signature :144-172, state collection :181-191, `TerminalColumn` call :284-317, `TerminalColumn` params :515-517, comment :588-589, floating slot :692-702)
- Modify: `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WorkspaceViewModel.kt:72-87` (remove `sendInput(String)`)
- Modify: `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/WorkspaceLogic.kt:52-62` (remove `utteranceInputBytes`)
- Modify: `CodeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/ui/WorkspaceLogicTest.kt` (remove the `utteranceInputBytes` block :75-108 + two imports)
- Modify: `CodeRelayAndroid/feature-workspace/build.gradle.kts:47-52` (drop `:speech`)
- Modify: `CodeRelayLinux/feature-workspace/build.gradle.kts` (:24 header line, :67 main exclusion, :78 test exclusion — drop the MicButton entries)

**Interfaces:**
- Consumes (Task 2, all on `relay.session.SessionCoordinator`): `optimizerAvailability: StateFlow<OptimizerAvailability>`, `optimizerState: StateFlow<OptimizerState>`, `optimizerUndo: StateFlow<OptimizerUndo?>`, `optimizerNotice: StateFlow<String?>`, `suspend fun optimizePrompt(shareScreen: Boolean)`, `suspend fun undoOptimize()`; enums `relay.session.OptimizerAvailability { UNKNOWN, SERVER_TOO_OLD, UNCONFIGURED, AVAILABLE }`, `relay.session.OptimizerState { IDLE, OPTIMIZING }`, `data class relay.session.OptimizerUndo(sessionId: UUID, original: String)`. Consumes (Task 1): `relay.net.OptimizerStrings.OPTIMIZED / UNDO / WAND_LABEL`. `:core-session` declares `api(project(":core-net"))`, so `relay.net.*` resolves from this module without a new dependency (same on Linux: `shared-session` → `api(":shared-net")`).
- Produces (Task 5 relies on these exact names):
  - `WorkspaceScreen(..., shareScreen: Boolean = true, hapticsEnabled: Boolean = false, sidebarToggleRequests..., modifier)` — the `micButton` parameter is **gone**; `shareScreen` takes its position in the parameter list.
  - `object WandButtonLogic { enum class WandVisual { DISABLED, DIMMED, READY, OPTIMIZING }; fun visual(availability, state, hasActiveSession, isRecovering): WandVisual; fun undoChipVisible(undo: OptimizerUndo?, activeSessionId: UUID?): Boolean }`
  - `@Composable fun WandButton(visual: WandButtonLogic.WandVisual, onTap: () -> Unit, modifier: Modifier = Modifier)`
  - `@Composable fun OptimizerOverlay(visual, undoVisible: Boolean, notice: String?, onWandTap: () -> Unit, onUndoTap: () -> Unit, modifier: Modifier = Modifier)`
- Design rulings:
  1. **Tap policy is the controller's, not the button's.** Task 2's `optimizePrompt` already shows `wandHint` when the wand is DIMMED (unavailable), so the DIMMED button is *clickable* and its tap just calls `coordinator.optimizePrompt(shareScreen)` — one code path, no duplicated gating (spec §7.1: "unavailable wand is dimmed but tappable; tap shows the hint"). Only DISABLED (no session / recovering) and OPTIMIZING refuse the click.
  2. **Notice beats chip.** If a notice and an undo are both present (a stale undo from the previous optimize while a new one failed — Task 2 dismisses stale *notices* on start, not stale undos), the overlay shows the notice: it is the newer information and the 4 s toast is shorter than the 10 s undo window, so the chip reappears when the toast expires.
  3. **The undo chip is session-keyed on the render side too** (`undoChipVisible` compares `undo.sessionId` with the active id), matching Task 2's ruling 2. Switching tabs hides it; switching back within 10 s shows it again.
  4. `WandButton.kt` is compiled by the Linux client as well (it lives in `feature-workspace` and is not excluded), so it uses only Compose Multiplatform-portable APIs: `foundation`, `material3`, `material-icons-extended`, `ui`. No `android.*`, no `androidx.compose.ui.tooling.preview` needed. `Icons.Filled.AutoAwesome` is the same glyph the removed `MicButton` used for its "enhanced" state and is available on both platforms.
  5. `:app` no longer compiles after this task (it still references `micButton =` and `MicButtonSlot`). That is expected and fixed in Task 5; this task verifies **only** `:feature-workspace:testDebugUnitTest` plus the Linux `:feature-workspace:test`.

- [ ] **Step 1: Write the failing test**

Create `CodeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/WandButtonLogicTest.kt`:

```kotlin
package relay.feature.workspace

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.feature.workspace.WandButtonLogic.WandVisual
import relay.session.OptimizerAvailability
import relay.session.OptimizerState
import relay.session.OptimizerUndo
import java.util.UUID

/**
 * The wand's pure state → visual mapping (spec §7.1): disabled while optimizing /
 * recovering / with no session, dimmed-but-tappable when the relay lacks the
 * optimizer, and the Undo chip only for the session that was optimized. The
 * Composable rendering itself is compile-only here; these functions are what the
 * overlay reads.
 */
class WandButtonLogicTest {

    private val sessionA = UUID.randomUUID()
    private val sessionB = UUID.randomUUID()

    // MARK: - visual()

    @Test
    fun `ready when available, idle, session active, not recovering`() {
        assertEquals(
            WandVisual.READY,
            WandButtonLogic.visual(OptimizerAvailability.AVAILABLE, OptimizerState.IDLE, hasActiveSession = true, isRecovering = false),
        )
    }

    @Test
    fun `optimizing wins over everything else`() {
        assertEquals(
            WandVisual.OPTIMIZING,
            WandButtonLogic.visual(OptimizerAvailability.UNCONFIGURED, OptimizerState.OPTIMIZING, hasActiveSession = false, isRecovering = true),
        )
    }

    @Test
    fun `disabled with no active session even when available`() {
        assertEquals(
            WandVisual.DISABLED,
            WandButtonLogic.visual(OptimizerAvailability.AVAILABLE, OptimizerState.IDLE, hasActiveSession = false, isRecovering = false),
        )
    }

    @Test
    fun `disabled while recovering even when available`() {
        assertEquals(
            WandVisual.DISABLED,
            WandButtonLogic.visual(OptimizerAvailability.AVAILABLE, OptimizerState.IDLE, hasActiveSession = true, isRecovering = true),
        )
    }

    @Test
    fun `dimmed when the relay is too old`() {
        assertEquals(
            WandVisual.DIMMED,
            WandButtonLogic.visual(OptimizerAvailability.SERVER_TOO_OLD, OptimizerState.IDLE, hasActiveSession = true, isRecovering = false),
        )
    }

    @Test
    fun `dimmed when the relay has no optimizer configured`() {
        assertEquals(
            WandVisual.DIMMED,
            WandButtonLogic.visual(OptimizerAvailability.UNCONFIGURED, OptimizerState.IDLE, hasActiveSession = true, isRecovering = false),
        )
    }

    @Test
    fun `dimmed before the first auth_success (availability unknown)`() {
        // UNKNOWN reads as "not advertised yet" — the tap shows nothing (Task 2's
        // wandHint is null for UNKNOWN), but the button must not claim readiness.
        assertEquals(
            WandVisual.DIMMED,
            WandButtonLogic.visual(OptimizerAvailability.UNKNOWN, OptimizerState.IDLE, hasActiveSession = true, isRecovering = false),
        )
    }

    @Test
    fun `no-session beats dimmed`() {
        // Priority: OPTIMIZING > DISABLED > DIMMED > READY.
        assertEquals(
            WandVisual.DISABLED,
            WandButtonLogic.visual(OptimizerAvailability.SERVER_TOO_OLD, OptimizerState.IDLE, hasActiveSession = false, isRecovering = false),
        )
    }

    // MARK: - undoChipVisible()

    @Test
    fun `chip hidden when there is no undo`() {
        assertFalse(WandButtonLogic.undoChipVisible(null, sessionA))
    }

    @Test
    fun `chip visible for the session that was optimized`() {
        assertTrue(WandButtonLogic.undoChipVisible(OptimizerUndo(sessionA, "original"), sessionA))
    }

    @Test
    fun `chip hidden for a different active session`() {
        assertFalse(WandButtonLogic.undoChipVisible(OptimizerUndo(sessionA, "original"), sessionB))
    }

    @Test
    fun `chip hidden when no session is active`() {
        assertFalse(WandButtonLogic.undoChipVisible(OptimizerUndo(sessionA, "original"), null))
    }

    // MARK: - isTappable()

    @Test
    fun `ready and dimmed are tappable, disabled and optimizing are not`() {
        assertTrue(WandButtonLogic.isTappable(WandVisual.READY))
        assertTrue(WandButtonLogic.isTappable(WandVisual.DIMMED))
        assertFalse(WandButtonLogic.isTappable(WandVisual.DISABLED))
        assertFalse(WandButtonLogic.isTappable(WandVisual.OPTIMIZING))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd CodeRelayAndroid && JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :feature-workspace:testDebugUnitKotlin --tests 'relay.feature.workspace.WandButtonLogicTest' 2>&1 | tail -15; echo EXIT=${pipestatus[1]}`
Expected: compilation FAILS with `Unresolved reference: WandButtonLogic`.

(If the task name is rejected, use `:feature-workspace:testDebugUnitTest --tests 'relay.feature.workspace.WandButtonLogicTest'`; the point is a compile failure, not a green run.)

- [ ] **Step 3: Create `WandButton.kt`**

Create `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WandButton.kt`:

```kotlin
package relay.feature.workspace

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import relay.net.OptimizerStrings
import relay.session.OptimizerAvailability
import relay.session.OptimizerState
import relay.session.OptimizerUndo
import java.util.UUID

/**
 * Pure state → visual mapping for the magic-wand button (spec §7.1). Kept out of
 * the Composables so it is assertable on the JVM; `WandButton` / `OptimizerOverlay`
 * are thin renderers over it, exactly like `WandButton` in CodeRelayClient over
 * `SharedSessionCoordinator`'s optimizer state.
 */
object WandButtonLogic {

    enum class WandVisual {
        /** No session or recovering — greyed out and not clickable. */
        DISABLED,
        /** Relay lacks the optimizer (or hasn't said yet) — dimmed but clickable; the tap shows the hint. */
        DIMMED,
        /** Optimizer advertised, idle — full colour, clickable. */
        READY,
        /** One RPC in flight — spinner, not clickable. */
        OPTIMIZING,
    }

    /** Priority: OPTIMIZING > DISABLED > DIMMED > READY. */
    fun visual(
        availability: OptimizerAvailability,
        state: OptimizerState,
        hasActiveSession: Boolean,
        isRecovering: Boolean,
    ): WandVisual = when {
        state == OptimizerState.OPTIMIZING -> WandVisual.OPTIMIZING
        !hasActiveSession || isRecovering -> WandVisual.DISABLED
        availability != OptimizerAvailability.AVAILABLE -> WandVisual.DIMMED
        else -> WandVisual.READY
    }

    /** The "Optimized · Undo" chip belongs to the session that was optimized, and only while it is active. */
    fun undoChipVisible(undo: OptimizerUndo?, activeSessionId: UUID?): Boolean =
        undo != null && activeSessionId != null && undo.sessionId == activeSessionId

    /** Whether a tap reaches the coordinator. DIMMED is tappable on purpose: the tap is how the user learns why. */
    fun isTappable(visual: WandVisual): Boolean =
        visual == WandVisual.READY || visual == WandVisual.DIMMED
}

/**
 * The 44 dp magic-wand button. Same footprint the mic button had, so it drops
 * into the same bottom-right slot in `TerminalColumn`.
 */
@Composable
fun WandButton(
    visual: WandButtonLogic.WandVisual,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tappable = WandButtonLogic.isTappable(visual)
    val container = when (visual) {
        WandButtonLogic.WandVisual.READY, WandButtonLogic.WandVisual.OPTIMIZING ->
            MaterialTheme.colorScheme.primaryContainer
        WandButtonLogic.WandVisual.DIMMED, WandButtonLogic.WandVisual.DISABLED ->
            Color.Gray.copy(alpha = 0.5f)
    }
    val tint = when (visual) {
        WandButtonLogic.WandVisual.READY -> MaterialTheme.colorScheme.onPrimaryContainer
        WandButtonLogic.WandVisual.DIMMED -> Color.White.copy(alpha = 0.7f)
        WandButtonLogic.WandVisual.DISABLED -> Color.White.copy(alpha = 0.35f)
        WandButtonLogic.WandVisual.OPTIMIZING -> MaterialTheme.colorScheme.onPrimaryContainer
    }
    Box(
        modifier = modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(container)
            .clickable(enabled = tappable, onClick = onTap)
            .semantics { contentDescription = OptimizerStrings.WAND_LABEL },
        contentAlignment = Alignment.Center,
    ) {
        if (visual == WandButtonLogic.WandVisual.OPTIMIZING) {
            CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                strokeWidth = 2.dp,
                color = tint,
            )
        } else {
            Icon(
                imageVector = Icons.Filled.AutoAwesome,
                contentDescription = null, // the Box carries WAND_LABEL
                tint = tint,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

/**
 * The wand plus whatever sits above it: the "Optimized · Undo" chip (10 s, tap =
 * one-shot undo) or the 4 s notice toast. Anchor it bottom-end over the terminal.
 *
 * When both a notice and an undo are present the notice wins — it is the newer
 * information and expires first, after which the chip shows again.
 */
@Composable
fun OptimizerOverlay(
    visual: WandButtonLogic.WandVisual,
    undoVisible: Boolean,
    notice: String?,
    onWandTap: () -> Unit,
    onUndoTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier, horizontalAlignment = Alignment.End) {
        when {
            notice != null -> {
                OptimizerNotice(notice)
                Spacer(Modifier.height(8.dp))
            }
            undoVisible -> {
                UndoChip(onUndoTap)
                Spacer(Modifier.height(8.dp))
            }
        }
        WandButton(visual = visual, onTap = onWandTap)
    }
}

@Composable
private fun UndoChip(onTap: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.inverseSurface)
            .clickable(onClick = onTap)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text(
            text = OptimizerStrings.OPTIMIZED + " · " + OptimizerStrings.UNDO,
            color = MaterialTheme.colorScheme.inverseOnSurface,
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun OptimizerNotice(text: String) {
    Box(
        modifier = Modifier
            .widthIn(max = 320.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.inverseSurface)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text(
            text = text,
            color = MaterialTheme.colorScheme.inverseOnSurface,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}
```

- [ ] **Step 4: Delete the mic button and its test**

```bash
git rm CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/MicButton.kt \
       CodeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/MicButtonStateTest.kt
```

- [ ] **Step 5: Rewire `WorkspaceScreen.kt`**

Five edits, in file order.

**5a — signature (lines 149-156).** Replace the `micButton` parameter and its KDoc:

```kotlin
    /**
     * Speech mic-button slot, placed in the terminal status row. `:app` supplies
     * the real [MicButton] (constructing the device-deferred PTT / continuous
     * engines + the model store) and wires `onUtteranceReady → vm.sendInput(text)`.
     * Defaults to empty so the screen renders without speech (e.g. in previews /
     * before the engines are wired).
     */
    micButton: @Composable () -> Unit = {},
```

with:

```kotlin
    /**
     * `AppSettings.shareScreenWithOptimizer` — sent as `shareScreen` on every
     * `optimize_prompt` the magic-wand button fires (spec §7.1). Defaults to the
     * setting's own default (on) so previews and hosts without the setting behave
     * like a fresh install.
     */
    shareScreen: Boolean = true,
```

Also fix the function KDoc above the signature: the line `* @param onShareQr stubbed in M2; the QR sheet is wired in Task 9` (line 140) stays; if the KDoc mentions `micButton` anywhere else, delete that sentence.

**5b — state collection.** Directly after the line

```kotlin
    val isRecovering by coordinator.isRecovering.collectAsStateWithLifecycle()
```

(line 191) insert:

```kotlin
    // Magic-wand prompt optimizer (spec §7.1). Four StateFlows from the
    // coordinator's PromptOptimizerController, rendered by OptimizerOverlay in the
    // bottom-right slot the mic button used to own.
    val optimizerAvailability by coordinator.optimizerAvailability.collectAsStateWithLifecycle()
    val optimizerState by coordinator.optimizerState.collectAsStateWithLifecycle()
    val optimizerUndo by coordinator.optimizerUndo.collectAsStateWithLifecycle()
    val optimizerNotice by coordinator.optimizerNotice.collectAsStateWithLifecycle()
    val wandVisual = WandButtonLogic.visual(
        availability = optimizerAvailability,
        state = optimizerState,
        hasActiveSession = activeSessionId != null,
        isRecovering = isRecovering,
    )
    val undoVisible = WandButtonLogic.undoChipVisible(optimizerUndo, activeSessionId)
```

**5c — `TerminalColumn` call (lines 315-316).** Replace

```kotlin
                micButton = micButton,
                redrawToken = redrawToken,
```

with

```kotlin
                wandOverlay = {
                    OptimizerOverlay(
                        visual = wandVisual,
                        undoVisible = undoVisible,
                        notice = optimizerNotice,
                        // Same `.light` tap haptic as every other toolbar action.
                        // Gating (unavailable → hint, no session → no-op) lives in
                        // the coordinator; the button only refuses DISABLED/OPTIMIZING.
                        onWandTap = { haptics.lightTap(); scope.launch { coordinator.optimizePrompt(shareScreen) } },
                        onUndoTap = { haptics.lightTap(); scope.launch { coordinator.undoOptimize() } },
                    )
                },
                redrawToken = redrawToken,
```

**5d — `TerminalColumn` parameter (line 516).** Replace

```kotlin
    micButton: @Composable () -> Unit,
```

with

```kotlin
    wandOverlay: @Composable () -> Unit,
```

**5e — the two comments + the floating slot (lines 588-589 and 692-702).** Replace

```kotlin
            // (The speech mic button is NOT here — iOS floats it bottom-right over
            // the terminal; see the floating Box in the terminal body below.)
```

with

```kotlin
            // (The magic-wand button is NOT here — iOS floats it bottom-right over
            // the terminal; see the floating Box in the terminal body below.)
```

and replace

```kotlin
            // Floating mic button, bottom-right over the terminal (iOS
            // ActiveTerminalView floating buttons: 16dp end / 12dp bottom). Always
            // present so the user can enable/disable continuous listening or kick
            // off the model download even with no active session.
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 16.dp, bottom = 12.dp),
            ) {
                micButton()
            }
```

with

```kotlin
            // Floating magic-wand button + its Undo chip / notice, bottom-right over
            // the terminal (iOS ActiveTerminalView floating buttons: 16dp end /
            // 12dp bottom). Always present: with no session it renders DISABLED,
            // and an unavailable optimizer renders DIMMED so a tap can explain why.
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 16.dp, bottom = 12.dp),
            ) {
                wandOverlay()
            }
```

No new imports are needed in `WorkspaceScreen.kt`: `WandButtonLogic` and `OptimizerOverlay` are in the same package, `collectAsStateWithLifecycle` / `launch` / `rememberCoroutineScope` are already imported.

- [ ] **Step 6: Remove the speech text-input path**

**6a — `WorkspaceViewModel.kt` lines 72-87.** Delete the KDoc block starting `/** Text-input overload for the speech pipeline.` through the closing brace of `fun sendInput(text: String)`. Nothing else in the file references `WorkspaceLogic.utteranceInputBytes`; check with `grep -n utteranceInputBytes` (expect no hits in `main/` after 6b).

**6b — `ui/WorkspaceLogic.kt` lines 52-62.** Delete the KDoc starting `/** The blank-skip + UTF-8 encode decision for a speech utterance` and the `fun utteranceInputBytes(text: String): ByteArray?` beneath it. The object's closing `}` stays.

**6c — `ui/WorkspaceLogicTest.kt`.** Delete from the line `// MARK: - utteranceInputBytes (the sendInput(String) overload's core logic)` (line 75) through the last `utteranceInputBytes` test's closing `}` (line 107), leaving the class's closing `}`. Remove the now-unused imports `org.junit.jupiter.api.Assertions.assertArrayEquals` and `org.junit.jupiter.api.Assertions.assertNull`.

- [ ] **Step 7: Drop `:speech` from the module and the Linux exclusion lists**

**7a — `CodeRelayAndroid/feature-workspace/build.gradle.kts` lines 47-52.** Delete:

```kotlin
    // :speech — the MicButton observes the PTT / continuous engine state
    // (SpeechEngineState / ContinuousListeningState) and the SpeechModelStore
    // download progress, and routes onUtteranceReady → terminal input. The engines
    // themselves are constructed by :app and handed down to WorkspaceScreen.
    implementation(project(":speech"))

```

**7b — `CodeRelayLinux/feature-workspace/build.gradle.kts`.** Three edits:
- line 24: delete `//   MicButton.kt             — speech is out of parity scope (spec §1.1)`.
- line 67: `"QrShareSheet.kt", "MicButton.kt",` → `"QrShareSheet.kt",`.
- line 78: delete `"MicButtonStateTest.kt",`.

`WandButton.kt` and `WandButtonLogicTest.kt` are deliberately **not** excluded — the Linux client gets the wand for free from the shared screen, and the pure test runs on both JVMs.

- [ ] **Step 8: Run the module's tests**

Run: `cd CodeRelayAndroid && JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :feature-workspace:testDebugUnitTest 2>&1 | tail -20; echo EXIT=${pipestatus[1]}`
Expected: `BUILD SUCCESSFUL`, `EXIT=0`, `WandButtonLogicTest` green (13 tests), no `MicButtonStateTest`, `WorkspaceLogicTest` still green.

Then confirm the Linux build sees the same sources: `cd ../CodeRelayLinux && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :feature-workspace:test 2>&1 | tail -20; echo EXIT=${pipestatus[1]}`
Expected: `BUILD SUCCESSFUL`, `EXIT=0`. (The Linux `:app` still compiles here because its `WorkspaceScreen(...)` call never passed `micButton`; it picks up `shareScreen`'s default. Task 7 wires the real setting.)

Do **not** run `assembleDebug` or `:app:*` on the Android side yet — `:app` is broken until Task 5 by design (ruling 5).

- [ ] **Step 9: Commit**

```bash
git add CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WandButton.kt \
        CodeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/WandButtonLogicTest.kt \
        CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WorkspaceScreen.kt \
        CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WorkspaceViewModel.kt \
        CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/WorkspaceLogic.kt \
        CodeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/ui/WorkspaceLogicTest.kt \
        CodeRelayAndroid/feature-workspace/build.gradle.kts \
        CodeRelayLinux/feature-workspace/build.gradle.kts
# MicButton.kt / MicButtonStateTest.kt are already staged by `git rm` in Step 4.
git commit -m "feat(android): magic-wand button + Optimized·Undo overlay replace the mic slot

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `feature-settings` + `core-storage` — the share-screen setting, speech-settings scrub, settings screen

**Files:**
- Rewrite: `CodeRelayAndroid/feature-settings/src/main/kotlin/relay/feature/settings/AppSettings.kt` (full file below)
- Rewrite: `CodeRelayAndroid/feature-settings/src/main/kotlin/relay/feature/settings/AppSettingsMigrations.kt` (full file below)
- Rewrite: `CodeRelayAndroid/feature-settings/src/test/kotlin/relay/feature/settings/AppSettingsMigrationsTest.kt` (full file below)
- Delete: `CodeRelayAndroid/feature-settings/src/test/kotlin/relay/feature/settings/BedrockDebounceFlowTest.kt`
- Modify: `CodeRelayAndroid/feature-settings/src/main/kotlin/relay/feature/settings/SettingsScreen.kt` (imports :27, :41; KDoc :46-75; flows :87-111; sections :137-179, :198-212; dialogs :225-249; enum :252-267; `WakeWordDialog` :475-494)
- Modify: `CodeRelayAndroid/feature-settings/build.gradle.kts:46-51`
- Modify: `CodeRelayAndroid/core-storage/src/main/kotlin/relay/storage/TokenStore.kt:8-25, 55-69`
- Modify: `CodeRelayAndroid/core-storage/src/androidTest/kotlin/relay/storage/TokenStoreTest.kt:46-53`
- Rewrite: `CodeRelayLinux/feature-settings/src/main/kotlin/relay/feature/settings/AppSettings.kt` (full file below)
- Modify: `CodeRelayLinux/feature-settings/build.gradle.kts` (dependencies block)
- Modify: `CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt:627-634` (visible sections) and `:783-787` (`AppSettings(...)` construction)

**Interfaces:**
- Consumes (Task 1): `relay.net.OptimizerStrings.SHARE_SCREEN_TOGGLE / SHARE_SCREEN_FOOTER`.
- Produces (Task 5 / Task 7 rely on these exact names, identical on Android and Linux):
  - `AppSettings.shareScreenWithOptimizer: StateFlow<Boolean>` (default `true`), `fun setShareScreenWithOptimizer(value: Boolean)`; DataStore key `shareScreenWithOptimizer` (byte-identical to the iOS `@AppStorage` key).
  - Android `AppSettings(dataStore, tokenStore, scope)` — constructor unchanged; `AppSettings.create(context, scope)` unchanged.
  - Linux `AppSettings(prefs, scope)` — the `tokenStore` parameter is **removed** (its only use was the Bedrock mirror).
  - `enum class SettingsSection { PROMPT_OPTIMIZER, CONNECTION, GENERAL, KEYBOARD_SHORTCUTS, ABOUT }` (`SPEECH` is gone).
  - `TokenStore.deleteBedrockToken()` replaces `saveBedrockToken` / `loadBedrockToken`; `TokenStore.BEDROCK_KEY` stays (it names the entry the scrub removes).
  - `AppSettingsMigrations.REMOVED_SPEECH_KEYS: List<Preferences.Key<*>>`, `AppSettingsMigrations.scrubSpeechKeys(prefs: MutablePreferences)`.
- Removed (nothing may reference these after this task): `smartCleanupEnabled`, `promptEnhancementEnabled`, `bedrockRegion`, `continuousListeningEnabled`, `wakeWord`, `bedrockBearerToken` + their setters, `currentSpeechOptions()`, `AppSettings.BEDROCK_DEBOUNCE_MS`, `AppSettingsMigrations.BedrockMigrationDecision / decideBedrockMigration / shouldScrubLegacyAfterWrite / loadBedrockTokenWithFallback`.
- Design rulings:
  1. **The scrub runs every launch, not once.** It is one DataStore read the shortcut migration already performs plus one idempotent secure-store `remove().commit()`. That is fail-closed by construction — no "done" flag that could be set before the delete lands (the Apple clients needed a flag because they also delete a model directory; Android's models lived inside the `:speech` module's own storage, which uninstalls with the code).
  2. **Key names for the shortcut stay `recordingShortcut*`.** The Apple clients kept them too (CLAUDE.md "Prompt Optimizer (client side)"); only the visible label changes to "Optimizer Shortcut". Nothing on Android or Linux consumes the value today (verified: no reader outside `feature-settings`), so no key handler is added — that is YAGNI, and the setting was already write-only before this plan.
  3. **The toggle gets its own "Prompt Optimizer" section**, matching the iOS `SettingsView` section the Apple plan added, instead of hiding in General. Linux opts into it in `Main.kt` (this task), since the Linux client renders the same wand.
  4. `feature-settings` gains `implementation(project(":core-net"))` (Linux: `implementation(project(":shared-net"))`) purely for `OptimizerStrings`, so the toggle copy is defined once (Global Constraints). It is `implementation`, not `api` — the screen does not expose any `relay.net` type.
  5. The Linux `linux-storage` `TokenStore` keeps `saveBedrockToken` / `loadBedrockToken` — its tests reference them and Plan 4 owns the Linux scrub. Only the Android `core-storage` `TokenStore` changes here.

- [ ] **Step 1: Write the failing tests**

Replace `CodeRelayAndroid/feature-settings/src/test/kotlin/relay/feature/settings/AppSettingsMigrationsTest.kt` with:

```kotlin
package relay.feature.settings

import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.mutablePreferencesOf
import androidx.datastore.preferences.core.stringPreferencesKey
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Pure-JVM tests for the `AppSettings` migrations: the legacy shortcut-modifier
 * mapping ported from `AppSettings.swift`, and the speech-removal scrub (spec §10).
 * The DataStore round-trip + secure-store I/O are instrumented/device tests
 * (DEFERRED — no emulator); the load-bearing logic here is exercised headless.
 */
class AppSettingsMigrationsTest {

    // MARK: - Shortcut-modifier mapping (AppSettings.swift:39-44)

    @Test
    fun `commandShift maps to Meta plus Shift`() {
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.SHIFT,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier("commandShift"),
        )
    }

    @Test
    fun `commandOption maps to Meta plus Alt`() {
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.ALT,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier("commandOption"),
        )
    }

    @Test
    fun `commandControl maps to Meta plus Ctrl`() {
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.CTRL,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier("commandControl"),
        )
    }

    @Test
    fun `unknown legacy modifier falls back to Meta plus Shift (iOS default branch)`() {
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.SHIFT,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier("somethingElse"),
        )
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.SHIFT,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier(""),
        )
    }

    // MARK: - Speech-removal scrub (spec §10)

    @Test
    fun `removed speech keys are exactly the six the speech stack wrote`() {
        // Names are the iOS @AppStorage keys verbatim (they were shared for import
        // round-trips), plus the legacy plaintext Bedrock token key.
        assertEquals(
            listOf(
                "smartCleanupEnabled",
                "promptEnhancementEnabled",
                "bedrockRegion",
                "continuousListeningEnabled",
                "wakeWord",
                "bedrockBearerToken",
            ),
            AppSettingsMigrations.REMOVED_SPEECH_KEYS.map { it.name },
        )
    }

    @Test
    fun `scrub removes every speech key and nothing else`() {
        val prefs = mutablePreferencesOf(
            booleanPreferencesKey("smartCleanupEnabled") to true,
            booleanPreferencesKey("promptEnhancementEnabled") to true,
            stringPreferencesKey("bedrockRegion") to "eu-west-1",
            booleanPreferencesKey("continuousListeningEnabled") to true,
            stringPreferencesKey("wakeWord") to "computer",
            stringPreferencesKey("bedrockBearerToken") to "legacy-plaintext",
            // Survivors:
            booleanPreferencesKey("hapticFeedbackEnabled") to false,
            booleanPreferencesKey("shareScreenWithOptimizer") to false,
            stringPreferencesKey("recordingShortcutKey") to "r",
        )

        AppSettingsMigrations.scrubSpeechKeys(prefs)

        AppSettingsMigrations.REMOVED_SPEECH_KEYS.forEach { key ->
            assertFalse(prefs.contains(key), "expected ${key.name} to be removed")
        }
        assertEquals(false, prefs[booleanPreferencesKey("hapticFeedbackEnabled")])
        assertEquals(false, prefs[booleanPreferencesKey("shareScreenWithOptimizer")])
        assertEquals("r", prefs[stringPreferencesKey("recordingShortcutKey")])
        assertEquals(3, prefs.asMap().size)
    }

    @Test
    fun `scrub is a no-op on a clean store`() {
        val prefs = mutablePreferencesOf(booleanPreferencesKey("autoConnectEnabled") to true)
        AppSettingsMigrations.scrubSpeechKeys(prefs)
        assertTrue(prefs.contains(booleanPreferencesKey("autoConnectEnabled")))
        assertEquals(1, prefs.asMap().size)
    }
}
```

Delete the debounce test, whose subject no longer exists:

```bash
git rm CodeRelayAndroid/feature-settings/src/test/kotlin/relay/feature/settings/BedrockDebounceFlowTest.kt
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd CodeRelayAndroid && JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :feature-settings:testDebugUnitTest --tests 'relay.feature.settings.AppSettingsMigrationsTest' 2>&1 | tail -15; echo EXIT=${pipestatus[1]}`
Expected: compile FAILS with `Unresolved reference: REMOVED_SPEECH_KEYS` / `scrubSpeechKeys`.

`mutablePreferencesOf` comes from `androidx.datastore:datastore-preferences-core`, which `libs.datastore.preferences` pulls in transitively and which is on the unit-test classpath. If — and only if — the compiler reports it unresolved, add `testImplementation("androidx.datastore:datastore-preferences-core:1.1.1")` to the module's `dependencies` (the version matches `datastore = "1.1.1"` in `gradle/libs.versions.toml`).

- [ ] **Step 3: Rewrite `AppSettingsMigrations.kt`**

Replace the whole file with:

```kotlin
package relay.feature.settings

import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey

/**
 * Pure (side-effect-free) pieces of the [AppSettings] startup migrations, factored
 * out so the load-bearing logic is unit-testable on the JVM without DataStore, the
 * EncryptedSharedPreferences-backed `TokenStore`, or an emulator.
 *
 * ## Android-faithfulness note
 *
 * On iOS the shortcut migration moves data written by **older app versions** (a
 * legacy `recordingShortcutModifier` String in `UserDefaults`) into the new Int
 * flags. No shipped Android build ever wrote that key, so on a real device it is a
 * no-op today. It is ported anyway — the same kind of best-effort forward-migration
 * hook the M1 `SavedConnectionStore` carries — so a future backup/restore or
 * cross-platform import that seeds the legacy key migrates identically to iOS.
 *
 * The speech-removal scrub is the opposite case: shipped Android builds up to
 * 0.3-m50 **did** write the speech settings and the Bedrock token, so
 * [REMOVED_SPEECH_KEYS] must stay in place for as long as such installs can update.
 */
object AppSettingsMigrations {

    // MARK: - Shortcut-modifier migration (AppSettings.swift:31-48)

    /**
     * Legacy DataStore/prefs key that held the recording-shortcut modifier as a
     * String (`"commandShift"` / `"commandOption"` / `"commandControl"`) before it
     * became an Int flags bitmask. Matches the iOS `UserDefaults` key.
     */
    const val LEGACY_SHORTCUT_MODIFIER_KEY = "recordingShortcutModifier"

    /**
     * Maps a legacy `recordingShortcutModifier` String to the new
     * [ShortcutFlags] Int, mirroring the iOS `switch` exactly
     * (AppSettings.swift:39-44):
     *  - `"commandShift"`   → Meta + Shift
     *  - `"commandOption"`  → Meta + Alt   (Option)
     *  - `"commandControl"` → Meta + Control
     *  - anything else      → Meta + Shift (the iOS `default` branch)
     *
     * Pure — no I/O — so the mapping is unit-tested directly.
     */
    fun shortcutFlagsForLegacyModifier(legacyRaw: String): Int = when (legacyRaw) {
        "commandShift" -> ShortcutFlags.META or ShortcutFlags.SHIFT
        "commandOption" -> ShortcutFlags.META or ShortcutFlags.ALT
        "commandControl" -> ShortcutFlags.META or ShortcutFlags.CTRL
        else -> ShortcutFlags.META or ShortcutFlags.SHIFT
    }

    // MARK: - Speech-removal scrub (spec §10)

    /**
     * Every DataStore key the removed on-device speech stack wrote. Names are the
     * iOS `@AppStorage` keys verbatim (they were shared so an import could
     * round-trip), plus the legacy plaintext Bedrock token that predates the
     * secure store. `AppSettings` removes them on every launch; the Bedrock
     * credential in the secure store is deleted alongside.
     */
    val REMOVED_SPEECH_KEYS: List<Preferences.Key<*>> = listOf(
        booleanPreferencesKey("smartCleanupEnabled"),
        booleanPreferencesKey("promptEnhancementEnabled"),
        stringPreferencesKey("bedrockRegion"),
        booleanPreferencesKey("continuousListeningEnabled"),
        stringPreferencesKey("wakeWord"),
        stringPreferencesKey("bedrockBearerToken"),
    )

    /** Removes [REMOVED_SPEECH_KEYS] from [prefs]; leaves every other key untouched. */
    fun scrubSpeechKeys(prefs: MutablePreferences) {
        REMOVED_SPEECH_KEYS.forEach { prefs.remove(it) }
    }
}
```

- [ ] **Step 4: Rewrite Android `AppSettings.kt`**

Replace the whole file with:

```kotlin
package relay.feature.settings

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import relay.protocol.SessionNamingTheme
import relay.storage.TokenStore

/**
 * App-wide user settings, ported from `AppSettings.swift`.
 *
 * iOS persists these via SwiftUI `@AppStorage` (UserDefaults). The Android analog
 * is a single Preferences [DataStore] (`app_settings`) holding **exactly the 10
 * keys** the iOS `AppSettings` exposes, each surfaced here as a [StateFlow] plus a
 * `set…` mutator.
 *
 * ## The 10 DataStore keys (defaults match AppSettings.swift)
 *  1. `hapticFeedbackEnabled`      = true
 *  2. `autoConnectEnabled`         = false
 *  3. `lastConnectedServerId`      = ""
 *  4. `sessionNamingTheme`         = gameOfThrones
 *  5. `terminalFontSize`           = 12.0
 *  6. `terminalScrollbackLines`    = 5000
 *  7. `recordingShortcutEnabled`   = true
 *  8. `recordingShortcutFlags`     = Meta+Alt ([ShortcutFlags.DEFAULT])
 *  9. `recordingShortcutKey`       = ""
 * 10. `shareScreenWithOptimizer`   = true   (spec §7.1 — sent as `shareScreen` on every `optimize_prompt`)
 *
 * The speech stack's six keys (`smartCleanupEnabled`, `promptEnhancementEnabled`,
 * `bedrockRegion`, `continuousListeningEnabled`, `wakeWord`, and the legacy
 * plaintext `bedrockBearerToken`) plus the Bedrock credential in the secure
 * [TokenStore] are **scrubbed on every launch** by [removeSpeechSettings]
 * (spec §10) — shipped builds up to 0.3-m50 wrote them.
 *
 * @param scope a long-lived scope (the host injects an application-scoped one);
 *   owns the StateFlow hot mirrors and the startup migrations.
 */
class AppSettings(
    private val dataStore: DataStore<Preferences>,
    private val tokenStore: TokenStore,
    private val scope: CoroutineScope,
) {

    // MARK: - Startup: migrations

    init {
        scope.launch { runMigrations() }
    }

    /**
     * Best-effort forward migrations. The shortcut one is a no-op on any real
     * Android install (see [AppSettingsMigrations]); the speech scrub is not.
     */
    private suspend fun runMigrations() {
        migrateShortcutIfNeeded()
        removeSpeechSettings()
    }

    /**
     * Migrate the legacy `recordingShortcutModifier` String → `recordingShortcutFlags`
     * Int. Mirrors AppSettings.swift:31-48: only migrate when the legacy key is
     * present and the new flags key has not been set, then delete the legacy key.
     */
    private suspend fun migrateShortcutIfNeeded() {
        val prefs = dataStore.data.first()
        val legacy = prefs[LEGACY_SHORTCUT_MODIFIER_KEY] ?: return
        if (prefs.contains(RECORDING_SHORTCUT_FLAGS)) return
        val flags = AppSettingsMigrations.shortcutFlagsForLegacyModifier(legacy)
        dataStore.edit {
            it[RECORDING_SHORTCUT_FLAGS] = flags
            it.remove(LEGACY_SHORTCUT_MODIFIER_KEY)
        }
    }

    /**
     * Speech-removal scrub (spec §10), the Android counterpart of the Apple
     * clients' `SpeechRemovalMigration`. Runs every launch: it is idempotent and
     * cheap (one DataStore read + one secure-store remove), and having no "done"
     * flag means it can never be marked complete before the deletion landed. The
     * secure-store delete is wrapped so a keystore hiccup cannot take startup down.
     */
    private suspend fun removeSpeechSettings() {
        val prefs = dataStore.data.first()
        if (AppSettingsMigrations.REMOVED_SPEECH_KEYS.any { prefs.contains(it) }) {
            dataStore.edit { AppSettingsMigrations.scrubSpeechKeys(it) }
        }
        runCatching { tokenStore.deleteBedrockToken() }
    }

    // MARK: - StateFlow mirrors + setters (the 10 keys)

    val hapticFeedbackEnabled: StateFlow<Boolean> = boolFlow(HAPTIC_FEEDBACK, true)
    fun setHapticFeedbackEnabled(value: Boolean) = put(HAPTIC_FEEDBACK, value)

    val autoConnectEnabled: StateFlow<Boolean> = boolFlow(AUTO_CONNECT, false)
    fun setAutoConnectEnabled(value: Boolean) = put(AUTO_CONNECT, value)

    val lastConnectedServerId: StateFlow<String> = stringFlow(LAST_CONNECTED_SERVER_ID, "")
    fun setLastConnectedServerId(value: String) = put(LAST_CONNECTED_SERVER_ID, value)

    /** Stored as the [SessionNamingTheme.rawValue]; resolves via `fromRaw` (falls back to DEFAULT). */
    val sessionNamingTheme: StateFlow<SessionNamingTheme> =
        dataStore.data
            .map { SessionNamingTheme.fromRaw(it[SESSION_NAMING_THEME] ?: SessionNamingTheme.DEFAULT.rawValue) }
            .stateIn(scope, SharingStarted.Eagerly, SessionNamingTheme.DEFAULT)
    fun setSessionNamingTheme(value: SessionNamingTheme) = put(SESSION_NAMING_THEME, value.rawValue)

    val terminalFontSize: StateFlow<Double> = doubleFlow(TERMINAL_FONT_SIZE, 12.0)
    fun setTerminalFontSize(value: Double) = put(TERMINAL_FONT_SIZE, value)

    val terminalScrollbackLines: StateFlow<Int> = intFlow(TERMINAL_SCROLLBACK_LINES, 5_000)
    fun setTerminalScrollbackLines(value: Int) = put(TERMINAL_SCROLLBACK_LINES, value)

    val recordingShortcutEnabled: StateFlow<Boolean> = boolFlow(RECORDING_SHORTCUT_ENABLED, true)
    fun setRecordingShortcutEnabled(value: Boolean) = put(RECORDING_SHORTCUT_ENABLED, value)

    val recordingShortcutFlags: StateFlow<Int> = intFlow(RECORDING_SHORTCUT_FLAGS, ShortcutFlags.DEFAULT)
    fun setRecordingShortcutFlags(value: Int) = put(RECORDING_SHORTCUT_FLAGS, value)

    val recordingShortcutKey: StateFlow<String> = stringFlow(RECORDING_SHORTCUT_KEY, "")
    fun setRecordingShortcutKey(value: String) = put(RECORDING_SHORTCUT_KEY, value)

    /**
     * Whether `optimize_prompt` may carry the last 40 screen lines (spec §7.1).
     * The device-side gate; the relay has its own (`promptOptimizerShareScreen`).
     */
    val shareScreenWithOptimizer: StateFlow<Boolean> = boolFlow(SHARE_SCREEN_WITH_OPTIMIZER, true)
    fun setShareScreenWithOptimizer(value: Boolean) = put(SHARE_SCREEN_WITH_OPTIMIZER, value)

    // MARK: - DataStore plumbing

    private fun boolFlow(key: Preferences.Key<Boolean>, default: Boolean): StateFlow<Boolean> =
        dataStore.data.map { it[key] ?: default }.stateIn(scope, SharingStarted.Eagerly, default)

    private fun stringFlow(key: Preferences.Key<String>, default: String): StateFlow<String> =
        dataStore.data.map { it[key] ?: default }.stateIn(scope, SharingStarted.Eagerly, default)

    private fun intFlow(key: Preferences.Key<Int>, default: Int): StateFlow<Int> =
        dataStore.data.map { it[key] ?: default }.stateIn(scope, SharingStarted.Eagerly, default)

    private fun doubleFlow(key: Preferences.Key<Double>, default: Double): StateFlow<Double> =
        dataStore.data.map { it[key] ?: default }.stateIn(scope, SharingStarted.Eagerly, default)

    private fun <T> put(key: Preferences.Key<T>, value: T) {
        scope.launch { dataStore.edit { it[key] = value } }
    }

    companion object {
        // The 10 DataStore keys (names match the iOS @AppStorage keys verbatim so
        // a cross-platform import round-trips).
        private val HAPTIC_FEEDBACK = booleanPreferencesKey("hapticFeedbackEnabled")
        private val AUTO_CONNECT = booleanPreferencesKey("autoConnectEnabled")
        private val LAST_CONNECTED_SERVER_ID = stringPreferencesKey("lastConnectedServerId")
        private val SESSION_NAMING_THEME = stringPreferencesKey("sessionNamingTheme")
        private val TERMINAL_FONT_SIZE = doublePreferencesKey("terminalFontSize")
        private val TERMINAL_SCROLLBACK_LINES = intPreferencesKey("terminalScrollbackLines")
        private val RECORDING_SHORTCUT_ENABLED = booleanPreferencesKey("recordingShortcutEnabled")
        private val RECORDING_SHORTCUT_FLAGS = intPreferencesKey("recordingShortcutFlags")
        private val RECORDING_SHORTCUT_KEY = stringPreferencesKey("recordingShortcutKey")
        private val SHARE_SCREEN_WITH_OPTIMIZER = booleanPreferencesKey("shareScreenWithOptimizer")

        // Legacy key read by the shortcut migration only (never written on Android today).
        private val LEGACY_SHORTCUT_MODIFIER_KEY =
            stringPreferencesKey(AppSettingsMigrations.LEGACY_SHORTCUT_MODIFIER_KEY)

        /**
         * Builds the production [AppSettings] from a [Context] + a long-lived
         * [scope]. The DataStore is the single process-wide `app_settings` instance.
         */
        fun create(context: Context, scope: CoroutineScope): AppSettings =
            AppSettings(
                dataStore = context.applicationContext.appSettingsDataStore,
                tokenStore = TokenStore(context.applicationContext),
                scope = scope,
            )
    }
}

/** Single process-wide DataStore instance backing [AppSettings]. */
private val Context.appSettingsDataStore: DataStore<Preferences> by
    preferencesDataStore(name = "app_settings")
```

- [ ] **Step 5: `TokenStore` — replace the Bedrock accessors with `deleteBedrockToken()`**

In `CodeRelayAndroid/core-storage/src/main/kotlin/relay/storage/TokenStore.kt`:

**5a** — class KDoc lines 8-25: replace

```kotlin
/**
 * Encrypted at-rest storage for per-connection authentication tokens and the
 * shared Bedrock bearer token.
 *
 * Ports `AuthManager.swift` (CodeRelayClient). On iOS/macOS those secrets live
 * in the Keychain under service `com.coderemote.relay`, keyed by the connection
 * `UUID` string (the Bedrock token uses the well-known account
 * `com.clauderelay.bedrock.bearerToken`). On Android there is no system Keychain,
 * so we use [EncryptedSharedPreferences] (AES-256 GCM, master key in the Android
 * Keystore / hardware-backed when available) with the **same** logical names:
 *
 * - file/service name: `com.coderemote.relay`
 * - per-connection key: the connection [UUID] string (`UUID.toString()`)
 * - Bedrock token key: `com.clauderelay.bedrock.bearerToken`
 *
 * Keeping the string identities identical to Swift means this store is the
 * single source of truth for those names across the whole product.
 */
```

with

```kotlin
/**
 * Encrypted at-rest storage for per-connection authentication tokens.
 *
 * Ports `AuthManager.swift` (CodeRelayClient). On iOS/macOS those secrets live
 * in the Keychain under service `com.coderemote.relay`, keyed by the connection
 * `UUID` string. On Android there is no system Keychain, so we use
 * [EncryptedSharedPreferences] (AES-256 GCM, master key in the Android
 * Keystore / hardware-backed when available) with the **same** logical names:
 *
 * - file/service name: `com.coderemote.relay`
 * - per-connection key: the connection [UUID] string (`UUID.toString()`)
 *
 * Keeping the string identities identical to Swift means this store is the
 * single source of truth for those names across the whole product.
 *
 * The removed on-device speech stack also kept an AWS Bedrock bearer token here
 * under [BEDROCK_KEY]; [deleteBedrockToken] scrubs it (spec §10) and is the only
 * thing that still touches that entry.
 */
```

**5b** — lines 55-69: replace `saveBedrockToken` + `loadBedrockToken` with

```kotlin
    /**
     * Removes the AWS Bedrock bearer token the speech stack used to store.
     * Idempotent; called on every launch by `AppSettings`' speech-removal scrub.
     */
    fun deleteBedrockToken() {
        // commit() not apply() — see saveToken(); a force-kill must not resurrect it.
        prefs.edit().remove(BEDROCK_KEY).commit()
    }
```

**5c** — companion KDoc for `BEDROCK_KEY` (lines 79-83): replace the KDoc with

```kotlin
        /**
         * Legacy Bedrock bearer token key, kept only so [deleteBedrockToken] can
         * scrub it. Matches the old iOS/macOS Keychain account
         * `com.clauderelay.bedrock.bearerToken`.
         */
```

**5d** — `CodeRelayAndroid/core-storage/src/androidTest/kotlin/relay/storage/TokenStoreTest.kt` lines 46-53: replace the `bedrockEmptyDeletes` test with

```kotlin
    @Test
    fun deleteBedrockTokenIsIdempotent() {
        // Nothing stored → no-op; stored → removed; removed again → still no-op.
        store.deleteBedrockToken()
        store.deleteBedrockToken()
        assertNull(store.loadToken(UUID.randomUUID())) // unrelated entries untouched
    }
```

(`assertEquals` stays imported — the other two tests use it.)

- [ ] **Step 6: `SettingsScreen.kt`**

Six edits, in file order.

**6a — imports.** Delete line 27 `import androidx.compose.material3.OutlinedTextField` and line 41 `import androidx.compose.ui.text.input.PasswordVisualTransformation`. Add `import relay.net.OptimizerStrings` after `import relay.protocol.SessionNamingTheme`.

**6b — KDoc lines 46-75.** Replace with:

```kotlin
/**
 * Settings screen, ported section-for-section from `SettingsView.swift`.
 *
 * Reads/writes through [AppSettings] (DataStore). Each toggle/picker collects its
 * backing [kotlinx.coroutines.flow.StateFlow] and calls the matching `set…`
 * mutator. The five sections mirror the iOS `Form` sections exactly:
 *  1. **Prompt Optimizer** — "Share terminal screen with the optimizer" (spec §7.1).
 *  2. **Connection** — Auto Connect.
 *  3. **General** — Haptic Feedback, Session-Names theme, Terminal Font Size
 *     stepper (8–16), Scrollback picker.
 *  4. **Keyboard Shortcuts** — Optimizer Shortcut toggle + key-capture control.
 *  5. **About** — version/build.
 *
 * @param appVersion app version name (host passes `BuildConfig.VERSION_NAME`)
 * @param buildNumber app version code (host passes `BuildConfig.VERSION_CODE`)
 * @param visibleSections which sections to render. Defaults to all five; a host
 *   without the underlying capability (the Linux desktop client has no hardware
 *   shortcut capture) hides the sections whose toggles would otherwise persist a
 *   value nothing reads.
 * @param hapticFeedbackAvailable whether to show the Haptic Feedback toggle; a
 *   desktop has no vibrator.
 */
```

**6c — flows + Done handler, lines 87-111.** Replace with:

```kotlin
    val shareScreen by settings.shareScreenWithOptimizer.collectAsStateWithLifecycle()
    val autoConnect by settings.autoConnectEnabled.collectAsStateWithLifecycle()
    val haptics by settings.hapticFeedbackEnabled.collectAsStateWithLifecycle()
    val theme by settings.sessionNamingTheme.collectAsStateWithLifecycle()
    val fontSize by settings.terminalFontSize.collectAsStateWithLifecycle()
    val scrollback by settings.terminalScrollbackLines.collectAsStateWithLifecycle()
    val shortcutEnabled by settings.recordingShortcutEnabled.collectAsStateWithLifecycle()
    val shortcutFlags by settings.recordingShortcutFlags.collectAsStateWithLifecycle()
    val shortcutKey by settings.recordingShortcutKey.collectAsStateWithLifecycle()

    // No validation gate any more: the Bedrock "Bearer Key is Required" alert went
    // with the speech stack. Done simply dismisses.
    fun handleDone() = onDone()
```

**6d — sections 1 and 2, lines 137-178** (from `// 1) Speech to Text` through the closing `}` of the Bedrock block). Replace with:

```kotlin
            // 1) Prompt Optimizer (spec §7.1) — the one device-side optimizer setting.
            if (SettingsSection.PROMPT_OPTIMIZER in visibleSections) {
                SectionHeader("Prompt Optimizer")
                ToggleRow(OptimizerStrings.SHARE_SCREEN_TOGGLE, shareScreen, settings::setShareScreenWithOptimizer)
                CaptionText(OptimizerStrings.SHARE_SCREEN_FOOTER)
            }
```

Then renumber the remaining section comments: `// 3) Connection` → `// 2) Connection`, `// 4) General` → `// 3) General`, `// 5) Keyboard Shortcuts` → `// 4) Keyboard Shortcuts`, `// 6) About` → `// 5) About`.

**6e — Keyboard Shortcuts label, line 201.** `ToggleRow("Recording Shortcut", shortcutEnabled, settings::setRecordingShortcutEnabled)` → `ToggleRow("Optimizer Shortcut", shortcutEnabled, settings::setRecordingShortcutEnabled)`.

**6f — dialogs and helpers.** Delete:
- the `showTokenRequired` / `editingWakeWord` state (lines 102-103, already gone with 6c — confirm),
- the `if (showTokenRequired) { AlertDialog(...) }` block (lines 225-237),
- the `if (editingWakeWord) { WakeWordDialog(...) }` block (lines 239-249),
- the `speechFooterText` function and its KDoc (lines 259-267),
- the `// MARK: - Wake-word edit dialog` section with `WakeWordDialog` (lines 475-494).

Replace the `SettingsSection` KDoc + enum (lines 252-257) with:

```kotlin
/**
 * The sections of [SettingsScreen], so a host can hide the ones it has no
 * backing capability for.
 */
enum class SettingsSection { PROMPT_OPTIMIZER, CONNECTION, GENERAL, KEYBOARD_SHORTCUTS, ABOUT }
```

`AlertDialog` is still imported and may now be unused — if the compiler warns, delete the import; the `mutableStateOf` / `remember` / `getValue` / `setValue` imports are still used by the picker rows further down.

- [ ] **Step 7: Module dependencies**

**7a — `CodeRelayAndroid/feature-settings/build.gradle.kts` lines 46-51.** Replace

```kotlin
    // :speech — currentSpeechOptions() returns a SpeechProcessingOptions snapshot
    // for the PTT / continuous engines, so the type is part of this module's API.
    api(project(":speech"))

    // DataStore backs the 14 typed settings keys.
```

with

```kotlin
    // :core-net — OptimizerStrings, so the share-screen toggle's copy is defined once.
    implementation(project(":core-net"))

    // DataStore backs the 10 typed settings keys.
```

**7b — `CodeRelayLinux/feature-settings/build.gradle.kts`.** In `dependencies`, after `api(project(":linux-storage"))` add:

```kotlin
    // OptimizerStrings for the share-screen toggle; same reason as the Android module.
    implementation(project(":shared-net"))
```

- [ ] **Step 8: Rewrite Linux `AppSettings.kt`**

Replace `CodeRelayLinux/feature-settings/src/main/kotlin/relay/feature/settings/AppSettings.kt` with:

```kotlin
package relay.feature.settings

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.StateFlow
import relay.protocol.SessionNamingTheme

/**
 * The 10 persisted app preferences.
 *
 * Linux counterpart of the Android `AppSettings`. **The public API is identical
 * on purpose** — the same `StateFlow` properties and `setX` methods — so the
 * shared `SettingsScreen.kt` (whose only non-portable import is
 * `androidx.lifecycle.compose.collectAsStateWithLifecycle`, which Compose
 * Multiplatform provides under the same package name) compiles against this
 * unchanged.
 *
 * ### Why there are no migrations here
 *
 * The Android class runs two startup steps: a legacy
 * `recordingShortcutModifier` String → flags Int migration, and a scrub of the
 * settings the removed speech stack wrote. Both exist because *older builds of
 * that app* wrote those keys.
 *
 * Linux never shipped the speech stack and no CodeRelay build has ever written
 * a legacy preference on this platform, so there is no legacy data to migrate —
 * by construction, not by assumption. Porting the migration machinery would be
 * dead code that still has to be maintained and can still go wrong.
 * `AppSettingsMigrations` is therefore not compiled into this module.
 *
 * (If settings import from another device is ever added, the migrations become
 * relevant again — and the shared `AppSettingsMigrations` is pure Kotlin, so it
 * can be pulled in at that point without a rewrite.)
 *
 * @param scope retained for API symmetry with the Android class (which owns hot
 *   StateFlow mirrors on it); `PreferenceStore` already has its own.
 */
class AppSettings(
    private val prefs: PreferenceStore,
    @Suppress("unused") private val scope: CoroutineScope,
) {

    // ---- the 10 persisted preferences ----

    /**
     * Retained for API parity with Android so the shared settings screen
     * compiles. There is no haptic hardware on a desktop, so the value is
     * persisted and simply never consulted.
     */
    val hapticFeedbackEnabled: StateFlow<Boolean> = prefs.boolFlow(HAPTIC_FEEDBACK, true)
    fun setHapticFeedbackEnabled(value: Boolean) = prefs.put(HAPTIC_FEEDBACK, value)

    val autoConnectEnabled: StateFlow<Boolean> = prefs.boolFlow(AUTO_CONNECT, false)
    fun setAutoConnectEnabled(value: Boolean) = prefs.put(AUTO_CONNECT, value)

    val lastConnectedServerId: StateFlow<String> = prefs.stringFlow(LAST_CONNECTED_SERVER_ID, "")
    fun setLastConnectedServerId(value: String) = prefs.put(LAST_CONNECTED_SERVER_ID, value)

    val sessionNamingTheme: StateFlow<SessionNamingTheme> =
        prefs.mapped(SESSION_NAMING_THEME) { SessionNamingTheme.fromRaw(it ?: "") }
    fun setSessionNamingTheme(value: SessionNamingTheme) =
        prefs.put(SESSION_NAMING_THEME, value.rawValue)

    val terminalFontSize: StateFlow<Double> = prefs.doubleFlow(TERMINAL_FONT_SIZE, 12.0)
    fun setTerminalFontSize(value: Double) = prefs.put(TERMINAL_FONT_SIZE, value)

    /**
     * Whether the user has chosen a terminal font size at all.
     *
     * Linux-only. The desktop terminal follows the size in the user's own
     * Foot/Alacritty config until a size is set here, so that "12 pt" default
     * must be distinguishable from "12 pt, chosen" — the former means "match
     * my other terminals", the latter means twelve points. Ctrl+Shift+0 clears
     * the choice via [clearTerminalFontSize] and the grid goes back to
     * following the desktop.
     */
    val terminalFontSizeIsSet: StateFlow<Boolean> = prefs.mapped(TERMINAL_FONT_SIZE) { it != null }
    fun clearTerminalFontSize() = prefs.remove(TERMINAL_FONT_SIZE)

    // ---- desktop-only: window geometry ----

    val windowWidth: StateFlow<Int> = prefs.intFlow(WINDOW_WIDTH, 1200)
    val windowHeight: StateFlow<Int> = prefs.intFlow(WINDOW_HEIGHT, 800)
    fun setWindowSize(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        if (width != windowWidth.value) prefs.put(WINDOW_WIDTH, width)
        if (height != windowHeight.value) prefs.put(WINDOW_HEIGHT, height)
    }

    val terminalScrollbackLines: StateFlow<Int> = prefs.intFlow(TERMINAL_SCROLLBACK_LINES, 5_000)
    fun setTerminalScrollbackLines(value: Int) = prefs.put(TERMINAL_SCROLLBACK_LINES, value)

    val recordingShortcutEnabled: StateFlow<Boolean> = prefs.boolFlow(RECORDING_SHORTCUT_ENABLED, true)
    fun setRecordingShortcutEnabled(value: Boolean) = prefs.put(RECORDING_SHORTCUT_ENABLED, value)

    val recordingShortcutFlags: StateFlow<Int> = prefs.intFlow(RECORDING_SHORTCUT_FLAGS, ShortcutFlags.DEFAULT)
    fun setRecordingShortcutFlags(value: Int) = prefs.put(RECORDING_SHORTCUT_FLAGS, value)

    val recordingShortcutKey: StateFlow<String> = prefs.stringFlow(RECORDING_SHORTCUT_KEY, "")
    fun setRecordingShortcutKey(value: String) = prefs.put(RECORDING_SHORTCUT_KEY, value)

    /**
     * Whether `optimize_prompt` may carry the last 40 screen lines (spec §7.1).
     * The device-side gate; the relay has its own (`promptOptimizerShareScreen`).
     */
    val shareScreenWithOptimizer: StateFlow<Boolean> = prefs.boolFlow(SHARE_SCREEN_WITH_OPTIMIZER, true)
    fun setShareScreenWithOptimizer(value: Boolean) = prefs.put(SHARE_SCREEN_WITH_OPTIMIZER, value)

    companion object {
        // Key names match the Android store's exactly, so a settings file moved
        // between platforms is intelligible and a future import path is trivial.
        const val HAPTIC_FEEDBACK = "hapticFeedbackEnabled"
        const val AUTO_CONNECT = "autoConnectEnabled"
        const val LAST_CONNECTED_SERVER_ID = "lastConnectedServerId"
        const val SESSION_NAMING_THEME = "sessionNamingTheme"
        const val TERMINAL_FONT_SIZE = "terminalFontSize"
        const val TERMINAL_SCROLLBACK_LINES = "terminalScrollbackLines"
        const val RECORDING_SHORTCUT_ENABLED = "recordingShortcutEnabled"
        const val RECORDING_SHORTCUT_FLAGS = "recordingShortcutFlags"
        const val RECORDING_SHORTCUT_KEY = "recordingShortcutKey"
        const val SHARE_SCREEN_WITH_OPTIMIZER = "shareScreenWithOptimizer"

        // Desktop-only keys; no Android counterpart.
        const val WINDOW_WIDTH = "windowWidth"
        const val WINDOW_HEIGHT = "windowHeight"
    }
}
```

If any Linux test under `CodeRelayLinux/feature-settings/src/test` referenced `bedrockBearerToken` / `smartCleanupEnabled` (check with `grep -rn "bedrock\|smartCleanup\|wakeWord" CodeRelayLinux/feature-settings/src/test`), delete just those test methods — at the time of writing there are none.

- [ ] **Step 9: Linux `Main.kt` — constructor + visible sections**

In `CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt`:

**9a** — lines 783-787: replace

```kotlin
                settings = AppSettings(
                    prefs = PreferenceStore(scope = scope),
                    tokenStore = tokens,
                    scope = scope,
                ),
```

with

```kotlin
                settings = AppSettings(
                    prefs = PreferenceStore(scope = scope),
                    scope = scope,
                ),
```

(`tokens` is still used by the rest of the environment — do not remove it.)

**9b** — lines 627-634: replace

```kotlin
                            // No speech engine and no recording shortcut on this
                            // platform; their toggles would persist values nothing
                            // reads. Haptics likewise.
                            visibleSections = setOf(
                                SettingsSection.CONNECTION,
                                SettingsSection.GENERAL,
                                SettingsSection.ABOUT,
                            ),
```

with

```kotlin
                            // No hardware-shortcut capture on this platform; its
                            // toggle would persist a value nothing reads. Haptics
                            // likewise. The optimizer section stays: the desktop
                            // renders the same magic-wand button.
                            visibleSections = setOf(
                                SettingsSection.PROMPT_OPTIMIZER,
                                SettingsSection.CONNECTION,
                                SettingsSection.GENERAL,
                                SettingsSection.ABOUT,
                            ),
```

- [ ] **Step 10: Verify both sides**

Android:
```bash
cd CodeRelayAndroid && JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :feature-settings:testDebugUnitTest :core-storage:compileDebugAndroidTestKotlin 2>&1 | tail -20; echo EXIT=${pipestatus[1]}
```
Expected: `BUILD SUCCESSFUL`, `EXIT=0`, `AppSettingsMigrationsTest` green (7 tests), no `BedrockDebounceFlowTest`.

Then grep for stragglers — every one of these must print nothing:
```bash
grep -rn "currentSpeechOptions\|bedrockBearerToken\|setWakeWord\|smartCleanupEnabled\|SettingsSection.SPEECH" CodeRelayAndroid --include='*.kt' | grep -v "/build/" | grep -v "^CodeRelayAndroid/speech/" | grep -v "^CodeRelayAndroid/app/"
```
(`speech/` and `app/` are excluded because Tasks 5 and 6 remove them; anything else is a miss.)

Linux:
```bash
cd ../CodeRelayLinux && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :feature-settings:test :app:compileKotlin 2>&1 | tail -20; echo EXIT=${pipestatus[1]}
```
Expected: `BUILD SUCCESSFUL`, `EXIT=0`.

The Android `:app` module does **not** compile at this point (Task 3's `micButton` removal + this task's `SettingsSection.SPEECH` removal); Task 5 fixes it. Do not run `assembleDebug` yet.

- [ ] **Step 11: Commit**

```bash
git add CodeRelayAndroid/feature-settings/src/main/kotlin/relay/feature/settings/AppSettings.kt \
        CodeRelayAndroid/feature-settings/src/main/kotlin/relay/feature/settings/AppSettingsMigrations.kt \
        CodeRelayAndroid/feature-settings/src/main/kotlin/relay/feature/settings/SettingsScreen.kt \
        CodeRelayAndroid/feature-settings/src/test/kotlin/relay/feature/settings/AppSettingsMigrationsTest.kt \
        CodeRelayAndroid/feature-settings/build.gradle.kts \
        CodeRelayAndroid/core-storage/src/main/kotlin/relay/storage/TokenStore.kt \
        CodeRelayAndroid/core-storage/src/androidTest/kotlin/relay/storage/TokenStoreTest.kt \
        CodeRelayLinux/feature-settings/src/main/kotlin/relay/feature/settings/AppSettings.kt \
        CodeRelayLinux/feature-settings/build.gradle.kts \
        CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt
# BedrockDebounceFlowTest.kt is already staged by `git rm` in Step 1.
git commit -m "feat(android): share-screen optimizer setting; scrub speech settings + Bedrock token on launch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `:app` — drop the speech runtime, wire `shareScreen`, restore `assembleDebug`

**Files:**
- Modify: `CodeRelayAndroid/app/src/main/kotlin/relay/app/CoordinatorFactory.kt:55-105`
- Modify: `CodeRelayAndroid/app/src/main/kotlin/relay/app/RelayNavGraph.kt:154-170, 337-346, 395-405, 448-465`
- Modify: `CodeRelayAndroid/app/src/main/kotlin/relay/app/MainActivity.kt:11-12, 61-70, 110-111, 154`
- Modify: `CodeRelayAndroid/app/src/main/kotlin/relay/app/ConnectionViewModel.kt:87-115`
- Delete: `CodeRelayAndroid/app/src/main/kotlin/relay/app/SpeechSession.kt`, `…/ContinuousListeningService.kt`, `…/SpeechPermissions.kt`
- Modify: `CodeRelayAndroid/app/src/main/AndroidManifest.xml` (speech permission block; `ContinuousListeningService` element)
- Modify: `CodeRelayAndroid/app/build.gradle.kts:73-78, 125-129`
- Modify: `CodeRelayAndroid/app/proguard-rules.pro:83-97`

**Interfaces:**
- Consumes (Task 3): `WorkspaceScreen(vm, onDisconnect, onAttach, onShareQr, shareScreen: Boolean = true, hapticsEnabled, …)` — the `micButton` parameter no longer exists.
- Consumes (Task 4): `AppSettings.shareScreenWithOptimizer: StateFlow<Boolean>`.
- Produces: `ConnectionSession(coordinator, workspaceViewModel, scope)` — the `speech` property is gone; `ConnectionSession.create(context, config, token, settings)` signature unchanged (`settings` still supplies the naming theme).
- Design rulings:
  1. **`POST_NOTIFICATIONS` stays** in the manifest — FCM push (`RelayFirebaseMessagingService`) needs it. Only the four speech entries go (`RECORD_AUDIO`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`, the `android.hardware.microphone` feature).
  2. **No replacement for the speech runtime-permission launcher.** POST_NOTIFICATIONS is already requested elsewhere for push (CLAUDE.md "Push Notifications" — API 33+ runtime request); check `grep -rn POST_NOTIFICATIONS CodeRelayAndroid/app/src/main/kotlin` and leave that path alone.
  3. The generic `-keepclasseswithmembernames class * { native <methods>; }` ProGuard rule **stays** (termlib's JNI needs it); only the ONNX-specific keeps and their comment go.
  4. `:app` compiles again at the end of this task; Task 6 makes `./gradlew test` green by deleting `:speech` itself.

- [ ] **Step 1: `CoordinatorFactory.kt`**

Replace lines 55-105 (from `class ConnectionSession private constructor(` to the end of the file) with:

```kotlin
class ConnectionSession private constructor(
    val coordinator: SessionCoordinator,
    val workspaceViewModel: WorkspaceViewModel,
    val scope: CoroutineScope,
) {
    companion object {
        /**
         * Constructs the coordinator + workspace VM for [config] using [token].
         * [settings] supplies the naming [theme].
         */
        fun create(
            context: Context,
            config: ConnectionConfig,
            token: String,
            settings: AppSettings,
        ): ConnectionSession {
            val appContext = context.applicationContext
            // Serial confined scope — the @MainActor analog.
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val nowMs: () -> Long = { SystemClock.elapsedRealtime() }

            val deviceId = DeviceIdentifier.get(appContext)
            val ownership = SessionOwnershipAdapter(SessionOwnershipStore(appContext, deviceId))

            val connection = RelayConnection()
            val coordinator = SessionCoordinator(
                scope = scope,
                connection = connection,
                token = token,
                ownershipStore = ownership,
                config = config,
                theme = settings.sessionNamingTheme.value,
                nowMs = nowMs,
            )

            val workspaceViewModel = WorkspaceViewModel(
                coordinator = coordinator,
                qualityProvider = { connection.connectionQuality },
                sendBinary = { bytes -> connection.sendBinary(bytes) },
                nowMs = nowMs,
            )

            return ConnectionSession(coordinator, workspaceViewModel, scope)
        }
    }
}
```

- [ ] **Step 2: `RelayNavGraph.kt`**

**2a — splash `onComplete`, lines 158-167.** Replace

```kotlin
                onComplete = {
                    // Best-effort, non-blocking speech-model preload/check (M3 Task 11).
                    // Re-derives model-readiness from disk so a download finished on a
                    // previous launch is reflected; does NOT trigger a download (that is
                    // user-gated behind the mic button's prompt — iOS preload parity).
                    scope.launch { runCatching { preloadSpeechModels(context) } }
                    navController.navigate(Routes.SERVERS) {
                        popUpTo(Routes.SPLASH) { inclusive = true }
                    }
                },
```

with

```kotlin
                onComplete = {
                    navController.navigate(Routes.SERVERS) {
                        popUpTo(Routes.SPLASH) { inclusive = true }
                    }
                },
```

If `scope` / `context` in that composable were used only by the removed line, the compiler will flag them as unused — remove the now-dead `val`s only if they are genuinely unused elsewhere in the same function (lines 150-151 still use `context` for `loadTokenFor`).

**2b — `WorkspaceRoute`, line 346.** After

```kotlin
    val hapticsEnabled by settings.hapticFeedbackEnabled.collectAsStateWithLifecycle()
```

add

```kotlin
    val shareScreen by settings.shareScreenWithOptimizer.collectAsStateWithLifecycle()
```

**2c — `WorkspaceScreen(` call, line 402.** Replace

```kotlin
        micButton = { session.speech.MicButtonSlot(session.workspaceViewModel) },
```

with

```kotlin
        shareScreen = shareScreen,
```

**2d — helper, lines 454-465.** Delete the `preloadSpeechModels` function and its KDoc (from `/**` on line 454 through the closing `}` on line 465). `loadTokenFor` above it stays.

- [ ] **Step 3: `MainActivity.kt`**

- Delete imports on lines 11-12: `androidx.activity.result.ActivityResultLauncher`, `androidx.activity.result.contract.ActivityResultContracts`.
- Delete lines 61-70 (the `speechPermissionLauncher` KDoc + property).
- Delete lines 110-111 (`// Register the speech runtime-permission requester for SpeechSession.` + `SpeechPermissions.requester = { … }`).
- Delete line 154 (`SpeechPermissions.requester = null`) inside `onDestroy`.
- `Log` and `TAG` remain used elsewhere in the file (deep-link logging); if the compiler reports `Log` unused, remove the import — do not remove `TAG`.

- [ ] **Step 4: `ConnectionViewModel.kt`**

Replace lines 87-115 with:

```kotlin
    /** Tears down the current session (cancel recovery, disconnect, cancel scope). */
    suspend fun teardown() {
        _activeSession.value?.let { session ->
            FcmTokenBridge.onTokenRefreshed = null  // don't fire into a dead session
            session.coordinator.tearDown()
            session.scope.cancel()
        }
        _activeSession.value = null
    }

    override fun onCleared() {
        // The Activity is truly finishing (not a fold/config change) — tear the
        // session down. teardown() is suspend, so it needs a live scope. NOT
        // viewModelScope: AndroidX cancels that inside clear() *before* onCleared()
        // runs, so a coroutine launched here would never start (leaking the socket
        // and the recovery loop). The session's OWN scope is still alive at this
        // point, so launch the teardown there and cancel it as the final step.
        val session = _activeSession.value
        _activeSession.value = null
        if (session != null) {
            session.scope.launch {
                session.coordinator.tearDown()
                session.scope.cancel()
            }
        }
        super.onCleared()
    }
```

- [ ] **Step 5: Delete the three speech host files**

```bash
git rm CodeRelayAndroid/app/src/main/kotlin/relay/app/SpeechSession.kt \
       CodeRelayAndroid/app/src/main/kotlin/relay/app/ContinuousListeningService.kt \
       CodeRelayAndroid/app/src/main/kotlin/relay/app/SpeechPermissions.kt
```

Then confirm nothing else in `:app` references them:

```bash
grep -rn "SpeechSession\|SpeechPermissions\|ContinuousListeningService\|relay.speech" CodeRelayAndroid/app/src
```
Expected: no output.

- [ ] **Step 6: `AndroidManifest.xml`**

**6a** — replace the speech permission block

```xml
    <!-- On-device speech (M3 Task 10). RECORD_AUDIO is the dangerous runtime
         permission for mic capture; POST_NOTIFICATIONS (API 33+) is required for the
         continuous-listening foreground-service notification. FOREGROUND_SERVICE +
         FOREGROUND_SERVICE_MICROPHONE back the always-on listening service — the
         documented Android divergence from iOS's foreground-only model. Runtime
         grants for RECORD_AUDIO + POST_NOTIFICATIONS are requested via
         ActivityResultContracts (device-deferred). -->
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
    <uses-feature android:name="android.hardware.microphone" android:required="false" />
```

with

```xml
    <!-- FCM push (F1 Android): POST_NOTIFICATIONS (API 33+) is the runtime permission
         for the agent-activity notifications RelayFirebaseMessagingService posts. -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

**6b** — delete the `ContinuousListeningService` element and its comment:

```xml
        <!-- Continuous-listening foreground service (M3 Task 10). microphone type
             so the OS allows mic capture while foregrounded; not exported (started
             only from within the app via Context.startForegroundService). -->
        <service
            android:name="relay.app.ContinuousListeningService"
            android:exported="false"
            android:foregroundServiceType="microphone" />

```

The `RelayFirebaseMessagingService` element below it stays.

- [ ] **Step 7: `app/build.gradle.kts` + `proguard-rules.pro`**

**7a — `app/build.gradle.kts` lines 74-78.** Replace the release-block comment

```kotlin
            // R8 full-mode: shrink + obfuscate code and shrink resources. The
            // keep rules in proguard-rules.pro protect everything reflection- or
            // JNI-based (kotlinx.serialization, ONNX Runtime, ML Kit, OkHttp,
            // coroutines) from being stripped. proguard-android-optimize.txt is
            // AGP's optimized default ruleset.
```

with

```kotlin
            // R8 full-mode: shrink + obfuscate code and shrink resources. The
            // keep rules in proguard-rules.pro protect everything reflection- or
            // JNI-based (kotlinx.serialization, termlib, ML Kit, OkHttp,
            // coroutines) from being stripped. proguard-android-optimize.txt is
            // AGP's optimized default ruleset.
```

**7b — `app/build.gradle.kts` lines 125-129.** Delete

```kotlin
    // :speech — the SpeechModelStore (splash preload), the ContinuousListeningEngine
    // (foreground service), and the SpeechProcessingOptions snapshot. This is the
    // module that finally packages the ONNX Runtime native libs into the APK (the
    // M3-E concern): :app → :speech → onnxruntime-android AAR → libonnxruntime*.so.
    implementation(project(":speech"))

```

**7c — `proguard-rules.pro` lines 83-94.** Replace

```
# ----------------------------------------------------------------------------
# ONNX Runtime (com.microsoft.onnxruntime → ai.onnxruntime API + JNI)
# ----------------------------------------------------------------------------
# Backs the Silero VAD + Smart-Turn detectors (:speech). The Java API classes
# under ai.onnxruntime.** are bound to native libonnxruntime*.so via JNI; the
# native side looks up Java fields/methods by name, so obfuscation breaks the
# bridge. Keep the API surface and ALL native-method signatures everywhere.
-keep class ai.onnxruntime.** { *; }
-keep class com.microsoft.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**
-dontwarn com.microsoft.onnxruntime.**
# JNI: never rename a class that declares native methods, and keep the methods.
-keepclasseswithmembernames class * {
    native <methods>;
}
```

with

```
# ----------------------------------------------------------------------------
# JNI (generic)
# ----------------------------------------------------------------------------
# Never rename a class that declares native methods, and keep the methods: the
# native side (termlib's libvterm bridge below) looks them up by name.
-keepclasseswithmembernames class * {
    native <methods>;
}
```

- [ ] **Step 8: Verify**

```bash
cd CodeRelayAndroid && JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:compileDebugKotlin :app:assembleDebug 2>&1 | tail -20; echo EXIT=${pipestatus[1]}
```
Expected: `BUILD SUCCESSFUL`, `EXIT=0`. `:speech` still builds as an (unreferenced) module until Task 6 — that is expected.

```bash
grep -rn "speech\|Speech\|RECORD_AUDIO\|onnx" CodeRelayAndroid/app/src CodeRelayAndroid/app/build.gradle.kts CodeRelayAndroid/app/proguard-rules.pro
```
Expected: no output.

- [ ] **Step 9: Commit**

```bash
git add CodeRelayAndroid/app/src/main/kotlin/relay/app/CoordinatorFactory.kt \
        CodeRelayAndroid/app/src/main/kotlin/relay/app/RelayNavGraph.kt \
        CodeRelayAndroid/app/src/main/kotlin/relay/app/MainActivity.kt \
        CodeRelayAndroid/app/src/main/kotlin/relay/app/ConnectionViewModel.kt \
        CodeRelayAndroid/app/src/main/AndroidManifest.xml \
        CodeRelayAndroid/app/build.gradle.kts \
        CodeRelayAndroid/app/proguard-rules.pro
# The three deleted files are already staged by `git rm` in Step 5.
git commit -m "feat(android): host the wand; drop the speech runtime, mic permissions and foreground service

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Delete the `:speech` module, the ML conversion tooling and the ONNX dependency

**Files:**
- Delete (tracked, `git rm -r`): `CodeRelayAndroid/speech/` (module: `build.gradle.kts`, `src/main/kotlin/relay/speech/**`, `src/test/kotlin/relay/speech/**`), `CodeRelayAndroid/ml/` (`_common.py`, `convert_logmel.py`, `convert_silero.py`, `convert_smartturn.py`, `validate_parity.py`, `README.md`, `out/.gitignore`), `tools/speech/convert_smart_turn.py`
- Modify: `CodeRelayAndroid/settings.gradle.kts:29`
- Modify: `CodeRelayAndroid/gradle/libs.versions.toml:24-30, 76-78`

**Interfaces:** none produced. After this task no file under `CodeRelayAndroid/` or `CodeRelayLinux/` may reference `relay.speech`, `:speech`, `onnxruntime`, or `ml/`.

- Design rulings:
  1. `ml/out/` is a git-ignored build output directory whose only tracked file is its own `.gitignore`; `git rm -r CodeRelayAndroid/ml` removes the tracked file, and any untracked `.onnx` outputs on the developer's disk are left alone (do **not** `rm -rf` — the plan never deletes untracked files).
  2. `tools/speech/` goes too: its single script is the CoreML→ONNX converter for the Smart-Turn model the deleted module consumed.
  3. The `mockk` / `turbine` / `junit5` entries in the version catalog stay — other modules use them. Only the two `onnxruntime` entries go.

- [ ] **Step 1: Remove the module and tooling**

```bash
git rm -r CodeRelayAndroid/speech CodeRelayAndroid/ml tools/speech
```
Expected: 53 files removed from the index (`git status --short | grep -c '^D'` → `53`).

- [ ] **Step 2: `settings.gradle.kts`**

Delete line 29: `include(":speech")`. The remaining `include(...)` lines are `core-protocol, core-net, core-storage, core-session, terminal, feature-servers, feature-workspace, feature-settings, app`.

- [ ] **Step 3: `gradle/libs.versions.toml`**

**3a — `[versions]`, lines 24-30.** Delete

```toml
# ONNX Runtime Mobile — the AAR backing the GATED M3-E Silero VAD + Smart-Turn
# detectors. Plain Maven AAR (no CMake/NDK native build). The detectors compile
# against this API now; they only run once ml/validate_parity.py converts the
# CoreML source models to ONNX and M4's parity gate passes. 1.20.0 is the chosen
# stable release (1.22.0 is latest; 1.20.0 has a mature mobile API and resolves
# cleanly on Maven Central).
onnxruntime = "1.20.0"

```

**3b — `[libraries]`, lines 76-78.** Delete

```toml
# ONNX Runtime Mobile (Android AAR) — backs the gated Silero VAD + Smart-Turn
# ONNX detectors (M3-E). See the [versions] note for the gating rationale.
onnxruntime-android = { module = "com.microsoft.onnxruntime:onnxruntime-android", version.ref = "onnxruntime" }

```

- [ ] **Step 4: Verify — the full Android CI trio plus the Linux build**

```bash
cd CodeRelayAndroid && export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
./gradlew test testDebugUnitTest --no-daemon 2>&1 | tail -20; echo EXIT=${pipestatus[1]}
./gradlew :core-storage:compileDebugAndroidTestKotlin --no-daemon 2>&1 | tail -5; echo EXIT=${pipestatus[1]}
./gradlew assembleDebug --no-daemon 2>&1 | tail -5; echo EXIT=${pipestatus[1]}
./gradlew :app:assembleRelease --no-daemon 2>&1 | tail -5; echo EXIT=${pipestatus[1]}
```
Expected: four `BUILD SUCCESSFUL`, four `EXIT=0`. (`assembleRelease` proves the trimmed ProGuard rules still minify cleanly; the APK is debug-signed without `keystore.properties`, which is fine.)

```bash
cd ../CodeRelayLinux && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew test 2>&1 | tail -10; echo EXIT=${pipestatus[1]}
```
Expected: `BUILD SUCCESSFUL`, `EXIT=0`.

Straggler grep — must print nothing:

```bash
grep -rn -i "relay\.speech\|:speech\|onnxruntime\|SpeechProcessingOptions\|MicButton" CodeRelayAndroid CodeRelayLinux --include='*.kt' --include='*.kts' --include='*.toml' --include='*.xml' --include='*.pro' | grep -v "/build/"
```

- [ ] **Step 5: Commit**

```bash
git add CodeRelayAndroid/settings.gradle.kts CodeRelayAndroid/gradle/libs.versions.toml
# The 53 removed files are already staged by `git rm -r` in Step 1.
git commit -m "chore(android): remove the on-device speech module, ML conversion tooling and ONNX Runtime

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Linux `shareScreen` wiring + documentation

**Files:**
- Modify: `CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt:194-197` (collect the flow) and `:568-580` (`WorkspaceScreen(` call)
- Modify: `CodeRelayAndroid/RELEASE.md:12-14, 126-134, 154-186`
- Modify: `README.md:16, 42, 382`
- Modify: `docs/android-parity-audit.md` (banner + §2, §3, §4 haptics row, §5, §6, §7)
- Modify: `docs/linux-client-spec.md:22-25, 172, 424, 463-464`
- Modify: `CLAUDE.md` "Prompt Optimizer (client side)" paragraph (ends line ~261)

**Interfaces:**
- Consumes (Task 3): `WorkspaceScreen(shareScreen: Boolean = true, …)`. Consumes (Task 4): Linux `AppSettings.shareScreenWithOptimizer`.
- Produces: nothing code-facing. This is the last task; after it every client (iOS, macOS, Android, Linux) sends the device-side `shareScreen` flag from its own setting.

- Design rulings:
  1. **The Linux wand is live after this task** because the shared `WorkspaceScreen` already renders it (Task 3) and the Linux `SessionCoordinator` is the shared one (Task 2). Plan 4 is therefore reduced to Linux-specific items (keyboard accelerator for the wand, Linux `TokenStore` Bedrock scrub, spec text); this task must not pull those in.
  2. `docs/android-parity-audit.md` is a **dated audit** (2026-06-09). It is not rewritten into a new audit; it gets a dated status banner and the rows/sections that now describe *removed* functionality are marked as such, the same way the Apple-side Plan 2 annotated it. Historical "PASS" verdicts on the deleted speech code stay as history.
  3. `docs/linux-client-spec.md` §1.1 keeps speech as a non-goal, restated in present tense: the Android stack is gone, so there is nothing to inherit.

- [ ] **Step 1: Linux `Main.kt` — pass the setting to the workspace**

**1a** — after line 197 (`val scrollbackLines by settings.terminalScrollbackLines.collectAsState()`) add:

```kotlin
    val shareScreen by settings.shareScreenWithOptimizer.collectAsState()
```

**1b** — in the `WorkspaceScreen(` call (lines 568-580), after

```kotlin
                            onShareQr = { id -> shareSessionId = id },
```

add

```kotlin
                            // The device-side gate on sending the last 40 screen lines
                            // with optimize_prompt (spec §7.1); the relay has its own.
                            shareScreen = shareScreen,
```

Verify:

```bash
cd CodeRelayLinux && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew test 2>&1 | tail -10; echo EXIT=${pipestatus[1]}
```
Expected: `BUILD SUCCESSFUL`, `EXIT=0`.

- [ ] **Step 2: `CodeRelayAndroid/RELEASE.md`**

**2a — lines 12-14.** Replace

```markdown
- `app/proguard-rules.pro` — R8 keep rules for kotlinx.serialization, ONNX
  Runtime (JNI), OkHttp/Okio, ML Kit / CameraX, and coroutines. **Do not weaken
  these without re-verifying on a device** (see the runtime caveat below).
```

with

```markdown
- `app/proguard-rules.pro` — R8 keep rules for kotlinx.serialization, termlib
  (JNI), OkHttp/Okio, ML Kit / CameraX, and coroutines. **Do not weaken these
  without re-verifying on a device** (see the runtime caveat below).
```

**2b — line 131.** Replace `- on-device speech (exercises the ONNX Runtime JNI bridge),` with `- a terminal session (exercises the termlib libvterm JNI bridge),`.

**2c — Data Safety table, line 159.** Delete the `**Microphone / audio**` row entirely. The table keeps the Camera and Personal rows.

**2d — lines 163-168 ("Declare:").** Replace

```markdown
- **On-device processing** for mic + camera (no off-device transmission).
- Data is **not** required to be collected (the app's core is a terminal relay;
  speech + QR are optional conveniences).
```

with

```markdown
- **On-device processing** for the camera (no off-device transmission).
- Data is **not** required to be collected (the app's core is a terminal relay;
  QR scanning is an optional convenience).
- The **prompt optimizer** sends the draft you typed at the agent's input line —
  and, if "Share terminal screen with the optimizer" is on (the default), the
  last 40 lines of the terminal screen — to *your own relay*, which forwards them
  to the model provider the relay operator configured. Nothing goes to a
  third party the user did not set up; the setting is per device.
```

**2e — lines 170-174 (the `> Note:` block).** Replace `(mic on-device, camera on-device, no` with `(camera on-device, optimizer traffic goes only to the user's relay, no`.

**2f — §7 Permissions rationale, lines 178-185.** Replace

```markdown
The app requests:
- `RECORD_AUDIO` — on-device voice input (push-to-talk + continuous listening).
  Requested at first use; the app is fully usable by typing if denied.
- `CAMERA` — scanning a QR code to add a server connection. Requested at first
  use of the QR scanner; servers can always be added manually if denied.

Both are user-initiated, on-device only, and have graceful no-permission paths.
Document this in the listing and in the in-app permission rationale prompts.
```

with

```markdown
The app requests:
- `CAMERA` — scanning a QR code to add a server connection. Requested at first
  use of the QR scanner; servers can always be added manually if denied.
- `POST_NOTIFICATIONS` (API 33+) — agent-activity push notifications. The app is
  fully usable without them.

Both are user-initiated and have graceful no-permission paths. Voice input is the
keyboard's own dictation; the app no longer requests the microphone. Document this
in the listing and in the in-app permission rationale prompts.
```

- [ ] **Step 3: `README.md`**

- Line 16: replace `session tabs, recovery, and on-device speech (in test-build distribution; see [CodeRelayAndroid](CodeRelayAndroid/))` with `session tabs, recovery, and the prompt-optimizer wand (in test-build distribution; see [CodeRelayAndroid](CodeRelayAndroid/))`.
- Line 42: replace `a real VT100 terminal via ConnectBot \`termlib\`, and an on-device speech pipeline)` with `a real VT100 terminal via ConnectBot \`termlib\`, and the same prompt-optimizer wand as the Apple clients)`.
- Line 382: delete the tree line `│   ├── speech/                 # Android on-device speech pipeline (Whisper/LLM)`.

- [ ] **Step 4: `docs/android-parity-audit.md`**

**4a** — after the `**Method:** …` paragraph (ends line 7), insert:

```markdown
> **Status update 2026-09-15.** Every speech-related row below is history. The
> on-device speech stack (`:speech`, `ml/`, the mic button, `RECORD_AUDIO`, the
> continuous-listening foreground service, the Bedrock token) was removed from the
> Android client in the same change that gave it the server-side prompt-optimizer
> wand, matching the Apple clients (`docs/superpowers/plans/2026-09-15-server-prompt-optimizer-plan3-android.md`).
> §2's Speech/Bedrock rows are now "removed on both sides", §3 describes deleted
> code, and the speech items in §5–§7 are moot. The rest of the audit stands.
```

**4b — §2 table, lines 49-50.** Change both `| **PASS** |` cells to `| **Removed** (2026-09, Plan 3) |`. Line 43's heading `## 2. Settings parity — 14 \`@AppStorage\` keys + Bedrock token (= 15 persisted)` → `## 2. Settings parity — 10 DataStore keys (was 14 + Bedrock token before 2026-09)`. Line 53 (Keyboard Shortcuts row): `recording-shortcut toggle` → `"Optimizer Shortcut" toggle`.

**4c — §2 paragraph, lines 56-62.** Replace with:

```markdown
The shortcut-modifier string→flags migration is still ported. The Bedrock→secure-store
migration is gone on both platforms: the Apple clients' `SpeechRemovalMigration` and
Android's `AppSettings.removeSpeechSettings()` (every launch, idempotent) *delete* the
Bedrock secret and the six speech settings instead. Android adds one key,
`shareScreenWithOptimizer` (default on), byte-identical to the iOS `@AppStorage` key.
```

**4d — §3, line 66.** Replace the `**Note:**` line with `**Note:** iOS/macOS removed on-device speech in 2026-09; Android followed in Plan 3 the same month. Every row below describes code that no longer exists and is kept as a record of what the port verified.`

**4e — §4 haptics row, line 97.** `~11 iOS sites wired (mic, keyboard, toggles, tabs)` → `~11 iOS sites wired (wand, keyboard, toggles, tabs)`.

**4f — §5.** Delete the whole `### Needs a Mac with \`coremltools\` + reference fixtures` subsection (lines 105-110). In `### Needs the Android NDK + CMake …` delete the two speech bullets (lines 113-117), leaving the heading only if another bullet remains — there is none, so delete the heading too (lines 112-117). Under `### Needs a device/emulator …` delete `- **Transcription CER audit vs iOS** (≤0.5% target).` (line 125) and `- **End-to-end speech→terminal, foreground-service notification, model downloads.**` (line 131). Under `### Needs human credentials`, line 135: `data-safety form (mic/camera = on-device only)` → `data-safety form (camera = on-device only; optimizer traffic goes to the user's own relay)`. Under `### Carry-forwards …` delete the `- **LOW iOS-parity gaps (M3, Swift has them too):** …` bullet (lines 143-144).

**4g — §6 table.** Delete the `Continuous listening uses a **foreground service + persistent notification**` row (line 150) and the `Wake-word \`WakeWordSession\` omits the 2.5s accumulator cap` row (line 154).

**4h — §7.** Line 162: `(wire protocol, recovery, TLS gate, speech state machine, Metaphone)` → `(wire protocol, recovery, TLS gate)`. Line 164: `**Public-launch readiness: BLOCKED on §5** — the ONNX parity gate, JNI inference, real terminal, on-device acceptance, and the Play release` → `**Public-launch readiness: BLOCKED on §5** — on-device acceptance and the Play release`.

(Line numbers in 4f-4h are pre-edit; apply from the bottom of the file upward, or re-grep after each deletion.)

- [ ] **Step 5: `docs/linux-client-spec.md`**

- Lines 22-25 (§1.1 first bullet). Replace with:
  ```markdown
  - **On-device speech.** None. The Android speech stack was removed in 2026-09 in
    favour of the relay-side prompt optimizer (the wand in the shared
    `WorkspaceScreen`), so there is nothing to inherit. Voice input is the desktop's
    own dictation into the terminal.
  ```
- Line 172: the `ContinuousListeningService` row's last cell `Speech is out of scope (§1.1)` → `Removed from Android too (§1.1)`.
- Line 424: `| On-device speech / wake word | **Deferred** | Inherited from Android (§1.1) |` → `| On-device speech / wake word | **N/A** | Removed everywhere; the wand replaces it (§1.1) |`.
- Lines 463-464: delete the two speech items (`whisper.cpp / llama.cpp inference` and `Silero VAD / SmartTurn ONNX detectors`) and renumber the camera item to `1.`.

- [ ] **Step 6: `CLAUDE.md`**

In "Prompt Optimizer (client side)", after the sentence ending `…the model directory once per install.` append:

```markdown
The Android and Linux clients share the same shape in Kotlin: `WandButton` /
`OptimizerOverlay` in `feature-workspace`, the four optimizer StateFlows on
`relay.session.SessionCoordinator`, `relay.net.OptimizerStrings`, and a
`shareScreenWithOptimizer` DataStore/preference key. Android's `:speech` module,
`ml/` tooling and `RECORD_AUDIO` permission are gone; `AppSettings.removeSpeechSettings()`
scrubs the six speech keys and the Bedrock token on every launch (idempotent, no flag).
```

- [ ] **Step 7: Final straggler sweep and commit**

```bash
grep -rn -i "on-device speech\|record_audio\|onnx\|wake.word\|whisperkit\|continuous.listening" README.md CLAUDE.md CodeRelayAndroid/RELEASE.md docs/linux-client-spec.md | grep -v "removed\|Removed\|gone\|no longer\|history\|deleted\|None\."
```
Expected: no output (every remaining mention is a past-tense removal note).

```bash
git add CodeRelayLinux/app/src/main/kotlin/relay/app/Main.kt \
        CodeRelayAndroid/RELEASE.md README.md docs/android-parity-audit.md \
        docs/linux-client-spec.md CLAUDE.md
git commit -m "docs(android,linux): wand replaces speech in the Android docs; Linux passes shareScreen to the workspace

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Out of scope (Plan 4 — Linux)

- A keyboard accelerator for the wand (Ctrl+Shift+O or similar) dispatched at the `Window`.
- Scrubbing the Linux `linux-storage` `TokenStore` Bedrock entry (`saveBedrockToken` / `loadBedrockToken` stay until then).
- Linux-specific spec text beyond the §1.1 restatement above.
