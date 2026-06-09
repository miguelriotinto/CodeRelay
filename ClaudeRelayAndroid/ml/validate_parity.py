#!/usr/bin/env python3
"""Parity gate: CoreML (iOS source of truth) vs converted ONNX (Android).

M4-GATED TOOLING — NOT RUN IN THE M3 ENV (no coremltools/onnxruntime installed).
This is THE GATE for M4: the Kotlin Silero/Smart-Turn ONNX detectors are NOT
wired into ContinuousListeningEngine.makeDefault until this script PASSES on a Mac.

Runnable on a Mac with: ``pip install coremltools onnx onnxruntime numpy``.

What it checks (acceptance thresholds)
--------------------------------------
  Silero VAD : per-window probability relative error < 0.1% vs the CoreML model
               (state threaded identically through both), across the reference set.
  LogMel     : max absolute element diff <= LOGMEL_MAX_ABS_TOL vs the CoreML
               front end, across the reference set.
  Smart-Turn : on a labelled reference set, the ONNX classifier (fed the ONNX
               log-mel) must achieve TPR >= 90% and FPR <= 10% vs the labels.
               (The CoreML model's own scores are also reported for reference.)

Reference audio set
-------------------
Pulls 16 kHz mono WAVs from the iOS speech fixtures
(``Tests/ClaudeRelaySpeechTests/Fixtures``). Labels for the Smart-Turn TPR/FPR
check are read from an optional ``labels.json`` in that directory mapping
``{ "<filename>.wav": true|false }`` (true = speaker done). If no fixtures are
present yet (the M3 state — the dir holds only .gitkeep), the script prints a
clear "no fixtures" notice and exits non-zero so the gate cannot pass vacuously.

Emits a parity report to stdout and ``ml/out/parity_report.json``.
"""

from __future__ import annotations

import glob
import json
import os
import sys

import _common as C

FIXTURES_DIR = os.path.normpath(
    os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..", "..", "Tests", "ClaudeRelaySpeechTests", "Fixtures",
    )
)
PARITY_REPORT = os.path.join(C.OUT_DIR, "parity_report.json")

# Acceptance thresholds.
SILERO_REL_ERROR_MAX = 0.001     # 0.1%
LOGMEL_MAX_ABS_TOL = 1e-2        # generous: CoreML fp16 vs ONNX fp32
SMARTTURN_MIN_TPR = 0.90
SMARTTURN_MAX_FPR = 0.10


# ── audio loading ──────────────────────────────────────────────────────────────
def _load_wavs():
    """Return list of (name, samples[float32 @ 16 kHz mono]). Empty if none."""
    import numpy as np
    import wave

    out = []
    for path in sorted(glob.glob(os.path.join(FIXTURES_DIR, "*.wav"))):
        with wave.open(path, "rb") as wf:
            if wf.getframerate() != C.SAMPLE_RATE or wf.getnchannels() != 1:
                print(f"  skip {os.path.basename(path)}: not 16 kHz mono")
                continue
            frames = wf.readframes(wf.getnframes())
            samples = (np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0)
            out.append((os.path.basename(path), samples))
    return out


