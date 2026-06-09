# Android Relay Client — M4: Parity Validation, Polish & Launch

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. **Depends on M1–M3.**
>
> **⚠️ Read `docs/superpowers/plans/2026-06-08-android-relay-client-corrections.md` first.** M4-relevant: the <400 MB memory target was reasoned against a mis-sized "~2.4 GB Qwen" — the real model is ≈0.5 GB (A6), so revisit the target (it should be easier to hit; confirm the real peak). The input-prompt debounce (Task 3) values **1000 ms / 2000 ms** are confirmed-correct (§D). The parity audit (Task 8) must cross-check the corrected settings count (14+1) and the per-op coordinator sequences.

**Goal:** Reach 100% feature parity and ship-quality polish: enable the SmartTurn turn-end classifier once it passes the parity gate, complete accessibility/haptics/animations, harden edge cases, run a full parity audit against iOS, and prepare the Play Store release.

**Architecture:** No new modules — this milestone enables the gated M3 work, fills polish gaps, and validates. The deliverable is a public-launch-ready app.

**Swift source of truth:** the whole iOS app — M4 is a parity audit, so cross-check against `ClaudeRelayApp/` and `Sources/ClaudeRelay*/` broadly.

---

## Task 1: Pass the SmartTurn/LogMel parity gate and enable the classifier

**Files:**
- Modify: `speech/src/main/kotlin/relay/speech/ContinuousListeningEngine.kt` (`makeDefault`)
- Use: `ml/validate_parity.py` (from M3 Task 9)

> This is the gate the spec defined: do not enable SmartTurn until numeric parity passes.

- [ ] **Step 1: Run the parity validation** on the reference audio set: `python ml/validate_parity.py`. Confirm Silero rel-error < 0.1%, SmartTurn TPR ≥ 90% / FPR ≤ 10%, LogMel within tolerance. Save the report to `ml/out/parity_report.md`.
- [ ] **Step 2: If the gate passes**, change `ContinuousListeningEngine.makeDefault` to wire `SmartTurnTurnEndDetector` (with `HeuristicTurnEndDetector` fallback on load failure). **If it fails**, keep the heuristic, document the gap in `parity_report.md`, and file a follow-up — do NOT ship a degraded classifier silently.
- [ ] **Step 3: A/B verify on device** — record 20 utterances with natural mid-sentence pauses; confirm SmartTurn does NOT cut off mid-thought and DOES finalize promptly at true end. Compare against iOS on the same phrases.
- [ ] **Step 4: Commit** `feat(speech): enable SmartTurn turn-end after parity gate passes`

---

## Task 2: Transcription + cleanup parity audit vs iOS

**Files:**
- Create: `ml/transcription_parity.py` (or a Kotlin instrumented test harness)

> Spec success metric: ≤0.5% CER vs iOS.

- [ ] **Step 1:** Build a fixed reference audio set (reuse `Tests/ClaudeRelaySpeechTests/Fixtures` — same repo, direct path — if usable). Transcribe on Android (whisper.cpp) and compare to iOS transcripts; compute CER.
- [ ] **Step 2:** Run the same transcripts through `TextCleaner` on both platforms; spot-check cleanup quality parity.
- [ ] **Step 3:** Record results; if CER > 0.5%, investigate quantization/weights mismatch before launch.
- [ ] **Step 4: Commit** `test(speech): transcription + cleanup parity audit`

---

## Task 3: Input-prompt detection wired into TerminalSessionVm

**Files:**
- Modify: `terminal/src/main/kotlin/relay/terminal/TerminalSessionVm.kt`
- Test: `terminal/src/test/kotlin/relay/terminal/InputPromptTest.kt`

> Deferred from M1 to keep that task focused. Port the `detectInputPrompt` debounce (1000ms normal / 2000ms agent-active) feeding `awaitingInput` → tab attention-flash. Pure logic with a virtual clock → unit-testable.

- [ ] **Step 1: Write the failing test**

```kotlin
@Test fun `marks awaiting input after silence threshold`() = runTest {
    val vm = TerminalSessionVm(normalSilenceMs = 1000, agentSilenceMs = 2000)
    var awaiting = false; vm.onAwaitingInputChanged = { awaiting = it }
    vm.terminalReady(); vm.receiveOutput("$ ".toByteArray())
    advanceTimeBy(1001); assertTrue(awaiting)
}
@Test fun `new output cancels pending and clears awaiting`() = runTest {
    val vm = TerminalSessionVm(normalSilenceMs = 1000, agentSilenceMs = 2000)
    var awaiting = false; vm.onAwaitingInputChanged = { awaiting = it }
    vm.terminalReady(); vm.receiveOutput("x".toByteArray()); advanceTimeBy(1001)
    vm.receiveOutput("y".toByteArray()); assertFalse(awaiting)
}
@Test fun `agent-active uses 2s threshold`() = runTest { /* set isAgentActive=true; 1.5s -> not awaiting; 2.1s -> awaiting */ }
```

- [ ] **Step 2–4:** add a coroutine `delay` + `Job` cancel debounce to `TerminalSessionVm` (inject a `CoroutineScope`/clock for tests); `isAgentActive` flag selects the threshold; cancel on each `receiveOutput`.
- [ ] **Step 5: Commit** `feat(terminal): input-prompt silence detection`

---

## Task 4: Hardware keyboard + key-repeat + copy/paste verification

**Files:**
- Modify: `terminal/.../RelayTerminalView.kt`

> The spec flagged the iOS Obj-C runtime hooks as NOT needed on Android, but mandated explicit testing of key-repeat + paste.

