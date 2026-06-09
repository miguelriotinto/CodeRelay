# Android Relay Client — Source-Fidelity Corrections (verification pass)

**Date:** 2026-06-08
**Status:** Authoritative — supersedes the spec/plan text it corrects
**Method:** 16 parallel auditors read the canonical Swift source slice-by-slice; every
CRITICAL/HIGH discrepancy was re-checked by an independent adversarial refuter; the
highest-risk items (settings count, session naming, recovery state machine) were then
hand-confirmed against source. **95 claims CONFIRMED, ~20 corrected.**

> **For agentic workers:** read this file alongside the spec and the M1–M4 plans.
> Where this file and an older doc disagree, **this file wins** — it is grounded in
> quoted source. The inline fixes have been applied to the spec/plans, but this file
> is the single place that explains *why* each change was made, with source citations.

The Android port's correctness is defined by fidelity to the Swift source
(`Sources/ClaudeRelay*/`, `ClaudeRelayApp/`). Every correction below cites the exact
file:line that is the source of truth.

---

## A. CRITICAL / HIGH — must fix before implementing the affected task

### A1. ServerMessage has **19** type strings, not 18 — total is **31**, not 30
- **Source:** `Sources/ClaudeRelayKit/Protocol/ServerMessage.swift:5-23` declares 19 cases;
  `:53-60` lists 19 `allTypeStrings`. `ClientMessage.swift` has 12. **12 + 19 = 31.**
- **Wrong in:** spec §2 ("30 unique type strings — 12 client, 18 server"); M1 Task 5 test
  `assertEquals(18, ServerMessage.ALL_TYPE_STRINGS.size)` and the test name
  `all 18 server type strings present`.
- **Note:** the M1 `ServerMessage.kt` *code block* already correctly lists all 19 data
  classes/objects and 19 `ALL_TYPE_STRINGS` — so the shipped impl yields 19 and the
  `assertEquals(18, …)` test would **fail**. The bug is only in the prose + assertion.
- **Fix:** "31 unique type strings — 12 client, 19 server"; assert `19` and rename the test.

### A2. AppSettings has **14** `@AppStorage` keys, not 18
- **Source:** `ClaudeRelayApp/Models/AppSettings.swift:112-145` — exactly 14 `@AppStorage`
  properties (verified `grep -c '@AppStorage'` = 14). `bedrockBearerToken` is `@Published`
  and Keychain-backed (`:121`), **not** `@AppStorage`. `bedrockRegion` and
  `lastConnectedServerId` **are** `@AppStorage`.
- **The 14 keys (with defaults):** `smartCleanupEnabled=true`,
  `promptEnhancementEnabled=false`, `bedrockRegion="us-east-1"`,
  `hapticFeedbackEnabled=true`, `autoConnectEnabled=false`, `lastConnectedServerId=""`,
  `sessionNamingTheme=.gameOfThrones`, `terminalFontSize=12.0`,
  `terminalScrollbackLines=5000`, `recordingShortcutEnabled=true`,
  `recordingShortcutFlags=[command,option]`, `recordingShortcutKey=""`,
  `continuousListeningEnabled=false`, `wakeWord="claude"`.
- **Plus:** `bedrockBearerToken` (Keychain) = **15 persisted preferences total.**
- **Wrong in:** spec §6 ("18 @AppStorage keys"); M2 Task 10 ("all 18 keys"); M2 checklist
  ("All 18 settings persist").
- **Fix:** "14 `@AppStorage` keys + 1 Keychain-backed token = 15 persisted preferences."
- **Porting notes the count change surfaces:**
  - There are **two iOS migrations** to port (M2 Task 10): `migrateShortcutIfNeeded`
    (old `recordingShortcutModifier` string → `recordingShortcutFlags` Int) and
    `migrateBedrockTokenIfNeeded` (legacy UserDefaults `bedrockBearerToken` →
    Keychain, with read-back-confirm-before-delete + plaintext fallback). See A2-mig.
  - The Bedrock debounce is **500 ms with `.dropFirst()`** (`AppSettings.swift:18-24`):
    the initial seed of the field must NOT trigger a write. Port the `.dropFirst()`.

