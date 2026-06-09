"""Shared helpers for the CoreML -> ONNX conversion sub-project.

M4-GATED TOOLING — NOT RUN IN THE M3 ENV.
=========================================
`coremltools` and `onnxruntime` (Python) are intentionally NOT installed in the
M3 build environment, so none of the scripts in this directory are executed here.
They are written to be correct + runnable on a Mac with:

    pip install coremltools onnx onnxruntime numpy

See ml/README.md for the full gating rationale. Until ml/validate_parity.py
passes on a Mac (M4), the converted ONNX models are NOT trusted and the Kotlin
detectors that consume them stay un-wired (see makeDefault gating note).

This module only contains pure-Python path helpers + I/O-contract constants, so
it imports nothing heavy and stays import-safe even without the ML deps.
"""

from __future__ import annotations

import os

# ── Source CoreML models (the in-repo macOS/iOS bundle resources) ──────────────
# Paths are relative to THIS file (ClaudeRelayAndroid/ml/), reaching back up to
# the SwiftPM target's Resources directory.
_HERE = os.path.dirname(os.path.abspath(__file__))
_RESOURCES = os.path.normpath(
    os.path.join(_HERE, "..", "..", "Sources", "ClaudeRelaySpeech", "Resources")
)

SILERO_MLMODELC = os.path.join(_RESOURCES, "SileroVAD.mlmodelc")
SMARTTURN_MLPACKAGE = os.path.join(_RESOURCES, "SmartTurnV3.mlpackage")
LOGMEL_MLPACKAGE = os.path.join(_RESOURCES, "WhisperLogMel8s.mlpackage")

# ── Output directory + file names (consumed by the Kotlin detectors as assets) ──
OUT_DIR = os.path.join(_HERE, "out")
SILERO_ONNX = os.path.join(OUT_DIR, "silero_vad.onnx")
LOGMEL_ONNX = os.path.join(OUT_DIR, "whisper_logmel8s.onnx")
SMARTTURN_ONNX = os.path.join(OUT_DIR, "smartturn_v3.onnx")

# ── I/O contracts (verified against SileroVAD.mlmodelc/metadata.json + the
#    SmartTurnV3 / WhisperLogMel8s mlmodel specs, and the Swift detectors). ──────
SAMPLE_RATE = 16_000

# Silero VAD v6 unified: stateful LSTM.
SILERO_INPUTS = {
    "audio_input": (1, 576),   # 64 context + 512 chunk
    "hidden_state": (1, 128),
    "cell_state": (1, 128),
}
SILERO_OUTPUTS = {
    "vad_output": (1, 1, 1),   # Swift reads element [0]
    "new_hidden_state": (1, 128),
    "new_cell_state": (1, 128),
}
SILERO_CONTEXT = 64
SILERO_CHUNK = 512
SILERO_STATE = 128

# Whisper log-mel front end: 8 s @ 16 kHz -> [1, 80, 800].
LOGMEL_INPUT = "audio"
LOGMEL_OUTPUT = "log_mel"
LOGMEL_SAMPLES = 128_000           # 8 s * 16 kHz
LOGMEL_OUTPUT_SHAPE = (1, 80, 800)

# Smart-Turn v3 classifier: log-mel -> sigmoid probability.
SMARTTURN_INPUT = "input_features"
SMARTTURN_OUTPUT = "probability"
SMARTTURN_INPUT_SHAPE = (1, 80, 800)
SMARTTURN_THRESHOLD = 0.5


def ensure_out_dir() -> None:
    """Create ml/out/ if missing."""
    os.makedirs(OUT_DIR, exist_ok=True)


def require_source(path: str) -> str:
    """Fail loudly if a source CoreML model is missing (e.g. wrong cwd)."""
    if not os.path.exists(path):
        raise FileNotFoundError(
            f"source model not found: {path}\n"
            "Run these scripts from ClaudeRelayAndroid/ml/ on a Mac with the "
            "in-repo Sources/ClaudeRelaySpeech/Resources/ present."
        )
    return path


def banner(title: str) -> None:
    line = "=" * len(title)
    print(f"\n{line}\n{title}\n{line}")