def _load_labels():
    path = os.path.join(FIXTURES_DIR, "labels.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


# ── model runners ────────────────────────────────────────────────────────────
def _coreml(path):
    import coremltools as ct

    return ct.models.MLModel(C.require_source(path))


def _ort(path):
    import onnxruntime as ort

    if not os.path.exists(path):
        raise FileNotFoundError(
            f"converted ONNX missing: {path} — run the convert_*.py scripts first."
        )
    return ort.InferenceSession(path, providers=["CPUExecutionProvider"])


# ── checks ─────────────────────────────────────────────────────────────────────
def _check_silero(wavs):
    """Thread identical state through CoreML + ONNX; compare per-window probs."""
    import numpy as np

    cm = _coreml(C.SILERO_MLMODELC)
    ox = _ort(C.SILERO_ONNX)

    worst_rel = 0.0
    n_windows = 0
    for _name, samples in wavs:
        # Reset state per clip for both models.
        h_cm = np.zeros((1, C.SILERO_STATE), np.float32)
        c_cm = np.zeros((1, C.SILERO_STATE), np.float32)
        h_ox = np.zeros((1, C.SILERO_STATE), np.float32)
        c_ox = np.zeros((1, C.SILERO_STATE), np.float32)
        ctx = np.zeros(C.SILERO_CONTEXT, np.float32)

        for start in range(0, len(samples) - C.SILERO_CHUNK + 1, C.SILERO_CHUNK):
            window = samples[start:start + C.SILERO_CHUNK]
            audio_in = np.concatenate([ctx, window]).reshape(1, -1).astype(np.float32)

            cm_out = cm.predict({
                "audio_input": audio_in, "hidden_state": h_cm, "cell_state": c_cm,
            })
            ox_out = dict(zip(
                [o.name for o in ox.get_outputs()],
                ox.run(None, {
                    "audio_input": audio_in, "hidden_state": h_ox, "cell_state": c_ox,
                }),
            ))

            p_cm = float(np.ravel(cm_out["vad_output"])[0])
            p_ox = float(np.ravel(ox_out["vad_output"])[0])
            denom = max(abs(p_cm), 1e-6)
            worst_rel = max(worst_rel, abs(p_cm - p_ox) / denom)
            n_windows += 1

            h_cm = np.array(cm_out["new_hidden_state"], np.float32).reshape(1, -1)
            c_cm = np.array(cm_out["new_cell_state"], np.float32).reshape(1, -1)
            h_ox = ox_out["new_hidden_state"].reshape(1, -1)
            c_ox = ox_out["new_cell_state"].reshape(1, -1)
            ctx = window[-C.SILERO_CONTEXT:]

    passed = worst_rel < SILERO_REL_ERROR_MAX
    return {
        "name": "silero",
        "windows": n_windows,
        "worst_rel_error": worst_rel,
        "threshold": SILERO_REL_ERROR_MAX,
        "passed": passed,
    }


def _logmel_pair(wavs):
    """Return (coreml_session_or_model, ort_session, per-clip [audio padded])."""
    import numpy as np

    def pad(samples):
        if len(samples) >= C.LOGMEL_SAMPLES:
            return samples[-C.LOGMEL_SAMPLES:]
        out = np.zeros(C.LOGMEL_SAMPLES, np.float32)
        out[C.LOGMEL_SAMPLES - len(samples):] = samples  # zero-pad at START
        return out

    return pad


def _check_logmel(wavs):
    import numpy as np

    cm = _coreml(C.LOGMEL_MLPACKAGE)
    ox = _ort(C.LOGMEL_ONNX)
    pad = _logmel_pair(wavs)

    worst_abs = 0.0
    for _name, samples in wavs:
        audio = pad(samples).reshape(1, -1).astype(np.float32)
        cm_mel = np.array(cm.predict({C.LOGMEL_INPUT: audio})[C.LOGMEL_OUTPUT], np.float32)
        ox_mel = ox.run(None, {C.LOGMEL_INPUT: audio})[0].astype(np.float32)
        worst_abs = max(worst_abs, float(np.max(np.abs(cm_mel - ox_mel))))

    passed = worst_abs <= LOGMEL_MAX_ABS_TOL
    return {
        "name": "logmel",
        "worst_max_abs_diff": worst_abs,
        "tolerance": LOGMEL_MAX_ABS_TOL,
        "passed": passed,
    }


def _check_smartturn(wavs, labels):
    import numpy as np

    if not labels:
        return {
            "name": "smartturn",
            "passed": False,
            "error": "no labels.json in fixtures — cannot compute TPR/FPR",
        }

    logmel = _ort(C.LOGMEL_ONNX)
    clf = _ort(C.SMARTTURN_ONNX)
    pad = _logmel_pair(wavs)

    tp = fp = tn = fn = 0
    for name, samples in wavs:
        if name not in labels:
            continue
        audio = pad(samples).reshape(1, -1).astype(np.float32)
        mel = logmel.run(None, {C.LOGMEL_INPUT: audio})[0].astype(np.float32)
        prob = float(np.ravel(clf.run(None, {C.SMARTTURN_INPUT: mel})[0])[0])
        pred_done = prob >= C.SMARTTURN_THRESHOLD
        truth_done = bool(labels[name])
        if pred_done and truth_done:
            tp += 1
        elif pred_done and not truth_done:
            fp += 1
        elif not pred_done and not truth_done:
            tn += 1
        else:
            fn += 1

    tpr = tp / (tp + fn) if (tp + fn) else 0.0
    fpr = fp / (fp + tn) if (fp + tn) else 0.0
    passed = tpr >= SMARTTURN_MIN_TPR and fpr <= SMARTTURN_MAX_FPR
    return {
        "name": "smartturn",
        "tp": tp, "fp": fp, "tn": tn, "fn": fn,
        "tpr": tpr, "fpr": fpr,
        "min_tpr": SMARTTURN_MIN_TPR, "max_fpr": SMARTTURN_MAX_FPR,
        "passed": passed,
    }


def main() -> int:
    C.banner("validate_parity.py — CoreML vs ONNX parity GATE (M4)")
    C.ensure_out_dir()

    wavs = _load_wavs()
    if not wavs:
        print(
            f"\nNO FIXTURES in {FIXTURES_DIR}\n"
            "The reference 16 kHz mono WAV set is not present (M3 state — the dir\n"
            "holds only .gitkeep). The parity gate CANNOT pass without it. Add the\n"
            "fixtures + labels.json on the Mac running M4, then re-run.\n"
        )
        return 2

    labels = _load_labels()
    print(f"reference clips: {len(wavs)}  labels: {len(labels)}")

    results = [
        _check_silero(wavs),
        _check_logmel(wavs),
        _check_smartturn(wavs, labels),
    ]

    C.banner("PARITY REPORT")
    for r in results:
        status = "PASS" if r.get("passed") else "FAIL"
        print(f"[{status}] {r['name']}: "
              + ", ".join(f"{k}={v}" for k, v in r.items() if k not in ("name", "passed")))

    with open(PARITY_REPORT, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nwrote {PARITY_REPORT}")

    all_passed = all(r.get("passed") for r in results)
    if all_passed:
        print("\nGATE PASSED — M4 may wire the ONNX detectors into makeDefault.")
        return 0
    print("\nGATE FAILED — keep the energy VAD + HeuristicTurnEndDetector.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