### A3. SessionNaming: **random** pick + explicit `fallbackIndex` (not "first unused" / `used.size+1`)
- **Source:** `Sources/ClaudeRelayClient/Helpers/SessionNaming.swift:157-164`:
  ```swift
  public static func pickDefaultName(usedNames: Set<String>, theme: SessionNamingTheme,
                                     fallbackIndex: Int) -> String {
      let available = theme.names.filter { !usedNames.contains($0) }
      return available.randomElement() ?? "Session \(fallbackIndex)"
  }
  ```
- **Wrong in:** M2 Task 1 (`pick(theme, used)` returning the "first unused pool entry";
  fallback `"Session ${used.size + 1}"`).
- **Fix:** port the full signature `pickDefaultName(usedNames, theme, fallbackIndex)`;
  use `available.randomElement()`; fallback `"Session $fallbackIndex"`. "First unused"
  would make names sequential/deterministic (UX divergence); `used.size+1` produces a
  different number than iOS when the caller tracks an independent counter.
- **Theme enum (`:8-16`):** 6 cases. Persisted raw values are **camelCase** and must be
  pinned via `@SerialName` (Kotlin constants may be SCREAMING_SNAKE):
  `gameOfThrones, viking, starWars, dune, lordOfTheRings, starTrek`. Default
  `gameOfThrones`. Name pools (`:42-144`) are large (≈70 each) — port verbatim.

### A4. RecoveryController — multiple load-bearing behaviors missing from the M2 port
Source: `Sources/ClaudeRelayClient/ViewModels/RecoveryController.swift`. **CONFIRMED:**
backoff `[0,1,2,4,8,15]s` (`:176`); 3-auto-failure suspend, only auto counts, user resets
(`:47,224-233,128-129`); `isRecoveryDispatched` vs `isRecovering` two-guard split;
generation captured + re-checked at every await; phases `reconnecting/authenticating/resuming`
(`SharedSessionCoordinator.swift:58-59`); final failure → `connectionTimedOut`. **But the
port is WRONG/INCOMPLETE on:**

1. **Probe timeout is 5 s, not ~2 s.** `isAlive()` → `measurePingRTT()` → `performPing()`
   uses `waitForPong(timeout: .seconds(5))` (`RelayConnection.swift:313`). Spec §3 says
   "~2 s" — wrong. The Kotlin `isAlive` lambda must wrap a **5 s** pong wait.
2. **Auth/resume failure is TERMINAL, not re-looped.** Swift retries only the *reconnect*
   across the backoff array; a successful reconnect whose `restoreSession` (auth/resume)
   fails calls `recordAutoRecoveryOutcome(success:false)` **once and returns**
   (`:202-206, 272`) — it does NOT re-run the 6-step backoff. The M2 Kotlin `continue`s the
   loop on auth/resume failure, so it would retry the full chain up to 6× before counting a
   single failure → the breaker trips far later than iOS. **Fix:** reconnect failure retries
   the backoff; reconnect-success-then-auth/resume-failure is terminal (count once, return).
3. **App-level vs transport-level restore error split — MISSING.** An
   `isApplicationLevelError` (e.g. session gone) sets `sessionAttachFailed`, does NOT set
   `connectionTimedOut`, **but still counts toward the breaker** (`:258-272`). Port this branch.
4. **3 s auto-recovery cooldown — MISSING.** `scheduleAutoRecovery` drops auto-recoveries
   within 3 s of the last one ending (`:43,94-98`). The Kotlin lacks the gate **and** its
   `finally` stamps `lastRecoveryEndedAt = 0L` — must stamp **now** (inject a monotonic clock).
5. **`resetAutoRecoveryBreaker()` on healthy ping — MISSING.** A successful keepalive ping
   while suspended clears the breaker (`:69-74`, wired to `onHealthyPing`). This is a 4th
   reset trigger beyond the user signals. Add it.
6. **`cancel()` semantics — MISSING.** `cancel()` sets `autoRecoverySuspended = true` +
   `recoveryFailed = true` + stamps `lastCancelledAt` + bumps generation (`:286-299`), so a
   user cancel does not immediately re-enter auto-recovery.
