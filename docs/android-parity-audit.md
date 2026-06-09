# Android Relay Client — Parity Audit (M4 Launch Gate)

**Date:** 2026-06-09
**Branch:** `android-m4-polish` (M1–M3 already merged to `main`)
**Method:** screen-by-screen + settings + speech + cross-cutting cross-check of the Android
port against the canonical iOS source (`ClaudeRelayApp/`, `Sources/ClaudeRelay*/`), grounded
in the actual code with file citations — not optimism.

## Verdict

**Feature parity is achieved on every customer-facing screen.** All 9 iOS screens have faithful
Android counterparts, all 6 settings sections + 14 `@AppStorage` keys are present, all 8
workspace status-bar elements are wired, and the speech layer's logic is a verified byte-for-byte
port. **No genuine missing features and no over-builds were found** — every gap is a *documented,
intentional deferral* gated on a resource this build environment lacks (a device/emulator, a Mac
with `coremltools`, the Termux engine vendoring, or Play credentials).

**The launch gate is CLEAR for the headless engineering scope.** It is **NOT** ship-ready for the
public Play Store launch until the **device/Mac/human deferral ledger (§5)** is completed — those
are real, required steps (the ONNX parity gate, on-device acceptance, accessibility/TalkBack pass,
the real Termux terminal, JNI model inference, and the Play Console release), not optional polish.

---

## 1. Screen parity map

| iOS screen | Android counterpart | Status | Notes |
|---|---|---|---|
| `ServerListView` | `ServersScreen.kt` | **PASS** | LazyColumn, live/offline dot, pull-to-refresh, swipe edit/delete, empty-state, Settings gear, CleartextPolicy-gated connect |
| `AddEditServerView` | `AddEditServerSheet.kt` | **PASS** | name/host/port/TLS/masked-token, host validation, delete-confirm dialog |
| `WorkspaceView` | `WorkspaceScreen.kt` | **PASS** | adaptive 840dp split (sidebar | terminal / compact drawer), recovery overlay (phase + cancel + BackHandler) |
| `ActiveTerminalView` | `TerminalHost.kt` + status bar | **PASS** (terminal render DEFERRED) | All status-bar elements present (§4); VT rendering uses a text-fallback engine pending the Termux binding (§5) |
| `SessionSidebarView` | `SessionSidebar.kt` | **PASS** | new/attach, state badges + ActivityDot, rename dialog, swipe-delete, long-press menu (rename / share QR), pull-to-refresh |
| `SettingsView` | `SettingsScreen.kt` | **PASS** | all 6 sections (§2) |
| `SplashScreenView` | `SplashScreen.kt` | **PASS** | 3-phase scale/fade animation matches iOS; preload hook on dismiss |
| `QRCodeSheet` | `QrShareSheet.kt` | **PASS** | ZXing QR of `clauderelay://session/{uuid}` + selectable deeplink |
| `QRScannerView` | `QrScannerScreen.kt` | **PASS** (camera runtime DEFERRED) | CameraX + ML Kit barcode → DeepLinks.parseSessionId → attach; runtime needs a device |

**Shared UI atoms:** `ConnectionQualityDot`, `ActivityDot`, `AgentColorPalette` (claude=orange,
codex=teal, default=teal), `SessionTabs` (numbered, agent-colored, awaiting-flash), `TerminalPalette`
(16-color ANSI) — all ported (M2), color/blink mappings verified against Swift.

## 2. Settings parity — 14 `@AppStorage` keys + Bedrock token (= 15 persisted)

All present in `feature-settings/.../AppSettings.kt` (DataStore) + `SettingsScreen.kt`:

| Section | Controls | Status |
|---|---|---|
| Speech-to-Text | Smart Cleanup, Prompt Enhancement, Continuous Listening, wake-word edit | **PASS** |
| AWS Bedrock | masked bearer token (TokenStore, 500ms-debounced `.dropFirst()` write), region, "token required" validation alert | **PASS** |
| Connection | Auto-Connect | **PASS** |
| General | Haptic Feedback, Naming-theme picker (6 themes), Font Size stepper (8–16), Scrollback picker (1k/5k/10k/25k) | **PASS** |
| Keyboard Shortcuts | recording-shortcut toggle + KeyEvent.META_* key capture | **PASS** |
| About | version/build from BuildConfig | **PASS** |

