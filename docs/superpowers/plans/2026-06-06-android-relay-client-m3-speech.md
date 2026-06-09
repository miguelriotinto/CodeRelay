# Android Relay Client — M3: On-Device Speech

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. **Depends on M2.**
>
> **⚠️ Read `docs/superpowers/plans/2026-06-08-android-relay-client-corrections.md` first.** M3-relevant: Qwen is `qwen35-0.8b-q4km.gguf` ≈ **0.5 GB**, not ~2.4 GB (A6, fixed below); ONNX models are **bundled, not downloaded** (A6); add **`WakeWordAudioPreprocessor`** (peakNormalize 0.95 + pad-to-3s) to Task 3 (A7); port **`ProcessedText`** sealed type + the word<2/silence-hallucination gate (A8); **`VadEvent` is 4 cases** (speechStart/speechContinue/silenceStart/silenceContinue) (B3). Confirmed-verbatim anchors (Silero `[1,576]`+`[1,128]` states, SmartTurn LogMel `[1,80,800]`/0.5/fail-to-done, Bedrock Haiku `us.anthropic.claude-haiku-4-5-20251001-v1:0`/512/0.3, energy VAD 0.015/0.008/250ms/1s, collapseRepetitions `len>20` two-tier) are in corrections §D — port verbatim.

**Goal:** On-device speech input at parity with iOS: microphone capture, whisper.cpp transcription, Silero VAD, the full push-to-talk + continuous-listening (wake-word) state machine, on-device llama.cpp text cleanup, and optional Bedrock Haiku cloud enhancement. The SmartTurn/LogMel turn-end classifier conversion is built here but gated behind parity validation in **M4** (a `HeuristicTurnEndDetector` ships in M3).

**Architecture:** A `:speech` module with a thin JNI layer (whisper.cpp, llama.cpp), ONNX Runtime Mobile for Silero VAD, an Oboe/AudioRecord capture layer, and pure-Kotlin ports of the state machine + wake-word matching + post-processor. A foreground service hosts continuous listening (Android requires this — divergence from iOS, documented in the spec).

**Swift source of truth:** all of `Sources/ClaudeRelaySpeech/*.swift`. **Read these before each task.**

> **Honesty note on this milestone:** JNI binding signatures, the converted-model tensor I/O, and Oboe callback wiring are **execution-time integration points** that depend on the exact third-party library versions chosen at build time. This plan pins: (a) the audio contract (16 kHz mono Float32), (b) the state machine (fully specified Kotlin), (c) wake-word matching (fully specified Kotlin), (d) thresholds/timeouts (from the Swift source), and (e) parity gates. It marks JNI/model glue as `EXECUTION NOTE` with the exact contract each must satisfy. Do NOT fabricate JNI signatures into "done" code — implement against the real library and validate with the parity tests.

---

## File Structure (added in M3)

```
speech/src/main/kotlin/relay/speech/
├── audio/AudioCaptureSession.kt        # PTT capture -> 16kHz mono Float32
├── audio/StreamingAudioSource.kt       # continuous tap
├── audio/StreamingAudioBuffer.kt       # lock-free ring (ported)
├── audio/Resampler.kt                  # hardware rate -> 16kHz
├── vad/VoiceActivityDetector.kt        # energy fallback (ported)
├── vad/SileroVoiceActivityDetector.kt  # ONNX Runtime, stateful LSTM
├── vad/VadEvent.kt
├── transcribe/WhisperTranscriber.kt    # whisper.cpp JNI wrapper + hallucination collapse
├── turnend/TurnEndDetector.kt          # interface + decision type
├── turnend/HeuristicTurnEndDetector.kt # silence-timeout fallback (ships in M3)
├── turnend/SmartTurnTurnEndDetector.kt # ONNX (built M3, ENABLED in M4 behind gate)
├── wakeword/WakeWordDetector.kt        # alias->Levenshtein->Metaphone (ported)
├── wakeword/Metaphone.kt               # phonetic algorithm (pure Kotlin)
├── wakeword/WakeWordAudioPreprocessor.kt  # peakNormalize(0.95)+pad-to-3s before transcribe (ported)
├── cleanup/TextCleaner.kt              # llama.cpp JNI wrapper
├── cleanup/CloudPromptEnhancer.kt      # Bedrock Converse (OkHttp)
├── cleanup/SpeechPostProcessor.kt      # gate -> enhance -> clean -> passthrough; returns ProcessedText
├── ProcessedText.kt                    # sealed result (Passthrough/Enhanced/Cleaned/Refused/Empty)
├── ContinuousListeningState.kt         # enum + color buckets (ported)
├── ContinuousListeningEngine.kt        # state machine (ported)
├── OnDeviceSpeechEngine.kt             # PTT orchestrator (ported)
├── SpeechProcessingOptions.kt          # options (ported)
├── SpeechModelStore.kt                 # download/cache/disk lifecycle
└── ContinuousListeningService.kt       # foreground service (Android-specific)
native/ (cpp)
├── whisper-jni/                        # whisper.cpp + JNI bridge
└── llama-jni/                          # llama.cpp + JNI bridge
ml/ (conversion sub-project, NOT shipped in the app)
├── convert_silero.py
├── convert_smartturn.py
├── convert_logmel.py
└── validate_parity.py
```