7. **`lastCancelledAt` 1 s debounce on `triggerUserRecovery` — MISSING.** Ignores user
   recovery within 1 s of a cancel (`:56-58,124-127`) to avoid sheet-dismiss→ON_RESUME loops.
8. **`suppressAllViewModelSends(true/false)` — MISSING.** Toggled on at recovery start, off
   in the inner `defer` (`:165,168`). Inject a `suppressSends(Boolean)` lambda.
9. **`isRecovering` set on the wrong side of the probe — DRIFT.** Swift sets
   `isRecovering = true` only **after** `isAlive()` returns false (`:164`); the alive
   short-circuit never flips it. The Kotlin sets it at the top of `runRecovery` before the
   probe → UI flashes a recovery state on a healthy foreground refresh. Defer it.

> RecoveryController is the highest-risk port in the project. Treat M2 Task 3 as
> **rewrite, not transcription**: re-derive each method from the Swift source with the
> nine points above wired in, and extend the test suite to cover cooldown, healthy-ping
> reset, cancel-suspends-breaker, cancel-debounce, and "auth-fail is terminal."

### A5. SharedSessionCoordinator — the four session ops are **distinct sequences**, not one
- **Source:** `SharedSessionCoordinator.swift`. The spec/M2 present one shared
  "detach→act→claim→wire→active→touch→enforceLimit→fetch" sequence. The real ops differ:
  - **CREATE** (`createNewSession`, `:392-412`): `withAuth { detach?; createSession }`
    → `claimSession` → `wireTerminalOutput` (**after** the RPC) → set active → touch →
    enforceLimit → fetch.
  - **SWITCH** (`switchToSession`, `:433-458`): `prepareForSwitch(prev)` →
    `beginReplay(incoming)` → **`wireTerminalOutput` BEFORE** `withAuth { detach; resume }`
    (comment `:433-434`: "wire output BEFORE resumeSession so binary replay frames are
    routed to the correct VM from the start") → set active → touch → enforceLimit → fetch.
    **No `claim`.**
  - **ATTACH** (`attachRemoteSession`, `:477-522`): `withAuth { detach?; attachSession }`
    → `claimSession` → `vm.beginReplay()` → `wireTerminalOutput` (after) → active → touch →
    enforceLimit → names → fetch, **with previous-session rollback on failure** (`:510-514`).
  - **TERMINATE** (`terminateSession`, `:568-578`): `connection.send(.sessionTerminate)` →
    clear active → `evictTerminal` → `forgetSession` (activity) → `unclaimSession` → remove
    name+title → fetch. (forget **before** unclaim.)
- **Eager-wiring claim (spec §3) applies to SWITCH only.** For create/attach the wiring is
  *after* the RPC. The Android port must preserve **switch's** wire-before-resume ordering
  specifically, or replay frames get dropped/misrouted.
- **Fix:** M2 Task 6 must specify the four sequences separately (above) and call out the
  switch-only eager wiring + the attach rollback.

### A6. `:speech` model sizing + identity (drives M3 download/disk UX + M4 memory target)
- **Source:** `Sources/ClaudeRelaySpeech/SpeechModelStore.swift:24-29` downloads
  `https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf`
  → file `qwen35-0.8b-q4km.gguf`. Real linked size (verified via HF `x-linked-size`
  header) = **532,517,120 bytes ≈ 0.5 GB**, not "~2.4 GB". `ModelStoreError` budgets
  "~1 GB required" for **all** speech models combined.
- **Wrong in:** spec §5 + Risk Register + M3 Task 10 ("~2.4 GB Qwen").
- **Fix:** "≈0.5 GB Qwen3.5-0.8B Q4_K_M". Re-reason the M4 <400 MB memory target accordingly.
- **Download vs bundle split (M3 Task 10):** iOS **downloads exactly two** artifacts —
  Whisper `openai_whisper-small.en` (via WhisperKit's own store) + the Qwen GGUF — and
  **bundles three** CoreML models (`Resources/{SileroVAD.mlmodelc 904K,
  SmartTurnV3.mlpackage 15M, WhisperLogMel8s.mlpackage 364K}`). Android **cannot** bundle
  `.mlmodelc/.mlpackage` — it bundles the **converted ONNX** (Silero/SmartTurn/LogMel,
  small) and downloads Whisper-ggml + Qwen-GGUF. The M3 text "Whisper + ~2.4GB Qwen + ONNX
  models" (download list) is wrong: ONNX models are **bundled, not downloaded.**
- **"Same weights" is format-distinct (parity risk):** iOS Whisper is a WhisperKit
  **CoreML-converted** `small.en`, not a raw ggml file (`WhisperTranscriber.swift:38-43`).
  Android whisper.cpp needs a **ggml** small.en — same OpenAI checkpoint, different
  artifact. State this as a parity-validation requirement (covered by the M4 CER gate),
  not a drop-in.

### A7. WakeWordAudioPreprocessor — MISSING from the M3 plan
- **Source:** `Sources/ClaudeRelaySpeech/WakeWordAudioPreprocessor.swift`; called in
  `WakeWordDetector.swift:67-73` before WhisperKit transcription.
- **Fix:** add `speech/.../wakeword/WakeWordAudioPreprocessor.kt` to M3 Task 3: port
  `peakNormalize` (targetPeak `0.95f`, noiseFloor `0.001f`, unchanged if peak ≤ noiseFloor)
  and `pad(toSeconds=3.0, sampleRate=16000, trailing zeros, never truncate)`, and call both
  in `WakeWordDetector` before transcription. Without it, wake-word recall won't match iOS.

### A8. ProcessedText + the silence/word-count gate — MISSING from M3 Task 6
- **Source:** `Sources/ClaudeRelaySpeech/ProcessedText.swift:6-19` (sealed enum:
  `.passthrough/.enhanced/.cleaned/.refused(original)/.empty`, with `deliverableText: String?`
  = nil for `.empty`); `SpeechPostProcessor.swift:24-30` short-circuits to `.empty` when
  `trimmed.isEmpty`, `wordCount < 2`, or `TranscriberError.isSilenceHallucination(trimmed)`,
  **before** any enhance/clean; `.refused` is special-cased and does NOT fall through to clean.
- **Wrong in:** M3 Task 6 (`process` returns a bare `String`; sample test expects single-word
  `"raw"` echoed — iOS would suppress it as `.empty`).
- **Fix:** port `ProcessedText` as a sealed type with nullable `deliverableText`; port the
  word<2 / silence-hallucination short-circuit and the `.refused` branch. Otherwise Android
  emits transcripts iOS deliberately suppresses.

---

## B. MEDIUM — fidelity drifts to fix in the affected task

### B1. AgentColorPalette + TerminalPalette — capture exact colors (M2 Task 8)
- **Source:** `Sources/ClaudeRelayClient/Views/AgentColorPalette.swift:12-14`:
  `"claude" → .orange` (`:12`); `"codex" → Color(red:84/255, green:132/255, blue:137/255)`
  (teal, `:13`); **default → the SAME teal** as codex (`:14`, not a distinct neutral).
  `ClaudeRelayApp/Views/Components/TerminalPalette.swift:8-25` defines the 16-color ANSI
  palette installed via `RelayTerminalView.swift:266`.
- **Fix:** M2 Task 8 must port the exact `claude=orange / codex=RGB(84,132,137)` values, and
  add an explicit deliverable to install the 16 ANSI values into the Termux palette
  (`TerminalPalette` is currently unnamed in the plans). `agent` stays a `String` keyed by
  `"claude"/"codex"` (the Swift client does the same — do **not** port the full
  `CodingAgent` registry; it is server-only detection machinery the client never runs).

### B2. TerminalCache needs `pruneStale` / `cachedIds` / `removeAll` (M2 Task 2)
- **Source:** `TerminalCache.swift` + `SharedSessionCoordinator.swift:349-355,720`:
  `fetchSessions` evicts cached terminals for sessions gone from the server via a stale-prune;
  teardown uses `removeAll`. Swift's `enforceLimit` keys off the cached-view count + an
  explicit `lru` array, not access-order.
- **Fix:** the Kotlin cache must add `pruneStale(knownSessionIds)`, `cachedIds`, `count`,
  `removeAll`. The stripped 6-method LinkedHashMap(accessOrder) version loses stale-prune.

### B3. VadEvent is a 4-case enum, not 3 (M3 Task 2)
- **Source:** `Sources/ClaudeRelaySpeech/VADEvent.swift`: `speechStart, speechContinue,
  silenceStart, silenceContinue`, with `isSpeech` (start|continue) and `isEdge`
  (start) helpers.
- **Fix:** port all four cases + both helpers. Don't collapse the two "continue" cases into
  "None" — downstream distinguishes `speechContinue` from `silenceContinue` via `isSpeech`.

### B4. SavedConnectionStore legacy migration — exact key + lazy trigger (M1 Task 15 / spec §3)
- **Source:** `Sources/ClaudeRelayClient/Helpers/SavedConnectionStore.swift`. Legacy key is
  the literal `com.coderemote.savedConnections`; migration triggers lazily inside `loadAll()`
  whenever the current key is empty (not strictly "first launch"); the legacy key is left
  intact for downgrade safety.
- **Fix:** name the literal key in the spec/plan; the M1 "migration stub" must use
  `com.coderemote.savedConnections` as the source key.

### B5. Ownership store key string is `ownedSessions`, not `ownedSessionIds` (M2 Task 1)
- **Source:** `SessionOwnershipStore.swift`: the persisted key segment is `ownedSessions`.
  iOS literal keys: `com.clauderelay.sessionNames`,
  `com.clauderelay.ownedSessions.<deviceId>`, `com.clauderelay.agentSessions`.
- **Fix:** if mirroring iOS naming, the owned key string must read `ownedSessions` (the
  in-memory accessor may stay `owned`). **Note:** exact key-string parity with iOS is not a
  hard goal (Android shares no UserDefaults with iOS) — Android namespaces by the
  SharedPreferences file `relay.ownership`. Either replicate the prefixed strings verbatim
  **or** state explicitly that key-string parity is a non-goal. Just don't mislabel
  `ownedSessionIds` as a "verbatim port."

---

## C. LOW — wording/clarity (apply opportunistically)

- **C1. TerminalViewModel test framing (M1 Task 16 / spec §4):** drop "closes the iOS
  test-coverage gap" / "iOS has none here" / "with tests iOS lacks". iOS already has
  `Tests/ClaudeRelayClientTests/TerminalViewModelTests.swift`. The Android tests **port** an
  existing suite. Enumerate the same cases for parity (exact-4MB-boundary no-evict,
  over-cap eviction, resetForReplay-sends-RIS, awaiting-input-cleared-on-send).
- **C2. resize / resize_ack (spec §4):** iOS sends `resize` immediately and **ignores**
  `resize_ack` — there is no client-side reconcile. Don't build a `resize_ack`-driven
  reconcile loop "to match iOS"; to match iOS, resize is fire-and-forget. Any reconcile is a
  deliberate enhancement and should be labeled as such.
- **C3. SessionState.fromRaw fallback:** the Kotlin `fromRaw → CREATED` on unknown is a
  deliberate **divergence** (Swift throws). Either document the leniency (acceptable — both
  ends ship the same 9 cases, so unknown shouldn't occur on the wire) or make it throw.
  CREATED is a poor fallback (non-terminal); prefer documenting leniency + treating unknown
  as a no-op rather than a live state.
- **C4. terminalScrollbackLines:** default `5000` is correct; `25000` is the **largest picker
  option** (discrete picker 1000/5000/10000/25000), not an enforced max — the source has no
  clamp.
- **C5. SpeechProcessingOptions defaults (confirm in the Kotlin port):** `wakeWord="claude"`
  (lowercase — "Claude" is only the spoken/UI form), `bedrockRegion="us-east-1"`,
  `smartCleanupEnabled=true`, `promptEnhancementEnabled=false`, `turnEndSilenceTimeout=8.0`.

---

## D. Confirmed-correct anchors (do NOT change — verified verbatim against source)

These were checked and match source exactly; listed so future edits don't "fix" them:

- **Wire fidelity:** 12 client type strings; snake_case types / camelCase payload fields;
  `session_list_result` & `session_list_all_result` (collision avoidance); empty `{}` payload
  for ping/pong/detach/list; `skipReplay` emitted only when true; `protocolVersion/name/agent`
  omitted when nil; unknown type throws; **terminal I/O is raw binary frames**.
- **`SessionInfo.createdAt` is a `Double`** (WS path; reference-date seconds), cols/rows are
  `UInt16`. ISO-8601 is Admin-HTTP only.
- **ActivityState:** `active/idle/agent_active/agent_idle`; legacy `claude_active/claude_idle`
  decode → agent*; unknown → `active`; encode always modern.
- **ConnectionQuality thresholds** (EXCELLENT_RTT 0.1 / GOOD_RTT 0.3 / POOR_RTT 0.8 /
  MIN_SUCCESS 0.5 / GOOD_SUCCESS 0.83 / PERFECT 1.0) and bucket logic.
- **RelayConnection:** 10 s ping interval, 5 s pong timeout, 6-sample window, 3-fail death,
  generation counter, single-flight pong, `forceReconnect` does not auto-loop.
- **SessionController:** subscriber-before-send, ResumeGuard single-resume, 10 s timeout,
  `protocolVersion=1` / `minProtocolVersion=0`.
- **AuthManager Keychain:** service `com.coderemote.relay` (account = connection UUID);
  Bedrock key `com.clauderelay.bedrock.bearerToken`.
- **AuthCoordinator:** single-flight `ensureAuthenticated`; `withAuth` retry-once on
  not-authenticated.
- **TerminalViewModel:** 4 MB `pendingOutput` cap FIFO-drop + once-per-session warn; RIS =
  `0x1B 0x63` on first-ready; buffer-during-replay → single contiguous flush;
  input-prompt debounce **1000 ms normal / 2000 ms agent-active**.
- **Energy VAD:** speech `0.015` / silence `0.008`; 250 ms / 1 s debounce; chunk 0.030 s.
  (Silero overrides: speech `0.5`, silence `0.35`, chunk `0.1 s`.)
- **Silero ONNX I/O:** input `[1,576]` (64 ctx + 512 chunk) + `hidden_state[1,128]` +
  `cell_state[1,128]` → `vad_output` + new states; stateful LSTM threading; context =
  last 64 samples.
- **SmartTurn/LogMel:** LogMel `[1,80,800]` for 8 s @ 16 kHz; SmartTurn = Whisper-Tiny
  encoder + linear head → sigmoid, threshold 0.5; audio array `[128_000]`, feature key
  `log_mel`, classifier input `input_features`, output `probability`; **fail-to-done bias**
  (returns 1.0 on inference error); zero-pad at the **start**.
- **CloudPromptEnhancer:** Bedrock Converse; default modelId
  `us.anthropic.claude-haiku-4-5-20251001-v1:0`; maxTokens 512, temp 0.3; parses
  `output.message.content[0].text`; 17 refusal-prefixes + 6 refusal-phrases →
  `.refused`; `Bearer …` redaction in error formatting; 15 s request timeout.
- **TextCleaner:** Qwen3.5-0.8B Q4_K_M; `maxTokenCount=512`; 8 s timeout race → revert;
  hallucination guard (>3× input length & >100 chars, or contains ``` / `<div` / `<script` /
  `<html`); `minimumWordCount=3` bypass.
- **WhisperTranscriber.collapseRepetitions:** gated on `len > 20`; two-tier (sentence split
  on `.?!` Levenshtein ≤ `max(2, ref.count/5)`, then char-level minUnit 10 Levenshtein ≤
  `max(3, unit.count/3)`).
- **Continuous-listening states + color buckets** (BLUE listening/detectingWakeWord; RED
  armed/recording/detectingTurnEnd; YELLOW transcribing/cleaning/outputting); armed 4 s
  timeout; minSilenceDuration 1.0 s; turnEndSilenceTimeout 8 s (classifier authoritative,
  timer safety-net); strict two-phase residue rejection; 300 s audio auto-stop.
- **Wake-word cascade:** alias → Levenshtein (≤2) → Metaphone + first-letter guard; default
  wake word `"claude"`.
- **Coverage CONFIRMED:** ClipboardService (M4 Task 4), NetworkMonitor (M2), StreamingAudioSource
  (M3 Task 1), KeyCaptureView (M2 Task 10), QRCodeComponents (M2 Task 9), MicButton (M3
  Task 11), RelayTerminalView (M1 Task 17).
