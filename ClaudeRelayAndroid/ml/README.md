# `ml/` — CoreML → ONNX conversion for the Android speech pipeline

This sub-project converts the iOS/macOS **CoreML** speech models into **ONNX** so
the Android `:speech` module's ONNX-Runtime detectors can run the *same* models.

> **GATED to M4.** These scripts are tooling that runs on a **Mac with the ML
> deps installed**. They are **NOT run in the M3 build environment**
> (`coremltools`/`onnxruntime` are intentionally not installed there). The
> converted ONNX models are **not trusted** — and the consuming Kotlin detectors
> (`SileroVoiceActivityDetector`, `SmartTurnTurnEndDetector`) are **not wired into
> `ContinuousListeningEngine.makeDefault`** — until `validate_parity.py` **passes**.

## Requirements (run on a Mac)

```bash
pip install coremltools onnx onnxruntime numpy
# convert_logmel.py / convert_smartturn.py additionally need:
pip install torch transformers librosa
```

Run every script **from this directory** (`ClaudeRelayAndroid/ml/`) so the
relative source-model paths resolve:

```bash
cd ClaudeRelayAndroid/ml
python3 convert_silero.py        # → out/silero_vad.onnx
python3 convert_logmel.py        # → out/whisper_logmel8s.onnx
python3 convert_smartturn.py     # → out/smartturn_v3.onnx
python3 validate_parity.py       # THE GATE — must exit 0 before M4 wires detectors in
```

## Source models (in-repo CoreML, read by the scripts)

Relative to `ClaudeRelayAndroid/ml/`, under
`../../Sources/ClaudeRelaySpeech/Resources/`:

| Source CoreML model           | Script                | Output ONNX               |
|-------------------------------|-----------------------|---------------------------|
| `SileroVAD.mlmodelc`          | `convert_silero.py`   | `out/silero_vad.onnx`     |
| `WhisperLogMel8s.mlpackage`   | `convert_logmel.py`   | `out/whisper_logmel8s.onnx` |
| `SmartTurnV3.mlpackage`       | `convert_smartturn.py`| `out/smartturn_v3.onnx`   |

## I/O contracts (verified against the CoreML specs + the Swift/Kotlin detectors)

These are asserted by the convert/validate scripts and mirrored as constants in
the Kotlin detectors — a drift fails the script *and* would break the detector
on-device, so keep them in lock-step.

### Silero VAD v6 unified (`SileroVoiceActivityDetector.kt`)
Stateful LSTM, threaded across calls.

| | name | shape |
|---|---|---|
| input  | `audio_input`      | `[1, 576]` (64 context + 512 chunk) |
| input  | `hidden_state`     | `[1, 128]` |
| input  | `cell_state`       | `[1, 128]` |
| output | `vad_output`       | `[1, 1, 1]` (caller reads element `[0]`) |
| output | `new_hidden_state` | `[1, 128]` |
| output | `new_cell_state`   | `[1, 128]` |

Thresholds (Silero overrides): speech `0.5`, silence `0.35`,
`chunkDurationSeconds 0.1`.

### Whisper log-mel front end (`SmartTurnTurnEndDetector.kt`, stage 1)

| | name | shape |
|---|---|---|
| input  | `audio`   | `[1, 128000]` (8 s @ 16 kHz, zero-padded at the START) |
| output | `log_mel` | `[1, 80, 800]` |

### Smart-Turn v3 classifier (`SmartTurnTurnEndDetector.kt`, stage 2)

| | name | shape |
|---|---|---|
| input  | `input_features` | `[1, 80, 800]` (the `log_mel`) |
| output | `probability`    | `[1, 1]` (sigmoid, threshold `0.5` applied in the caller) |

**Fail-to-done bias:** on any inference error the detector returns probability
`1.0` → `SpeakerDone`. Stalling on a hung classifier is worse than an occasional
early cut; the engine's `raceTurnEnd` timer is the only thing that resumes
recording, so a silent failure must not block it.

## Parity gate (`validate_parity.py`)

Feeds the reference 16 kHz mono WAV set (from
`../../Tests/ClaudeRelaySpeechTests/Fixtures`, with an optional `labels.json`
mapping `"<file>.wav" → done?`) through **both** the CoreML models (via
coremltools) **and** the converted ONNX, and asserts:

| model      | criterion |
|------------|-----------|
| Silero     | per-window probability **relative error < 0.1%** |
| LogMel     | **max-abs element diff ≤ 1e-2** |
| Smart-Turn | **TPR ≥ 90% and FPR ≤ 10%** vs labels |

Exit `0` = gate passed (M4 may wire the detectors in and bundle the `.onnx` as
app assets). Exit non-zero (incl. "no fixtures") = keep the energy VAD +
`HeuristicTurnEndDetector`. A report is written to `out/parity_report.json`.

## What M4 must do

1. Run the three `convert_*.py` scripts on a Mac with the deps.
2. Add the reference fixtures + `labels.json` and make `validate_parity.py` exit `0`.
3. Bundle `out/*.onnx` as `:app` assets (e.g. `app/src/main/assets/`).
4. Wire `SileroVoiceActivityDetector.tryLoad(...)` / `SmartTurnTurnEndDetector.tryLoad(...)`
   into `ContinuousListeningEngine.makeDefault` (preferring them, falling back to
   energy VAD / heuristic when `tryLoad` returns null).

`out/` is git-ignored — the converted models are build artifacts produced
per-machine, not checked in.