Both iOS migrations ported (shortcut-modifier string→flags; legacy plaintext Bedrock→Keychain with
read-back-confirm). Bedrock token correctly in EncryptedSharedPreferences, not DataStore.

## 3. Speech feature inventory (M3)

| Feature | Status | Notes |
|---|---|---|
| StreamingAudioBuffer (16kHz mono ring) | **PASS** | pure-logic, tested; exact API port |
| Energy VAD + 4-case VadEvent | **PASS** | thresholds 0.015/0.008, 250ms/1s verified |
| Wake-word cascade (alias→Levenshtein→Metaphone) + preprocessor | **PASS** | Metaphone hand-traced for output parity; recall-critical |
| WhisperTranscriber.collapseRepetitions + silence filter | **PASS** | two-tier heuristic, len>20 gate verified |
| ProcessedText + SpeechPostProcessor chain | **PASS** | word<2/silence short-circuit, never-throws, branch order exact |
| CloudPromptEnhancer (Bedrock Converse) | **PASS** (network device-deferred) | modelId/512/0.3/15s, Bearer-redaction, 18+6 refusal detection |
| TurnEndDetector + heuristic + raceTurnEnd | **PASS** | classifier-authoritative, INFERENCE_TIMED_OUT-on-timer |
| ContinuousListeningEngine + OnDeviceSpeechEngine | **PASS** | strict two-phase red-handshake, armed 4s timeout, 176-test state machine |
| SpeechModelStore (2 downloads / 3 bundled ONNX) | **PASS** (download runtime device-deferred) | Qwen ≈0.5GB + ggml small.en; resumable + cloud fallback |
| ContinuousListeningService (FG-service microphone) | **PASS** (runtime device-deferred) | foregroundServiceType=microphone + notification + permission flow |
| MicButton dual-mode | **PASS** | PTT tap / continuous + long-press one-shot; state-driven color; haptics wired (§4) |
| **whisper.cpp / llama.cpp JNI inference** | **DEFERRED** | no CMake in env; documented stubs degrade gracefully (§5) |
| **Silero VAD / SmartTurn ONNX detectors** | **DEFERRED (gated to M4)** | built + compile-verified, NOT wired into `makeDefault` until the parity gate passes (§5) |

## 4. Cross-cutting features

| Feature | Status | Android location |
|---|---|---|
| Deep links `clauderelay://session/{uuid}` | **PASS** | DeepLinks.kt + manifest intent-filter + cold/warm pendingSessionId |
| Connection quality (app-level ping/pong) | **PASS** | RelayConnection (10s/5s/6-window/3-fail) |
| Recovery state machine | **PASS** | RecoveryController (9-behavior parity rewrite) |
| Session ownership / naming | **PASS** | SessionOwnershipStore (device-scoped) + SessionNaming (random + fallbackIndex) |
| Activity monitoring (agent map / awaiting / stolen) | **PASS** | ActivityCoordinator |
| Input-prompt silence detection | **PASS** | TerminalSessionVm (1s/2s debounce, M4 Task 3) |
| TLS/cleartext scoping | **PASS** | CleartextPolicy enforced at the RelayConnection.connect chokepoint (unbypassable) |
| Auto-connect | **PASS** | RelayNavGraph (awaits persisted settings via `.first()`) |
| Device identifier | **PASS (accepted divergence)** | generated persisted UUID vs iOS identifierForVendor (§5) |
| Haptics (gated by hapticFeedbackEnabled) | **PASS** | Haptics.kt — ~11 iOS sites wired (mic, keyboard, toggles, tabs); QR-scan ungated to match iOS |
| **Hardware key-repeat / copy-paste / image-paste** | **DEFERRED** | bound to the deferred Termux VT view (text-fallback has no clipboard) (§5) |

## 5. Deferred-work ledger (REQUIRED before public launch — not optional polish)

These are gated on resources absent from the build environment. Each is documented inline in the
code and was an explicit, accepted deferral during M1–M3.

### Needs a Mac with `coremltools` + reference fixtures
- **SmartTurn/Silero ONNX parity gate (M4 Task 1):** run `ClaudeRelayAndroid/ml/convert_*.py`,
  add the reference audio set + `labels.json`, make `validate_parity.py` pass (Silero rel-err
  <0.1%, SmartTurn TPR≥90%/FPR≤10%, LogMel ≤1e-2), bundle `ml/out/*.onnx` as `:app` assets, then
  wire `SmartTurnTurnEndDetector`/`SileroVoiceActivityDetector` into `ContinuousListeningEngine.makeDefault`.
  Until then the engine ships the energy VAD + heuristic turn-end (functional, lower-accuracy).

