# ClaudeRelaySpeech

Speech-pipeline guidance. Loads when working under `Sources/ClaudeRelaySpeech/`.

## Continuous Listening Pipeline

`ContinuousListeningEngine` is a parallel orchestrator to `OnDeviceSpeechEngine`
powering always-on listening with a wake word ("Claude" by default). Both
engines delegate post-processing (cleanup plus cloud enhancement) to the shared
`SpeechPostProcessor`, so `smartCleanupEnabled` and `promptEnhancementEnabled`
settings behave identically in push-to-talk and continuous modes.

**Strict two-phase UX.** The user says the wake word, the mic button turns
red to acknowledge, then they speak the command. Combined utterances like
"Claude, list my files" spoken in one breath are rejected — the red-light
handshake is the whole point of the design. An `.armed` state sits between
wake-word detection and command recording, timing out back to `.listening`
after 4 s if the user never starts the command.

State machine:
```
idle → listening (blue) ─ speechStart → detectingWakeWord (blue)
  ↓ (silence + wake-word match with empty residue)
armed (red, 4s timeout) ─ speechStart → recording (red)
  ↓ silenceStart (≥1 s)
detectingTurnEnd (red) ─ classifier: done → transcribing (yellow)
                      └ classifier: continuing → recording
transcribing → cleaning (yellow) → outputting (yellow) → listening
```

UI color buckets: **blue** for `listening`/`detectingWakeWord`, **red** for
`armed`/`recording`/`detectingTurnEnd`, **yellow** for
`transcribing`/`cleaning`/`outputting`.

Pipeline:
1. `StreamingAudioSource` (AVAudioEngine tap) → 16 kHz mono Float32 chunks
2. `StreamingAudioBuffer` (30 s ring, `OSAllocatedUnfairLock`) — zero-copy append
3. `VoiceActivityDetecting` — `SileroVoiceActivityDetector` wraps the bundled
   FluidInference Silero-VAD v6 unified CoreML model (stateful LSTM, 576-sample
   input = 64 context + 512 chunk). Falls back to the energy-based
   `VoiceActivityDetector` if the bundle resource fails to load.
4. On `speechStart` (listening → detectingWakeWord), ~0.5 s of pre-roll is
   fed to `WakeWordDetector` plus ongoing chunks until `silenceStart`
5. `WakeWordDetector.checkForWakeWord()` runs `WakeWordAudioPreprocessor`
   (peak-normalize to ~0.95 + pad to 3 s) before WhisperKit transcription,
   then matches with a cascade: alias table → Levenshtein (≤ 2) →
   Metaphone phonetic equality with first-letter guard
6. If matched with empty residue → `.armed` (red, 4 s). Non-empty residue
   is rejected in strict mode — user must pause before the command
7. `armed → recording` on next `speechStart`; `recording → detectingTurnEnd`
   on `silenceStart`. VAD `minSilenceDuration = 1.0 s` so transient breath
   pauses do not trigger turn-end
8. `TurnEndDetecting` — `SmartTurnTurnEndDetector` bundles Smart-Turn v3
   (Whisper-Tiny encoder + linear head, 8 s zero-padded-from-start context)
   and a Whisper log-mel preprocessor. Falls back to `HeuristicTurnEndDetector`
   if either `.mlpackage` fails to load or compile
9. `raceTurnEnd` returns `TurnEndDecision {done, continuing, inferenceTimedOut}`.
   **The classifier is authoritative.** The timer (`turnEndSilenceTimeout`,
   default 8 s) is a safety net against a hung CoreML prediction — when
   it fires the engine resumes `.recording` rather than forcing transcription
10. On `.done` → Whisper transcription → `SpeechPostProcessor.process(...)`
    → `onUtteranceReady` → `SessionCoordinator.vm.sendInput(text)`

`ContinuousListeningEngine.makeDefault(options:)` constructs the engine with
the best available detectors. `updateOptions(_:)` pushes settings changes
(incl. wake word, which triggers a `WakeWordDetector` rebuild) without
restarting. iOS responds to `AVAudioSession.interruptionNotification` by
pausing; macOS hooks `NSWorkspace.willSleepNotification` /
`didWakeNotification`.

Push-to-talk (`OnDeviceSpeechEngine`) remains as an alternative mode. When
`continuousListeningEnabled` is on: tap the mic to pause/resume; long-press
for a 2-second one-shot PTT capture without disabling continuous mode.

**Foreground-only:** audio engine starts on `scenePhase == .active` (iOS) or
the Settings toggle (macOS). No background audio entitlement is used.