---

## Task 1: `:speech` module + audio contract + `StreamingAudioBuffer`

**Files:**
- Create: `speech/build.gradle.kts` (Android library, NDK enabled, ONNX Runtime + Oboe deps)
- Create: `speech/src/main/kotlin/relay/speech/audio/StreamingAudioBuffer.kt`
- Test: `speech/src/test/kotlin/relay/speech/audio/StreamingAudioBufferTest.kt` (JVM)

> Port of `StreamingAudioBuffer.swift`: thread-safe 30s ring of Float32 at 16kHz, monotonic write position, lock-free reads returning independent copies. This is pure logic → fully unit-testable.

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.speech.audio

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class StreamingAudioBufferTest {
    @Test fun `append advances write position`() {
        val buf = StreamingAudioBuffer(capacitySamples = 16000)
        buf.append(FloatArray(800) { 0.1f })
        assertEquals(800L, buf.writePosition)
    }
    @Test fun `read returns independent copy of a range`() {
        val buf = StreamingAudioBuffer(capacitySamples = 16000)
        buf.append(FloatArray(1000) { it.toFloat() })
        val copy = buf.read(from = 0, count = 500)
        copy[0] = -1f
        assertEquals(0f, buf.read(0, 1)[0])   // original unaffected
        assertEquals(500, copy.size)
    }
    @Test fun `ring overwrites oldest beyond capacity`() {
        val buf = StreamingAudioBuffer(capacitySamples = 1000)
        buf.append(FloatArray(1500) { 1f })   // overflows
        assertEquals(1500L, buf.writePosition)  // monotonic
    }
}
```

- [ ] **Step 2: Run to verify it fails / Step 3: implement**

```kotlin
package relay.speech.audio

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Port of StreamingAudioBuffer.swift: 16kHz mono Float32 ring, monotonic
 *  write position, lock-protected append, copy-on-read. */
class StreamingAudioBuffer(private val capacitySamples: Int = 16000 * 30) {
    private val ring = FloatArray(capacitySamples)
    private val lock = ReentrantLock()
    @Volatile var writePosition: Long = 0L; private set