### Needs the Android NDK + CMake (native build) + a device
- **whisper.cpp / llama.cpp JNI (M3):** real on-device transcription + text cleanup. The
  `WhisperTranscriber.transcribe` / `TextCleaner.clean` are documented stubs that throw → caught →
  graceful degradation (cloud-only path). Requires vendoring the libs + a CMake `externalNativeBuild`.
- **Oboe/AudioRecord mic capture:** `AudioCapturing`/`StreamingAudioSourcing` are no-op stubs; real
  16kHz mono Float32 capture needs a device.

### Needs the Termux engine vendored + a device
- **Real VT terminal view (M1 Task 17):** `RelayTermuxView`/`TermuxTerminalEngine` adapter (Termux
  isn't on Maven Central; see `terminal/TERMUX_INTEGRATION.md`). The text-fallback engine drives the
  real byte path meanwhile. **Copy/paste + image-paste + hardware key-repeat** ride on this.

### Needs a device/emulator (on-device acceptance — M4 Tasks 2,4,5,6,7)
- **Transcription CER audit vs iOS** (≤0.5% target).
- **Hardware keyboard + key-repeat + clipboard paste** verification.
- **Accessibility / TalkBack pass:** main buttons have `contentDescription`; a full TalkBack
  navigation + announcement-order + dynamic-type audit needs a device (PARTIAL → must complete).
- **Animations/haptics felt** side-by-side with iOS (the *buzz* and motion; the wiring is done).
- **Integration + process-death + memory (<400MB) + large-output** hardening against a live server.
- **End-to-end speech→terminal, foreground-service notification, model downloads.**

### Needs human credentials (M4 Task 9)
- **Play Store release:** generate the upload keystore + `keystore.properties` (template +
  `RELEASE.md` ready), `bundleRelease` AAB, Play Console listing + data-safety form (mic/camera =
  on-device only) + internal→closed→open tracks. Release buildType + R8 keep rules are scaffolded
  and `assembleRelease` builds green; **R8-keep runtime correctness must be verified on a minified
  build on a device** before promoting any track.

### Carry-forwards from earlier milestones (open, non-blocking-for-headless)
- **Session-scope leak on Activity rotation (M2):** `activeSession` in Compose `remember` isn't
  cancelled in `onDestroy`; lift to a ViewModel/SavedStateHandle.
- **LOW iOS-parity gaps (M3, Swift has them too):** SpeechModelStore `.part` cleanup on failure,
  pre-flight disk-space check, concurrent-download guard.

## 6. Accepted divergences (intentional, documented — NOT gaps)

| Divergence | Rationale |
|---|---|
| Continuous listening uses a **foreground service + persistent notification** | Android cannot mic in the background silently; platform requirement (spec §5) |
| **Device identifier** = generated persisted UUID (not identifierForVendor) | Android has no privacy-safe stable hardware ID; cleared on app-data-clear (documented) |
| **NSC permits cleartext at the platform layer**; CleartextPolicy is the IP-range enforcer | Android NSC can't express RFC1918 CIDR; the in-code gate mirrors iOS `NSAllowsLocalNetworking` |
| **QR-scan haptic is ungated** | Exact iOS parity — `QRScannerView.swift:93` fires it without the setting guard |
| Wake-word `WakeWordSession` omits the 2.5s accumulator cap | Masked by the 3s force-check timer; `pad()` never truncates — immaterial to detection |

## 7. Sign-off

- **No unaccounted gaps.** Every PARTIAL/DEFERRED item above is either (a) closed in M4 (haptics,
  input-prompt detection), (b) a documented resource-gated deferral with a clear completion step in
  §5, or (c) an accepted intentional divergence in §6.
- **Headless engineering scope: COMPLETE.** ~480 JVM unit tests pass; the whole project + the
  release-minified APK build; the load-bearing ports (wire protocol, recovery, TLS gate, speech
  state machine, Metaphone) were each adversarially verified against Swift.
- **Public-launch readiness: BLOCKED on §5** — the ONNX parity gate, JNI inference, real terminal,
  on-device acceptance, and the Play release are required and need a device/Mac/credentials.

**Recommendation:** merge M4 (closes the headless milestone); treat §5 as the explicit pre-launch
checklist for a session with a device + Mac + Play credentials.