- [ ] **Step 1:** Implement hardware-key handling via `onKeyEvent` + `KeyEvent.META_*` (Ctrl/Alt/Shift combos → control bytes). Detect hardware keyboard (`InputDevice`) to hide the soft-keyboard toggle (the `GCKeyboard` analog).
- [ ] **Step 2: Manual verify on a device with a physical keyboard:** hold Backspace → continuous repeat (no cutoff); Ctrl+C/V/X work; clipboard text paste sends UTF-8 bytes; image paste → PNG base64 → `paste_image`.
- [ ] **Step 3: Commit** `feat(terminal): hardware keyboard, key-repeat, copy/paste`

---

## Task 5: Animations, haptics, splash polish

**Files:** `feature-workspace/*`, `feature-servers/*`, `app/.../SplashScreen.kt`

> Port the iOS motion + haptics: splash scale-in/fade sequence; quality-dot + activity-dot blinking (`rememberInfiniteTransition`); tab attention-flash; `HapticFeedback`/`VibrationEffect` on button taps + speech events (success/warning). Manual verification.

- [ ] **Step 1:** Splash animation sequence (logo scale 0.6→1.0, text fade, full fade-out) matching `SplashScreenView.swift` timings.
- [ ] **Step 2:** Blinking dots + tab flash via infinite transitions.
- [ ] **Step 3:** Haptics gated by the `hapticFeedbackEnabled` setting; `VIBRATE` permission.
- [ ] **Step 4: Manual verify** against the iOS app side-by-side.
- [ ] **Step 5: Commit** `feat(ui): animations, haptics, splash polish`

---

## Task 6: Accessibility pass

**Files:** across `:feature-*`

> Use the `swift-accessibility` analog for Android: content descriptions, TalkBack labels, touch-target sizes, dynamic font scaling, focus order. Terminal output exposed to TalkBack where feasible.

- [ ] **Step 1:** Add `contentDescription`/`semantics` to all interactive elements (mic button states, dots, tabs, swipe actions).
- [ ] **Step 2:** Verify with TalkBack: navigate servers → connect → terminal → settings; ensure mic-button state changes are announced.
- [ ] **Step 3:** Respect system font scale; verify layouts don't clip at large scale.
- [ ] **Step 4: Commit** `feat(a11y): TalkBack labels, touch targets, dynamic type`

---

## Task 7: Edge-case hardening + integration test pass

**Files:** tests across modules

> Close the gaps the iOS code lacked tests for and harden reconnection/edge cases.

- [ ] **Step 1: Integration test (instrumented, against the dev server):** full flow — connect, create 3 sessions, switch (assert single-paint replay), rename, kill server mid-session → recovery → restart server → reconnect → sessions restored.
- [ ] **Step 2: Process-death restore:** kill the app process while attached; relaunch → ownership store restores names/owned/agents; auto-connect (if on) reconnects.
- [ ] **Step 3: Memory:** profile peak memory with speech models loaded (target < 400 MB; note the Qwen is ≈0.5 GB on disk, much smaller than the "~2.4 GB" the target was originally reasoned against — re-baseline against the real loaded footprint); confirm `onTrimMemory` unloads the cleanup LLM.
- [ ] **Step 4: Large output:** stream a huge file (`cat bigfile`) → confirm the 4MB pending cap drops oldest without crashing and the live terminal stays responsive.
- [ ] **Step 5: Commit** `test: edge-case hardening + integration pass`

---

## Task 8: Full parity audit against iOS (the M4 gate)

**Files:** Create `docs/android-parity-audit.md`

> Walk the spec's complete feature inventory and the iOS app screen-by-screen; check every item off on Android. This is the launch gate.

- [ ] **Step 1:** For every entry in the spec's "screen parity map" and "Settings parity" + the subagent feature inventory, verify the Android behavior matches. Record PASS/GAP per item in `docs/android-parity-audit.md`.
- [ ] **Step 2:** For each GAP, either fix it or document an explicit, accepted divergence (e.g., the foreground-service notification, the device-id stability) with rationale.
- [ ] **Step 3:** Sign-off: parity audit shows no unaccepted gaps.
- [ ] **Step 4: Commit** `docs: android parity audit (launch gate)`

---

## Task 9: Release engineering — signing, Play Store, closed → open track

**Files:** `app/build.gradle.kts` (release signing, R8), Play Console assets

- [ ] **Step 1:** Configure release signing (upload key in keystore, NOT committed), R8/ProGuard rules (keep kotlinx.serialization + JNI symbols), versionName/versionCode.
- [ ] **Step 2:** Build a release AAB: `./gradlew :app:bundleRelease`; verify it installs and runs.
- [ ] **Step 3:** Play Console: app listing, screenshots (phone + tablet), data-safety form (mic, camera, on-device processing), permissions rationale. Internal → closed → open testing tracks (mirrors the iOS TestFlight cadence).
- [ ] **Step 4:** Ship to closed beta; collect feedback; promote to production after the parity audit + beta sign-off.
- [ ] **Step 5: Commit** `chore(release): signing config + Play Store release setup`

---

## M4 Self-Review Checklist

- [ ] SmartTurn enabled only after the parity gate passed (Task 1) — or heuristic retained + gap documented.
- [ ] Transcription CER ≤ 0.5% vs iOS (Task 2).
- [ ] Input-prompt detection ported + tested (Task 3).
- [ ] Hardware keyboard, key-repeat, copy/paste verified (Task 4).
- [ ] Animations + haptics + splash match iOS (Task 5).
- [ ] Accessibility: TalkBack + dynamic type (Task 6).
- [ ] Integration + process-death + memory + large-output hardening (Task 7).
- [ ] **Parity audit shows no unaccepted gaps (Task 8) — the launch gate.**
- [ ] Release AAB builds + Play tracks configured (Task 9).