    fun append(samples: FloatArray) = lock.withLock {
        for (s in samples) { ring[(writePosition % capacitySamples).toInt()] = s; writePosition++ }
    }
    /** Returns an independent copy of [count] samples starting at absolute [from]. */
    fun read(from: Long, count: Int): FloatArray = lock.withLock {
        FloatArray(count) { i -> ring[((from + i) % capacitySamples).toInt()] }
    }
}
```

- [ ] **Step 4: pass / Step 5: Commit** `feat(speech): module + StreamingAudioBuffer (16kHz mono Float32 contract)`

> **EXECUTION NOTE — audio capture:** `AudioCaptureSession`/`StreamingAudioSource`/`Resampler` wrap Oboe (preferred) or `AudioRecord`. Contract: deliver 16 kHz mono **Float32** chunks to `StreamingAudioBuffer.append` and an `onChunk` callback. Handle `AudioManager.OnAudioFocusChangeListener` interruptions (calls/Bluetooth) — the `AVAudioSession.interruptionNotification` analog. Retain the 5-min auto-stop cap. Verify manually (record + assert sample rate/format), not unit-tested.

---

## Task 2: Energy VAD (`VoiceActivityDetector`) — ported, unit-tested

**Files:**
- Create: `speech/src/main/kotlin/relay/speech/vad/VadEvent.kt`, `VoiceActivityDetector.kt`
- Test: `speech/src/test/kotlin/relay/speech/vad/VoiceActivityDetectorTest.kt`

> Port of `VoiceActivityDetector.swift`: RMS hysteresis (speech 0.015 / silence 0.008), debounce 250ms speech-start / 1s silence-start. This is the documented fallback when Silero fails to load — and is pure logic.

- [ ] **Step 1: Write failing tests** asserting: loud RMS chunks past 250ms → `SpeechStart`; quiet chunks past 1s → `SilenceStart`; transient single-chunk dips do NOT flip state.
- [ ] **Step 2–4:** implement the RMS detector with the exact thresholds/debounce from Swift. `VadEvent` is a **4-case** enum (port `VADEvent.swift` verbatim): `SpeechStart, SpeechContinue, SilenceStart, SilenceContinue`, with `isSpeech` (start|continue) and `isEdge` (start) helpers. Do **not** collapse the two "continue" cases into `None` — downstream distinguishes `speechContinue` from `silenceContinue` via `isSpeech`.
- [ ] **Step 5: Commit** `feat(speech): energy VAD fallback (ported thresholds)`

> **EXECUTION NOTE — Silero VAD:** `SileroVoiceActivityDetector` runs the converted Silero v6 ONNX via ONNX Runtime Mobile. Public ONNX weights for Silero exist (low conversion risk — see ml/Task 9). Contract: input `audio_input[1,576]` (64 context + 512 chunk) + `hidden_state[1,128]` + `cell_state[1,128]` → `vad_output[1]` + new states; **thread the LSTM states across calls**. Fall back to the energy VAD (Task 2) if the model fails to load. Validate edge timing in M4.

---

## Task 3: `Metaphone` + `WakeWordDetector` matching cascade — ported, unit-tested

**Files:**
- Create: `speech/src/main/kotlin/relay/speech/wakeword/Metaphone.kt`, `WakeWordDetector.kt`
- Create: `speech/src/main/kotlin/relay/speech/wakeword/WakeWordAudioPreprocessor.kt`
- Test: `speech/src/test/kotlin/relay/speech/wakeword/WakeWordTest.kt`
- Test: `speech/src/test/kotlin/relay/speech/wakeword/WakeWordAudioPreprocessorTest.kt`

> Port of `WakeWordDetector.swift` matching logic (the transcription part needs Whisper — Task 5 — but the **match cascade is pure logic**): alias table → Levenshtein (≤2) → Metaphone phonetic equality with first-letter guard. This is fully unit-testable and is where wake-word recall lives.

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.speech.wakeword

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class WakeWordTest {
    private val d = WakeWordDetector(wakeWord = "claude")
    @Test fun `exact match`() { assertTrue(d.matches("claude")) }
    @Test fun `alias match`() { assertTrue(d.matches("cloud")) }           // known alias
    @Test fun `levenshtein within two`() { assertTrue(d.matches("clawd")) }
    @Test fun `metaphone phonetic match`() { assertTrue(d.matches("klaude")) }
    @Test fun `first-letter guard rejects distant`() { assertFalse(d.matches("frog")) }
    @Test fun `empty residue required handled by caller`() { /* residue logic lives in engine */ }
}
```

- [ ] **Step 2–4:** implement `Metaphone` (standard algorithm, pure Kotlin) and `WakeWordDetector.matches(transcript)` with the cascade + alias table (`cloud`, `lord`, etc. — copy the EXACT alias entries from `WakeWordDetector.swift` so the test's `cloud` alias and Levenshtein bound match) + first-letter guard + configurable wake word.
- [ ] **Step 4b: Port `WakeWordAudioPreprocessor`** (`WakeWordAudioPreprocessor.swift`; required for recall parity — do NOT skip): `peakNormalize` (targetPeak `0.95f`, noiseFloor `0.001f`, return unchanged if peak ≤ noiseFloor) and `pad(toSeconds=3.0, sampleRate=16000)` (trailing zeros, never truncate). Call BOTH on the captured audio **before** WhisperKit/whisper.cpp transcription, matching `WakeWordDetector.swift:67-73`. Unit-test: a quiet buffer normalizes to peak ≈ 0.95; a <3 s buffer pads to exactly 48000 samples; a near-silent buffer (peak ≤ 0.001) is returned unchanged.
- [ ] **Step 5: Commit** `feat(speech): wake-word match cascade + audio preprocessor (normalize + pad)`

---

## Task 4: `ContinuousListeningState` + color buckets — ported, unit-tested

**Files:**
- Create: `speech/src/main/kotlin/relay/speech/ContinuousListeningState.kt`
- Test: `speech/src/test/kotlin/relay/speech/ContinuousListeningStateTest.kt`

> Port of `ContinuousListeningState.swift`. The enum + the blue/red/yellow UI color bucket mapping is pure logic.

- [ ] **Step 1: Write the failing test**

```kotlin
@Test fun `color buckets`() {
    assertEquals(ListeningColor.BLUE, ContinuousListeningState.LISTENING.color)
    assertEquals(ListeningColor.BLUE, ContinuousListeningState.DETECTING_WAKE_WORD.color)
    assertEquals(ListeningColor.RED, ContinuousListeningState.ARMED.color)
    assertEquals(ListeningColor.RED, ContinuousListeningState.RECORDING.color)
    assertEquals(ListeningColor.RED, ContinuousListeningState.DETECTING_TURN_END.color)
    assertEquals(ListeningColor.YELLOW, ContinuousListeningState.TRANSCRIBING.color)
    assertEquals(ListeningColor.YELLOW, ContinuousListeningState.CLEANING.color)
    assertEquals(ListeningColor.YELLOW, ContinuousListeningState.OUTPUTTING.color)
}
```

- [ ] **Step 2–4:** implement the enum (`IDLE, LISTENING, DETECTING_WAKE_WORD, ARMED, RECORDING, DETECTING_TURN_END, TRANSCRIBING, CLEANING, OUTPUTTING`) + `color` mapping. **Document the strict two-phase contract** in KDoc: combined "Claude, do X" is rejected; `ARMED` has a 4s timeout back to `LISTENING`.
- [ ] **Step 5: Commit** `feat(speech): continuous-listening state + color buckets`

---

## Task 5: `WhisperTranscriber` (whisper.cpp JNI) + hallucination collapse

**Files:**
- Create: `speech/native/whisper-jni/` (C++ + CMake)
- Create: `speech/src/main/kotlin/relay/speech/transcribe/WhisperTranscriber.kt`
- Test: `speech/src/test/kotlin/relay/speech/transcribe/HallucinationCollapseTest.kt` (JVM — tests the pure post-processing only)

> Port of `WhisperTranscriber.swift`. The **repetition-hallucination collapse** (Levenshtein/char-unit) is pure logic and unit-tested here. The whisper.cpp inference is JNI glue (EXECUTION NOTE).

- [ ] **Step 1: Write the failing test for hallucination collapse**

```kotlin
@Test fun `collapses repeated phrase hallucination`() {
    val collapsed = WhisperTranscriber.collapseRepetition("list files list files list files")
    assertEquals("list files", collapsed)
}
@Test fun `leaves normal text unchanged`() {
    assertEquals("open the readme", WhisperTranscriber.collapseRepetition("open the readme"))
}
```

- [ ] **Step 2–4:** implement `collapseRepetition` (port the exact Swift heuristic). Define `suspend fun transcribe(samples: FloatArray): String` that calls the JNI bridge then `collapseRepetition`.

> **EXECUTION NOTE — whisper.cpp JNI:** vendor whisper.cpp under `native/whisper-jni/`, add a CMake `externalNativeBuild`, expose `nativeTranscribe(modelPtr, floatPcm): String`. Use the **same Whisper small.en weights** as iOS (ggml/GGUF). Run on `Dispatchers.Default`. VAD-confirmed audio → bypass the no-speech filter (matches Swift). Validate transcription parity in M4 (≤0.5% CER vs iOS on the reference set).

- [ ] **Step 5: Commit** `feat(speech): WhisperTranscriber + hallucination collapse`

---

## Task 6: `TextCleaner` (llama.cpp JNI) + `CloudPromptEnhancer` + `SpeechPostProcessor`

**Files:**
- Create: `speech/native/llama-jni/`
- Create: `speech/src/main/kotlin/relay/speech/ProcessedText.kt`
- Create: `speech/src/main/kotlin/relay/speech/cleanup/{TextCleaner,CloudPromptEnhancer,SpeechPostProcessor}.kt`
- Test: `speech/src/test/kotlin/relay/speech/cleanup/SpeechPostProcessorTest.kt`

> `SpeechPostProcessor` (port of `SpeechPostProcessor.swift`) chains enhance→clean→passthrough and **never throws**, returning a **`ProcessedText`** (port `ProcessedText.swift`: a sealed type `Passthrough/Enhanced/Cleaned/Refused(original)/Empty` with `deliverableText: String?` = `null` for `Empty`). It **short-circuits to `Empty`** when the trimmed input is blank, `wordCount < 2`, or `isSilenceHallucination` — **before** any enhance/clean (`SpeechPostProcessor.swift:24-30`). `CloudPromptEnhancer` is OkHttp REST (Bedrock Converse). `TextCleaner` is llama.cpp JNI.

- [ ] **Step 1: Write the failing test (fakes for cleaner + enhancer)**

```kotlin
private fun pp(enhance: suspend (String)->String, clean: suspend (String)->String,
               smart: Boolean, prompt: Boolean, token: String = "tok") =
    SpeechPostProcessor(enhance, clean,
        SpeechProcessingOptions(smartCleanupEnabled = smart, promptEnhancementEnabled = prompt,
                                bedrockBearerToken = token))

@Test fun `word count below two short-circuits to Empty before any work`() = runTest {
    val pp = pp({ "X" }, { "Y" }, smart = true, prompt = true)
    val r = pp.process("raw")                 // single word -> iOS suppresses
    assertEquals(ProcessedText.Empty, r)
    assertNull(r.deliverableText)
}
@Test fun `enhances then falls through to clean on enhancer failure`() = runTest {
    val pp = pp(enhance = { throw RuntimeException("network") }, clean = { "cleaned: $it" },
               smart = true, prompt = true)
    val r = pp.process("raw text here")       // >=2 words, passes the gate
    assertEquals("cleaned: raw text here", r.deliverableText)
}
@Test fun `refused does not fall through to clean`() = runTest {
    val pp = pp(enhance = { throw EnhancerException.Refused }, clean = { "cleaned: $it" },
               smart = true, prompt = true)
    val r = pp.process("two words")
    assertTrue(r is ProcessedText.Refused); assertEquals("two words", r.deliverableText)
}
@Test fun `passthrough when both disabled`() = runTest {
    val pp = pp({ "X" }, { "Y" }, smart = false, prompt = false)
    assertEquals("raw text", pp.process("raw text").deliverableText)
}
@Test fun `never throws`() = runTest {
    val pp = pp({ throw RuntimeException() }, { throw RuntimeException() }, smart = true, prompt = true)
    assertEquals("raw text", pp.process("raw text").deliverableText)  // falls back to original
}
```

- [ ] **Step 2–4:** implement `ProcessedText` (sealed type + `deliverableText`) and `SpeechPostProcessor.process` returning it (`SpeechPostProcessor.swift:20-73`): trim → `Empty` if blank / `wordCount < 2` / `isSilenceHallucination`; then `wantsEnhancement = promptEnhancement && token.isNotEmpty()` → try `enhance` → `Enhanced`, on `Refused` → `Refused(original)` (do NOT fall through), on other failure → if `smartCleanup` run `clean` else `Passthrough`; if not enhancing → `smartCleanup ? clean : Passthrough`; cleanup catches all → `Passthrough`; **never throws**. Implement `CloudPromptEnhancer` (Bedrock Converse POST, bearer token, maxTokens=512 temp=0.3, parse `output.message.content[0].text`, **redact `Bearer` in error logs**, 17 refusal-prefix + 6 refusal-phrase detection → `Refused`, 15 s timeout, default modelId `us.anthropic.claude-haiku-4-5-20251001-v1:0`). `TextCleaner` JNI below. **The mic-button consumer must skip sending when `deliverableText == null`** (the `Empty` suppression iOS relies on).

> **EXECUTION NOTE — llama.cpp JNI:** vendor llama.cpp under `native/llama-jni/`; load the **same Qwen GGUF** as iOS; 512-token context; **8s timeout race** (`withTimeoutOrNull(8000)`) reverting to original on timeout/hallucination; unload on `ComponentCallbacks2.onTrimMemory`. Validate cleanup parity in M4.

- [ ] **Step 5: Commit** `feat(speech): post-processor + cloud enhancer + text cleaner`

---

## Task 7: `HeuristicTurnEndDetector` + `TurnEndDetector` interface (M3 ships heuristic)

**Files:**
- Create: `speech/src/main/kotlin/relay/speech/turnend/{TurnEndDetector,HeuristicTurnEndDetector,TurnEndDecision}.kt`
- Test: `speech/src/test/kotlin/relay/speech/turnend/HeuristicTurnEndDetectorTest.kt`

> Port of `TurnEndDetector.swift` interface + `HeuristicTurnEndDetector`. The SmartTurn ONNX detector is built in Task 9 but **only enabled in M4** behind the parity gate; M3 ships the heuristic so continuous listening is fully functional.

- [ ] **Step 1: Write the failing test** — heuristic returns `done` after the configured silence (default from `SpeechProcessingOptions`), `continuing` otherwise.
- [ ] **Step 2–4:** implement `TurnEndDecision(done, continuing, inferenceTimedOut)`, the `TurnEndDetector` interface, and the silence-timeout heuristic.
- [ ] **Step 5: Commit** `feat(speech): turn-end interface + heuristic detector`

---

## Task 8: `ContinuousListeningEngine` + `OnDeviceSpeechEngine` state machines

**Files:**
- Create: `speech/src/main/kotlin/relay/speech/{ContinuousListeningEngine,OnDeviceSpeechEngine,SpeechProcessingOptions}.kt`
- Test: `speech/src/test/kotlin/relay/speech/ContinuousListeningEngineTest.kt`

> Port of `ContinuousListeningEngine.swift` (+ `OnDeviceSpeechEngine.swift`). The state machine is the heart of the feature and is **testable with injected detectors** (fake VAD/wake-word/turn-end/transcriber/post-processor). This is where the strict two-phase red-handshake and "classifier authoritative / timer safety-net" rules live.

- [ ] **Step 1: Write the failing tests (injected fakes drive transitions)**

```kotlin
@Test fun `wake word with empty residue arms; non-empty residue rejected`() = runTest {
    // feed speechStart -> detectingWakeWord; wake word "claude" + empty residue -> ARMED
    // feed "claude list files" (non-empty residue) -> stays LISTENING (strict mode)
}
@Test fun `armed times out back to listening after 4s`() = runTest { /* advance virtual time 4s */ }
@Test fun `classifier done triggers transcribe even before timer`() = runTest { /* authoritative */ }
@Test fun `classifier timeout (timer) resumes recording, not transcribe`() = runTest { /* safety-net */ }
@Test fun `full happy path produces an utterance`() = runTest {
    // listening -> wake -> armed -> recording -> turnEnd done -> transcribe -> clean -> onUtteranceReady("...")
}
```

- [ ] **Step 2–4:** implement both engines as coroutine state machines over the injected detectors, mirroring the Swift transitions exactly (the spec's state diagram). `ContinuousListeningEngine.makeDefault(options)` wires the best available detectors (Silero VAD or energy fallback; SmartTurn or heuristic). `updateOptions` pushes settings (incl. wake-word rebuild) without restart. Emit `onUtteranceReady(text)`.
- [ ] **Step 5: Commit** `feat(speech): continuous + PTT engines (strict two-phase state machine)`

---

## Task 9: CoreML→ONNX conversion sub-project (built in M3, gated to M4)

**Files:**
- Create: `ml/convert_silero.py`, `ml/convert_smartturn.py`, `ml/convert_logmel.py`, `ml/validate_parity.py`
- Create: `speech/src/main/kotlin/relay/speech/turnend/SmartTurnTurnEndDetector.kt`

> Build the conversion pipeline and the ONNX-backed detectors now; **do not enable SmartTurn in the shipped engine until M4's parity gate passes.** This task is research/tooling — verification is the parity report, not a unit test.
>
> **Monorepo payoff:** because the Android app lives in this repo, the conversion + validation scripts read the iOS CoreML originals and the speech fixtures by direct relative path — no copy/submodule. Source models: `Sources/ClaudeRelaySpeech/Resources/{SileroVAD.mlmodelc,WhisperLogMel8s.mlpackage,SmartTurnV3.mlpackage}`. Reference audio: `Tests/ClaudeRelaySpeechTests/Fixtures`. Conversion tooling lives under `ClaudeRelayAndroid/ml/`.

- [ ] **Step 1: Convert Silero VAD** — prefer public Silero v6 ONNX weights; else introspect `Sources/ClaudeRelaySpeech/Resources/SileroVAD.mlmodelc` with `coremltools` and rebuild in ONNX. Output `ClaudeRelayAndroid/ml/out/silero_vad.onnx`.
- [ ] **Step 2: Convert WhisperLogMel8s** — `coremltools` introspection of `Sources/ClaudeRelaySpeech/Resources/WhisperLogMel8s.mlpackage` → ONNX; verify output shape `[1,80,800]` for 8s @16kHz. Output `ClaudeRelayAndroid/ml/out/whisper_logmel8s.onnx`.
- [ ] **Step 3: Convert SmartTurn v3** — from `Sources/ClaudeRelaySpeech/Resources/SmartTurnV3.mlpackage`: Whisper-Tiny encoder + linear head → ONNX; sigmoid output, 0.5 threshold. Output `ClaudeRelayAndroid/ml/out/smartturn_v3.onnx`.
- [ ] **Step 4: `validate_parity.py`** — feed the reference audio set (`Tests/ClaudeRelaySpeechTests/Fixtures`) through BOTH the iOS CoreML models (via `coremltools` on a Mac, reading the `Sources/ClaudeRelaySpeech/Resources/` originals) and the converted ONNX models; assert: Silero probability relative error < 0.1%; SmartTurn turn-end TPR ≥ 90% / FPR ≤ 10% vs labels; LogMel output max-abs diff within tolerance. **Emit a parity report.**
- [ ] **Step 5: Implement `SmartTurnTurnEndDetector.kt`** — ONNX Runtime Mobile two-stage (LogMel → SmartTurn), `raceTurnEnd` returning `TurnEndDecision`, 8s timer safety-net (classifier authoritative). Fall back to `HeuristicTurnEndDetector` if models fail to load. **Leave it un-wired in `makeDefault` until M4.**
- [ ] **Step 6: Commit** `feat(speech): CoreML->ONNX conversion pipeline + SmartTurn detector (gated)`

---

## Task 10: `SpeechModelStore` + `ContinuousListeningService` (foreground) + permissions

**Files:**
- Create: `speech/src/main/kotlin/relay/speech/SpeechModelStore.kt`, `ContinuousListeningService.kt`
- Modify: `app/src/main/AndroidManifest.xml` (permissions + service)

> `SpeechModelStore` (port of `SpeechModelStore.swift`): resumable **downloads of exactly two artifacts** — Whisper-ggml small.en + Qwen `qwen35-0.8b-q4km.gguf` (**≈0.5 GB**, not 2.4 GB; HF `unsloth/Qwen3.5-0.8B-GGUF`) — with progress, disk lifecycle, platform-keyed flags. The three ONNX models (Silero/SmartTurn/LogMel, converted in Task 9) are **bundled as app assets, NOT downloaded** (they're small: 904K/15M/364K originals). `ContinuousListeningService` is the **Android-required foreground service** (`foregroundServiceType="microphone"` + persistent notification) — the documented divergence from iOS's foreground-only model.

- [ ] **Step 1: Manifest** — add `RECORD_AUDIO`, `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`; declare `<service android:foregroundServiceType="microphone"/>`.
- [ ] **Step 2: `SpeechModelStore`** — download/cache/verify the **two** downloaded models (Whisper-ggml small.en + Qwen `qwen35-0.8b-q4km.gguf` ≈0.5 GB); bundle the three ONNX models as assets (do not download them); `StateFlow` progress; cloud-only fallback if the Qwen download fails (still transcribe + cloud-enhance). Mirror iOS `modelsReady = whisperReady && llmDownloaded`.
- [ ] **Step 3: `ContinuousListeningService`** — foreground service hosting `ContinuousListeningEngine`; persistent notification; starts on workspace foreground when continuous mode is on; stops on background/disable. Runtime permission flow via `ActivityResultContracts`.
- [ ] **Step 4: Manual verify** — grant mic permission; download models with progress; service notification appears; speak wake word → red → command → text appears in the terminal.
- [ ] **Step 5: Commit** `feat(speech): model store + continuous-listening foreground service`

---

## Task 11: Wire speech into the workspace (MicButton dual-mode)

**Files:**
- Modify: `feature-workspace/.../TerminalScreen.kt`; create `MicButton.kt`
- Modify: `app/.../RelayNavGraph.kt` (preload models on splash dismiss)

> Port of `MicButton.swift`: PTT (tap) in default mode; continuous + long-press one-shot in continuous mode; state-driven icon+color (idle→recording→transcribing→cleaning→outputting; listening=blue); download-progress ring. `onUtteranceReady(text)` → active VM `sendInput(text)`.

- [ ] **Step 1:** implement `MicButton` observing engine state; wire PTT/continuous per `AppSettings.continuousListeningEnabled`.
- [ ] **Step 2:** wire `onUtteranceReady(result: ProcessedText)` → **skip when `result.deliverableText == null`** (the `Empty` suppression), else `coordinator.activeVm.sendInput(result.deliverableText!!)`.
- [ ] **Step 3: Manual verify (M3 acceptance):** PTT tap → speak → text sent; continuous mode → "Claude" (red) → command → text sent; long-press one-shot works; cloud enhance toggles behavior.
- [ ] **Step 4: Commit** `feat(workspace): mic button + speech wired to terminal input`

---

## M3 Self-Review Checklist

- [ ] Audio buffer ring + copy-on-read (Task 1 test).
- [ ] Energy VAD thresholds/debounce ported (Task 2 test).
- [ ] Wake-word cascade: alias/Levenshtein/Metaphone + first-letter guard (Task 3 test).
- [ ] State color buckets blue/red/yellow (Task 4 test).
- [ ] Hallucination collapse (Task 5 test).
- [ ] Post-processor never throws; word<2/silence → `Empty`; `Refused` doesn't fall through; returns `ProcessedText` (Task 6 test).
- [ ] `WakeWordAudioPreprocessor` ported: peakNormalize 0.95 + pad-to-3s before transcription (Task 3).
- [ ] Heuristic turn-end (Task 7 test).
- [ ] State machine: strict two-phase, armed timeout, classifier-authoritative, happy path (Task 8 tests).
- [ ] Conversion pipeline builds + parity report generated (Task 9) — SmartTurn NOT yet enabled.
- [ ] Foreground service + permissions + model download (Task 10 manual).
- [ ] PTT + continuous produce terminal input (Task 11 manual).
